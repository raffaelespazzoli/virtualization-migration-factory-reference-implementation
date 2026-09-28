package dac

import (
	dashboardBuilder "github.com/perses/perses/cue/dac-utils/dashboard"
	panelGroupsBuilder "github.com/perses/perses/cue/dac-utils/panelgroups"
	varGroupBuilder "github.com/perses/perses/cue/dac-utils/variable/group"
	panelBuilder "github.com/perses/plugins/prometheus/sdk/cue/panel"
	promQuery "github.com/perses/plugins/prometheus/schemas/prometheus-time-series-query:model"
	statChart "github.com/perses/plugins/statchart/schemas:model"
	staticListVarBuilder "github.com/perses/plugins/staticlistvariable/sdk/cue:staticlist"
)

// ── Chart template ──────────────────────────────────────────────────
#trendChart: {
	kind: "TimeSeriesChart"
	spec: {
		legend: {position: "bottom", mode: "list"}
		visual: {display: "line", areaOpacity: 0, lineWidth: 2}
		yAxis: format: unit: "decimal"
	}
}

// ── Query helper ────────────────────────────────────────────────────
#q: {
	#query:  string
	#format: string
	kind:    "TimeSeriesQuery"
	spec: plugin: promQuery & {
		spec: {
			query:            #query
			seriesNameFormat: #format
			minStep:          "5m"
		}
	}
}

// ── PromQL building blocks ──────────────────────────────────────────
//
// Recording rules pre-compute cluster-wide aggregates:
//   cluster:vm_memory_actual_used:bytes = sum(kubevirt_vmi_memory_used_bytes)
//   cluster:vm_cpu_actual_used:cores    = sum(rate(kubevirt_vmi_cpu_usage_seconds_total[5m]))
//
// Both approaches compute σ the same way: stddev_over_time on the
// aggregate recording rule.  They differ only in the multiplier:
//   Normal    → z  (from the standard normal distribution table)
//   Chebyshev → k = √(q / (1−q))  (Cantelli inequality, any distribution)
//
// sum() around *_over_time() strips Thanos external labels so that
// binary ops with label-free numerators produce results.

// z-score lookup: maps $confidence → z using a discrete table.
// PromQL has no inverse-normal-CDF, so we use == bool matching.
_z: "((vector($confidence) == bool 0.95) * 1.645 + (vector($confidence) == bool 0.99) * 2.326 + (vector($confidence) == bool 0.995) * 2.576 + (vector($confidence) == bool 0.999) * 3.090 + (vector($confidence) == bool 0.9995) * 3.291 + (vector($confidence) == bool 0.9999) * 3.719)"

