package dac

import (
	dashboardBuilder "github.com/perses/perses/cue/dac-utils/dashboard"
	panelGroupsBuilder "github.com/perses/perses/cue/dac-utils/panelgroups"
	varGroupBuilder "github.com/perses/perses/cue/dac-utils/variable/group"
	panelBuilder "github.com/perses/plugins/prometheus/sdk/cue/panel"
	promQuery "github.com/perses/plugins/prometheus/schemas/prometheus-time-series-query:model"
	statChart "github.com/perses/plugins/statchart/schemas:model"
	labelValuesVarBuilder "github.com/perses/plugins/prometheus/sdk/cue/variable/labelvalues"
)

// ── Stacked area chart ──────────────────────────────────────────────
// Perses TimeSeriesChart with visual.stack = "all" renders a stacked
// area chart.  Each query becomes one band; order matters (bottom to
// top matches query order).
#stackedAreaChart: {
	kind: "TimeSeriesChart"
	spec: {
		legend: {
			position: "bottom"
			mode:     "list"
		}
		visual: {
			display:    "line"
			areaOpacity: 0.7
			stack:       "all"
		}
		yAxis: format: unit: "bytes"
	}
}

// ── Query helper ────────────────────────────────────────────────────
#memQuery: {
	#query:   string
	#segment: string
	kind:     "TimeSeriesQuery"
	spec: plugin: promQuery & {
		spec: {
			query:            #query
			seriesNameFormat: #segment
		}
	}
}

// ── Per-node vs all-nodes aggregation ───────────────────────────────
// When $node is a specific node, the metric naturally has one series.
// When $node is ".*" (all nodes), we sum across nodes so the chart
// shows a single stacked area instead of interleaved per-node bands.
//
// The variable filter is applied via {node=~"$node"} in each query.
// For kube_node_status_* the label is also "node".

// ── PromQL fragments ────────────────────────────────────────────────

