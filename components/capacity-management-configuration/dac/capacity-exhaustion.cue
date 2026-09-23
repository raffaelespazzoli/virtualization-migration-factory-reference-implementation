package dac

import (
	dashboardBuilder "github.com/perses/perses/cue/dac-utils/dashboard"
	panelGroupsBuilder "github.com/perses/perses/cue/dac-utils/panelgroups"
	varGroupBuilder "github.com/perses/perses/cue/dac-utils/variable/group"
	panelBuilder "github.com/perses/plugins/prometheus/sdk/cue/panel"
	promQuery "github.com/perses/plugins/prometheus/schemas/prometheus-time-series-query:model"
	staticListVarBuilder "github.com/perses/plugins/staticlistvariable/sdk/cue:staticlist"
)

// Combined days-to-exhaustion, capped so +Inf (stable or growing capacity)
// renders at the gauge maximum instead of overflowing the dial.
#daysToExhaustion: "clamp_max(cluster:days_to_exhaustion_$observation_period:days, 365)"

#trendQuery: {
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

dashboardBuilder & {
	#name:    "capacity-exhaustion"
	#project: "openshift-operators"
	#display: {
		name:        "Time to Capacity Exhaustion"
		description: "Days until the cluster runs out of schedulable capacity based on recent trends."
	}
	#duration: "6h"

	#variables: {varGroupBuilder & {
		#input: [
			staticListVarBuilder & {
				#name: "observation_period"
				#display: name: "Observation period"
				#values: [
					{value: "7d", label: "7 days"},
					{value: "30d", label: "30 days"},
					{value: "180d", label: "180 days"},
					{value: "360d", label: "360 days"},
				]
				// CUE schema is {singleValue, sliceValues}. kustomize
				// flattens this to a string for the Perses operator.
				variable: spec: defaultValue: singleValue: "30d"
			},
		]
	}}.variables

	#panelGroups: panelGroupsBuilder & {
		#input: [
			{
				#title: "Current Estimate"
				#cols:  1
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "Days to Exhaustion"
								description: "Days until the cluster runs out of capacity (whichever resource exhausts first). Gauge capped at 365; values at max mean capacity is stable or growing."
							}
							plugin: {
								kind: "GaugeChart"
								spec: {
									calculation: "last-number"
									format: {
										unit:          "decimal"
										decimalPlaces: 0
									}
									max: 365
									thresholds: steps: [
										{value: 0, color:  "#f53636"},
										{value: 30, color: "#ed8128"},
										{value: 90, color: "#32ac2d"},
									]
								}
							}
							queries: [
								{
									kind: "TimeSeriesQuery"
									spec: plugin: promQuery & {
										spec: query: #daysToExhaustion
									}
								},
							]
						}
					},
				]
			},
			{
				#title:  "Trend"
				#cols:   1
				#height: 12
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "Days to Exhaustion Trend"
								description: "How the estimated days until exhaustion has changed over time for memory and CPU. Lines disappear when capacity is stable or growing (+Inf)."
							}
							plugin: {
								kind: "TimeSeriesChart"
								spec: {
									legend: {
										position: "bottom"
										mode:     "list"
									}
									yAxis: format: {
										unit:          "decimal"
										decimalPlaces: 0
									}
								}
							}
							queries: [
								#trendQuery & {
									#segment: "Memory"
									#query:   "cluster:days_to_exhaustion_memory_$observation_period:days"
								},
								#trendQuery & {
									#segment: "CPU"
									#query:   "cluster:days_to_exhaustion_cpu_$observation_period:days"
								},
							]
						}
					},
				]
			},
		]
	}
}