// ── Normal approach ─────────────────────────────────────────────────
// Overcommit = Granted / (μ + z × σ)
#memNormal: """
	sum(kubevirt_vmi_memory_domain_bytes)
	/ (
	  sum(avg_over_time(cluster:vm_memory_actual_used:bytes[$observation_period]))
	  + \(_z)
	    * sum(stddev_over_time(cluster:vm_memory_actual_used:bytes[$observation_period]))
	)
	"""

#cpuNormal: """
	sum(vmi:kubevirt_vmi_vcpu:count)
	/ (
	  sum(avg_over_time(cluster:vm_cpu_actual_used:cores[$observation_period]))
	  + \(_z)
	    * sum(stddev_over_time(cluster:vm_cpu_actual_used:cores[$observation_period]))
	)
	"""

// ── Chebyshev / Cantelli approach ───────────────────────────────────
// Overcommit = Granted / (μ + k × σ)   where k = √(q / (1−q))
#memChebyshev: """
	sum(kubevirt_vmi_memory_domain_bytes)
	/ (
	  sum(avg_over_time(cluster:vm_memory_actual_used:bytes[$observation_period]))
	  + sqrt(vector($confidence / (1 - $confidence)))
	    * sum(stddev_over_time(cluster:vm_memory_actual_used:bytes[$observation_period]))
	)
	"""

#cpuChebyshev: """
	sum(vmi:kubevirt_vmi_vcpu:count)
	/ (
	  sum(avg_over_time(cluster:vm_cpu_actual_used:cores[$observation_period]))
	  + sqrt(vector($confidence / (1 - $confidence)))
	    * sum(stddev_over_time(cluster:vm_cpu_actual_used:cores[$observation_period]))
	)
	"""

// ── Diagnostics ─────────────────────────────────────────────────────
#vmCount: "count(kubevirt_vmi_memory_domain_bytes)"

// ── Dashboard ───────────────────────────────────────────────────────

dashboardBuilder & {
	#name:    "vm-overcommit"
	#project: "perses"
	#display: {
		name: "VM Overcommit"
		description: """
			Statistical overcommit analysis based on observed aggregate VM usage volatility.
			Normal = assumes bell-curve distribution for VM load.
			Chebyshev = no assumption on distribution, but more conservative.
			Both use the same mean (μ) and standard deviation (σ) computed over the observation period.
			"""
	}
	#duration: "5m"

	#variables: {varGroupBuilder & {
		#input: [
			staticListVarBuilder & {
				#name:    "observation_period"
				#display: name: "Observation period"
				#values: [
					{value: "7d", label: "7 days"},
					{value: "30d", label: "30 days"},
					{value: "180d", label: "180 days"},
					{value: "360d", label: "360 days"},
				]
				variable: spec: defaultValue: singleValue: "30d"
			},
			staticListVarBuilder & {
				#name:    "confidence"
				#display: name: "Confidence level"
				#values: [
					{value: "0.95", label:   "95%"},
					{value: "0.99", label:   "99%"},
					{value: "0.995", label:  "99.5%"},
					{value: "0.999", label:  "99.9%"},
					{value: "0.9995", label: "99.95%"},
					{value: "0.9999", label: "99.99%"},
				]
				variable: spec: defaultValue: singleValue: "0.999"
			},
		]
	}}.variables

	#panelGroups: panelGroupsBuilder & {
		#input: [
			// ── Row 1: Memory overcommit ratios ─────────────
			{
				#title: "Memory Overcommit Ratio"
				#cols:  2
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "Normal — assumes normal distribution for VM load"
								description: "Overcommit = Granted / (μ + z×σ). The z-score is looked up from the standard normal table for the selected confidence level."
							}
							plugin: statChart & {spec: {calculation: "last-number", format: {unit: "decimal", decimalPlaces: 2}}}
							queries: [{#q & {#query: #memNormal, #format: "normal"}}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Chebyshev — no assumption on load distribution, more conservative"
								description: "Overcommit = Granted / (μ + k×σ) where k = √(q/(1−q)). The Cantelli inequality guarantees this bound for any distribution shape."
							}
							plugin: statChart & {spec: {calculation: "last-number", format: {unit: "decimal", decimalPlaces: 2}}}
							queries: [{#q & {#query: #memChebyshev, #format: "chebyshev"}}]
						}
					},
				]
			},

			// ── Row 2: CPU overcommit ratios ────────────────
			{
				#title: "CPU Overcommit Ratio"
				#cols:  2
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "Normal — assumes normal distribution for VM load"
								description: "Overcommit = Granted / (μ + z×σ). The z-score is looked up from the standard normal table for the selected confidence level."
							}
							plugin: statChart & {spec: {calculation: "last-number", format: {unit: "decimal", decimalPlaces: 2}}}
							queries: [{#q & {#query: #cpuNormal, #format: "normal"}}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Chebyshev — no assumption on load distribution, more conservative"
								description: "Overcommit = Granted / (μ + k×σ) where k = √(q/(1−q)). The Cantelli inequality guarantees this bound for any distribution shape."
							}
							plugin: statChart & {spec: {calculation: "last-number", format: {unit: "decimal", decimalPlaces: 2}}}
							queries: [{#q & {#query: #cpuChebyshev, #format: "chebyshev"}}]
						}
					},
				]
			},

			// ── Row 3: Diagnostics ──────────────────────────
			{
				#title: "Diagnostics"
				#cols:  1
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "VM count"
								description: "Number of running VMs contributing to the aggregate."
							}
							plugin: statChart & {spec: {calculation: "last-number", format: {unit: "decimal", decimalPlaces: 0}}}
							queries: [{#q & {#query: #vmCount, #format: "VMs"}}]
						}
					},
				]
			},

			// ── Row 4: Memory overcommit trend ──────────────
			{
				#title:  "Memory Overcommit Trend"
				#cols:   1
				#height: 12
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "Memory"
								description: "Both approaches over time. The gap shows how much the distributional assumption matters."
							}
							plugin: #trendChart
							queries: [
								{#q & {#query: #memNormal, #format: "Normal"}},
								{#q & {#query: #memChebyshev, #format: "Chebyshev"}},
							]
						}
					},
				]
			},

			// ── Row 5: CPU overcommit trend ──────────────────
			{
				#title:  "CPU Overcommit Trend"
				#cols:   1
				#height: 12
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "CPU"
								description: "Both approaches over time."
							}
							plugin: #trendChart
							queries: [
								{#q & {#query: #cpuNormal, #format: "Normal"}},
								{#q & {#query: #cpuChebyshev, #format: "Chebyshev"}},
							]
						}
					},
				]
			},
		]
	}
}
