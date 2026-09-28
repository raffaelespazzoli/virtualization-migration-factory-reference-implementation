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
			...
		}
		yAxis: format: unit: "bytes"
		...
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
// When $node is a specific node, the recording rule naturally has one
// series per node.  When $node is ".*" (all nodes), sum() aggregates
// across nodes so the chart shows a single stacked area.
//
// All panel queries reference recording rules from prometheus-rule.yaml
// (group: capacity-management-node-memory.rules) which pre-aggregate
// cAdvisor metrics by node.  This reduces Thanos query fan-out.

// ── Node filter applied to recording rules ──────────────────────────
_wk: "{node=~\"$node\"}" // workloads (kubepods.slice)
_sy: "{node=~\"$node\"}" // system (system.slice)

// ── PromQL fragments ────────────────────────────────────────────────

// Panel 1: Full node — stacks from bottom: non-reclaimable, overhead,
//          hot, cold, free.  Total = capacity.
#p1_nonReclaim: "sum(cluster:node:memory:workloads_non_reclaimable:bytes" + _wk + ") + sum(cluster:node:memory:system_non_reclaimable:bytes" + _sy + ")"
#p1_overhead:   "sum(cluster:node:memory:workloads_overhead:bytes" + _wk + ") + sum(cluster:node:memory:system_overhead:bytes" + _sy + ")"
#p1_hotReclaim: "sum(cluster:node:memory:workloads_hot_reclaimable:bytes" + _wk + ") + sum(cluster:node:memory:system_hot_reclaimable:bytes" + _sy + ")"
#p1_coldReclaim: "sum(cluster:node:memory:workloads_cold:bytes" + _wk + ") + sum(cluster:node:memory:system_cold:bytes" + _sy + ")"
#p1_free: """
	sum(kube_node_status_capacity{resource="memory", node=~"$node"})
	- sum(cluster:node:memory:workloads_used:bytes\( _wk ))
	- sum(cluster:node:memory:system_used:bytes\( _sy ))
	"""

// Panel 2: Workloads (kubepods.slice) — total = allocatable
#p2_nonReclaim:  "sum(cluster:node:memory:workloads_non_reclaimable:bytes" + _wk + ")"
#p2_overhead:    "sum(cluster:node:memory:workloads_overhead:bytes" + _wk + ")"
#p2_hotReclaim:  "sum(cluster:node:memory:workloads_hot_reclaimable:bytes" + _wk + ")"
#p2_coldReclaim: "sum(cluster:node:memory:workloads_cold:bytes" + _wk + ")"
#p2_free: """
	sum(kube_node_status_allocatable{resource="memory", node=~"$node"})
	- sum(cluster:node:memory:workloads_used:bytes\( _wk ))
	"""

// Panel 3: System (system.slice) — no cap (system.slice has memory.max = max)
#p3_nonReclaim:  "sum(cluster:node:memory:system_non_reclaimable:bytes" + _sy + ")"
#p3_overhead:    "sum(cluster:node:memory:system_overhead:bytes" + _sy + ")"
#p3_hotReclaim:  "sum(cluster:node:memory:system_hot_reclaimable:bytes" + _sy + ")"
#p3_coldReclaim: "sum(cluster:node:memory:system_cold:bytes" + _sy + ")"

// ── Summary stats PromQL ────────────────────────────────────────────
#allocatable: "sum(kube_node_status_allocatable{resource=\"memory\", node=~\"$node\"})"
#reserved: """
	sum(kube_node_status_capacity{resource="memory", node=~"$node"})
	- sum(kube_node_status_allocatable{resource="memory", node=~"$node"})
	"""
#capacity: "sum(kube_node_status_capacity{resource=\"memory\", node=~\"$node\"})"
#workloadUtilization: "sum(cluster:node:memory:workloads_utilization:ratio" + _wk + ")"
#systemUsed: "sum(cluster:node:memory:system_used:bytes" + _sy + ")"

// ── Dashboard ───────────────────────────────────────────────────────

dashboardBuilder & {
	#name:    "node-memory"
	#project: "perses"
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
								description: "kubepods.slice working_set / allocatable (kubelet eviction metric)"
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
							plugin: #stackedAreaChart & {
								spec: {
									visual: lineWidth: 2
									querySettings: [{
										queryIndex: 5
										colorMode:  "fixed-single"
										colorValue: "#FFFFFF"
										lineStyle:  "dotted"
										stack:      false
										areaOpacity: 0
									}]
								}
							}
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
								#memQuery & {
									#segment: "── Allocatable"
									#query:   #allocatable
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
							plugin: #stackedAreaChart & {
								spec: {
									visual: lineWidth: 2
									querySettings: [{
										queryIndex: 4
										colorMode:  "fixed-single"
										colorValue: "#FF8C00"
										lineStyle:  "dotted"
										stack:      false
										areaOpacity: 0
									}]
								}
							}
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
								#memQuery & {
									#segment: "── Reserved"
									#query:   #reserved
								},
							]
						}
					},
				]
			},
		]
	}
}