// Panel 1: Full node — stacks from bottom: non-reclaimable, hot, cold, free
// Total = capacity.
#p1_nonReclaim: """
	sum(container_memory_rss{id="/system.slice", node=~"$node"})
	+ sum(container_memory_rss{id="/kubepods.slice", node=~"$node"})
	"""
#p1_hotReclaim: """
	sum(container_memory_total_active_file_bytes{id="/system.slice", node=~"$node"})
	+ sum(container_memory_total_active_file_bytes{id="/kubepods.slice", node=~"$node"})
	"""
#p1_coldReclaim: """
	sum(container_memory_total_inactive_file_bytes{id="/system.slice", node=~"$node"})
	+ sum(container_memory_total_inactive_file_bytes{id="/kubepods.slice", node=~"$node"})
	"""
#p1_overhead: """
	(
	  sum(container_memory_usage_bytes{id="/system.slice", node=~"$node"})
	  + sum(container_memory_usage_bytes{id="/kubepods.slice", node=~"$node"})
	)
	- (
	  sum(container_memory_rss{id="/system.slice", node=~"$node"})
	  + sum(container_memory_rss{id="/kubepods.slice", node=~"$node"})
	)
	- (
	  sum(container_memory_total_active_file_bytes{id="/system.slice", node=~"$node"})
	  + sum(container_memory_total_active_file_bytes{id="/kubepods.slice", node=~"$node"})
	)
	- (
	  sum(container_memory_total_inactive_file_bytes{id="/system.slice", node=~"$node"})
	  + sum(container_memory_total_inactive_file_bytes{id="/kubepods.slice", node=~"$node"})
	)
	"""
#p1_free: """
	sum(kube_node_status_capacity{resource="memory", node=~"$node"})
	- sum(container_memory_usage_bytes{id="/system.slice", node=~"$node"})
	- sum(container_memory_usage_bytes{id="/kubepods.slice", node=~"$node"})
	"""

// Panel 2: Workloads (kubepods.slice) — total = allocatable
#p2_nonReclaim: """
	sum(container_memory_rss{id="/kubepods.slice", node=~"$node"})
	"""
#p2_hotReclaim: """
	sum(container_memory_total_active_file_bytes{id="/kubepods.slice", node=~"$node"})
	"""
#p2_coldReclaim: """
	sum(container_memory_total_inactive_file_bytes{id="/kubepods.slice", node=~"$node"})
	"""
#p2_overhead: """
	sum(container_memory_usage_bytes{id="/kubepods.slice", node=~"$node"})
	- sum(container_memory_rss{id="/kubepods.slice", node=~"$node"})
	- sum(container_memory_total_active_file_bytes{id="/kubepods.slice", node=~"$node"})
	- sum(container_memory_total_inactive_file_bytes{id="/kubepods.slice", node=~"$node"})
	"""
#p2_free: """
	sum(kube_node_status_allocatable{resource="memory", node=~"$node"})
	- sum(container_memory_usage_bytes{id="/kubepods.slice", node=~"$node"})
	"""

// Panel 3: System (system.slice) — no cap (system.slice has memory.max = max)
#p3_nonReclaim: """
	sum(container_memory_rss{id="/system.slice", node=~"$node"})
	"""
#p3_hotReclaim: """
	sum(container_memory_total_active_file_bytes{id="/system.slice", node=~"$node"})
	"""
#p3_coldReclaim: """
	sum(container_memory_total_inactive_file_bytes{id="/system.slice", node=~"$node"})
	"""
#p3_overhead: """
	sum(container_memory_usage_bytes{id="/system.slice", node=~"$node"})
	- sum(container_memory_rss{id="/system.slice", node=~"$node"})
	- sum(container_memory_total_active_file_bytes{id="/system.slice", node=~"$node"})
	- sum(container_memory_total_inactive_file_bytes{id="/system.slice", node=~"$node"})
	"""

// ── Summary stats PromQL ────────────────────────────────────────────
#allocatable: """
	sum(kube_node_status_allocatable{resource="memory", node=~"$node"})
	"""
#reserved: """
	sum(kube_node_status_capacity{resource="memory", node=~"$node"})
	- sum(kube_node_status_allocatable{resource="memory", node=~"$node"})
	"""
#capacity: """
	sum(kube_node_status_capacity{resource="memory", node=~"$node"})
	"""
#workloadUtilization: """
	sum(container_memory_usage_bytes{id="/kubepods.slice", node=~"$node"})
	/
	sum(kube_node_status_allocatable{resource="memory", node=~"$node"})
	"""
#systemUsed: """
	sum(container_memory_usage_bytes{id="/system.slice", node=~"$node"})
	"""

// ── Dashboard ───────────────────────────────────────────────────────

dashboardBuilder & {
	#name:    "node-memory"
	#project: "openshift-operators"
	#display: {
		name:        "Node Memory"
		description: "Runtime memory decomposition per node: non-reclaimable, hot-reclaimable, cold-reclaimable, and free."
	}
	#duration: "6h"

	#variables: {varGroupBuilder & {
		#input: [
			labelValuesVarBuilder & {
				#name:   "node"
				#display: name: "Node"
				#metric: "kube_node_status_capacity"
				#label:  "node"
				#allowAllValue: true
				#allowMultiple: false
			},
		]
	}}.variables

	#panelGroups: panelGroupsBuilder & {
		#input: [
			// ── Row 1: Reference values ─────────────────────────
			{
				#title: "Summary"
				#cols:  5
				#panels: [
					panelBuilder & {
						spec: {
							display: name: "Capacity"
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {
										unit:          "bytes"
										decimalPlaces: 1
									}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {
									spec: query: #capacity
								}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: name: "Allocatable"
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {
										unit:          "bytes"
										decimalPlaces: 1
									}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {
									spec: query: #allocatable
								}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Reserved"
								description: "system-reserved + kube-reserved + eviction-threshold"
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {
										unit:          "bytes"
										decimalPlaces: 1
									}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {
									spec: query: #reserved
								}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Workload utilization"
								description: "kubepods.slice usage / allocatable"
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {
										unit:          "percent"
										decimalPlaces: 1
									}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {
									spec: query: #workloadUtilization
								}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "System used"
								description: "system.slice total usage (can exceed reserved via file cache)"
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {
										unit:          "bytes"
										decimalPlaces: 1
									}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {
									spec: query: #systemUsed
								}
							}]
						}
					},
				]
			},

			// ── Row 2: Stacked area charts ──────────────────────
			{
				#title:  "Memory Decomposition"
				#cols:   3
				#height: 14
				#panels: [
					// ── Panel 1: Full Node ──────────────────────
					panelBuilder & {
						spec: {
							display: {
								name:        "Node Total"
								description: "Full node memory: system + workloads. Total height = node capacity."
							}
							plugin: #stackedAreaChart
							queries: [
								#memQuery & {
									#segment: "Non-reclaimable (anon)"
									#query:   #p1_nonReclaim
								},
								#memQuery & {
									#segment: "Kernel overhead"
									#query:   #p1_overhead
								},
								#memQuery & {
									#segment: "Reclaimable hot (active file)"
									#query:   #p1_hotReclaim
								},
								#memQuery & {
									#segment: "Reclaimable cold (inactive file)"
									#query:   #p1_coldReclaim
								},
								#memQuery & {
									#segment: "Free"
									#query:   #p1_free
								},
							]
						}
					},

					// ── Panel 2: Workloads (kubepods.slice) ─────
					panelBuilder & {
						spec: {
							display: {
								name:        "Workloads (kubepods.slice)"
								description: "Pod memory only. Total height = node allocatable."
							}
							plugin: #stackedAreaChart
							queries: [
								#memQuery & {
									#segment: "Non-reclaimable (anon)"
									#query:   #p2_nonReclaim
								},
								#memQuery & {
									#segment: "Kernel overhead"
									#query:   #p2_overhead
								},
								#memQuery & {
									#segment: "Reclaimable hot (active file)"
									#query:   #p2_hotReclaim
								},
								#memQuery & {
									#segment: "Reclaimable cold (inactive file)"
									#query:   #p2_coldReclaim
								},
								#memQuery & {
									#segment: "Free"
									#query:   #p2_free
								},
							]
						}
					},

					// ── Panel 3: System (system.slice) ──────────
					panelBuilder & {
						spec: {
							display: {
								name:        "System (system.slice)"
								description: "OS and Kubernetes system services. Compare with Reserved stat above — system usage commonly exceeds reservation due to file cache."
							}
							plugin: #stackedAreaChart
							queries: [
								#memQuery & {
									#segment: "Non-reclaimable (anon)"
									#query:   #p3_nonReclaim
								},
								#memQuery & {
									#segment: "Kernel overhead"
									#query:   #p3_overhead
								},
								#memQuery & {
									#segment: "Reclaimable hot (active file)"
									#query:   #p3_hotReclaim
								},
								#memQuery & {
									#segment: "Reclaimable cold (inactive file)"
									#query:   #p3_coldReclaim
								},
							]
						}
					},
				]
			},
		]
	}
}
