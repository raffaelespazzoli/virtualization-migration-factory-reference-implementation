package dac

import (
	dashboardBuilder "github.com/perses/perses/cue/dac-utils/dashboard"
	panelGroupsBuilder "github.com/perses/perses/cue/dac-utils/panelgroups"
	varGroupBuilder "github.com/perses/perses/cue/dac-utils/variable/group"
	panelBuilder "github.com/perses/plugins/prometheus/sdk/cue/panel"
	promQuery "github.com/perses/plugins/prometheus/schemas/prometheus-time-series-query:model"
	labelValuesVarBuilder "github.com/perses/plugins/prometheus/sdk/cue/variable/labelvalues"
)

// ── Stacked area chart definition ───────────────────────────────────
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
// Builds a time-series query with a human-readable segment name.
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

// ── Threshold line helper ───────────────────────────────────────────
// A query rendered as a line (not stacked) to show a reference level.
// Using a separate non-stacked query is the Perses way to overlay a
// constant line on a stacked chart.
#thresholdQuery: {
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
// Total = capacity.  Allocatable shown as a threshold line.
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
#p1_allocatable: """
	sum(kube_node_status_allocatable{resource="memory", node=~"$node"})
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

// Panel 3: System (system.slice) — total = reservation
// Reserved shown as a threshold line (can be crossed upward).
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
#p3_reserved: """
	sum(kube_node_status_capacity{resource="memory", node=~"$node"})
	- sum(kube_node_status_allocatable{resource="memory", node=~"$node"})
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
								description: "Full node memory: system + workloads. The dashed line marks allocatable. Total height = node capacity."
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
								#thresholdQuery & {
									#segment: "── Allocatable"
									#query:   #p1_allocatable
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
								description: "OS and Kubernetes system services. The dashed line marks the reservation — usage can cross it."
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
								#thresholdQuery & {
									#segment: "── Reserved"
									#query:   #p3_reserved
								},
							]
						}
					},
				]
			},
		]
	}
}
