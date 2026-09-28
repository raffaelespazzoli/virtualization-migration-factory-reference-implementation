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

// ── Common filter ───────────────────────────────────────────────────
// Applied to every container-level metric.  The variable selectors
// use regex matching so that "all" ($__all → .*) works correctly.
_f: "namespace=~\"$namespace\", pod=~\"$pod\", container=~\"$container\", container!=\"POD\", container!=\"\""

// ── PromQL fragments ────────────────────────────────────────────────

// Memory segments (bottom to top in the stacked chart):
//   1. Non-reclaimable (anonymous/RSS)
//   2. Kernel overhead  (usage - rss - cache)
//   3. Reclaimable hot  (active file = cache - inactive_file)
//   4. Reclaimable cold (inactive file = usage - working_set)
//
// These are derived from four cAdvisor metrics:
//   container_memory_rss, container_memory_cache,
//   container_memory_usage_bytes, container_memory_working_set_bytes

#rss: "sum(container_memory_rss{" + _f + "})"

#overhead: """
	sum(container_memory_usage_bytes{\( _f )})
	- sum(container_memory_rss{\( _f )})
	- sum(container_memory_cache{\( _f )})
	"""

#hotReclaim: """
	sum(container_memory_cache{\( _f )})
	- (
	  sum(container_memory_usage_bytes{\( _f )})
	  - sum(container_memory_working_set_bytes{\( _f )})
	)
	"""

#coldReclaim: """
	sum(container_memory_usage_bytes{\( _f )})
	- sum(container_memory_working_set_bytes{\( _f )})
	"""

// Summary stat queries
#workingSet: "sum(container_memory_working_set_bytes{" + _f + "})"
#usageTotal: "sum(container_memory_usage_bytes{" + _f + "})"
#memLimit:   "sum(kube_pod_container_resource_limits{resource=\"memory\", namespace=~\"$namespace\", pod=~\"$pod\", container=~\"$container\"})"
#utilization: """
	sum(container_memory_working_set_bytes{\( _f )})
	/
	sum(kube_pod_container_resource_limits{resource="memory", namespace=~"$namespace", pod=~"$pod", container=~"$container"})
	"""

// ── Dashboard ───────────────────────────────────────────────────────

dashboardBuilder & {
	#name:    "pod-memory"
	#project: "perses"
	#display: {
		name:        "Pod Memory"
		description: "Container memory decomposition: non-reclaimable, hot/cold reclaimable, kernel overhead, with limit threshold."
	}
	#duration: "6h"

	#variables: {varGroupBuilder & {
		#input: [
			labelValuesVarBuilder & {
				#name:   "namespace"
				#display: name: "Namespace"
				#metric: "container_memory_working_set_bytes"
				#label:  "namespace"
				#allowAllValue: false
				#allowMultiple: false
			},
			labelValuesVarBuilder & {
				#name:   "pod"
				#display: name: "Pod"
				#label:  "pod"
				#query:  "container_memory_working_set_bytes{namespace=~\"$namespace\",container!=\"\",container!=\"POD\"}"
				#allowAllValue: true
				#allowMultiple: false
			},
			labelValuesVarBuilder & {
				#name:   "container"
				#display: name: "Container"
				#label:  "container"
				#query:  "container_memory_working_set_bytes{namespace=~\"$namespace\",pod=~\"$pod\",container!=\"\",container!=\"POD\"}"
				#allowAllValue: true
				#allowMultiple: false
			},
		]
	}}.variables

	#panelGroups: panelGroupsBuilder & {
		#input: [
			// ── Row 1: Summary stats ────────────────────────
			{
				#title: "Summary"
				#cols:  4
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "Working Set"
								description: "Memory that cannot be freely reclaimed (usage minus inactive file cache). This is what the kubelet uses for eviction and OOM decisions."
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
									spec: query: #workingSet
								}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: name: "Memory Limit"
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
									spec: query: #memLimit
								}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Utilization"
								description: "working_set / limit — how close to OOM"
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {
										unit:          "percent"
										decimalPlaces: 1
									}
									thresholds: {
										steps: [
											{value: 0, color: "#32ac2d"},
											{value: 0.80, color: "#ed8128"},
											{value: 0.95, color: "#f53636"},
										]
									}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {
									spec: query: #utilization
								}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "RSS"
								description: "Anonymous memory (heap, stack). Cannot be reclaimed without swap — primary driver of OOM kills."
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
									spec: query: #rss
								}
							}]
						}
					},
				]
			},

			// ── Row 2: Memory Decomposition ──────────────────
			{
				#title:  "Memory Decomposition"
				#cols:   1
				#height: 16
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "Memory Breakdown"
								description: "Stacked memory usage with limit threshold. Total height = container_memory_usage_bytes."
							}
							plugin: #stackedAreaChart & {
								spec: {
									visual: lineWidth: 2
									querySettings: [{
										queryIndex: 4
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
									#segment: "Non-reclaimable (anon/RSS)"
									#query:   #rss
								},
								#memQuery & {
									#segment: "Kernel overhead"
									#query:   #overhead
								},
								#memQuery & {
									#segment: "Reclaimable hot (active file)"
									#query:   #hotReclaim
								},
								#memQuery & {
									#segment: "Reclaimable cold (inactive file)"
									#query:   #coldReclaim
								},
								#memQuery & {
									#segment: "── Memory Limit"
									#query:   #memLimit
								},
							]
						}
					},
				]
			},
		]
	}
}
