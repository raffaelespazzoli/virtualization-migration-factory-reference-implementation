package dac

import (
	dashboardBuilder "github.com/perses/perses/cue/dac-utils/dashboard"
	panelGroupsBuilder "github.com/perses/perses/cue/dac-utils/panelgroups"
	varGroupBuilder "github.com/perses/perses/cue/dac-utils/variable/group"
	panelBuilder "github.com/perses/plugins/prometheus/sdk/cue/panel"
	promQuery "github.com/perses/plugins/prometheus/schemas/prometheus-time-series-query:model"
	statChart "github.com/perses/plugins/statchart/schemas:model"
	table "github.com/perses/plugins/table/schemas:model"
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

// ── PromQL fragments ────────────────────────────────────────────────
//
// Recording rules pre-compute cluster-wide aggregates as time series:
//   cluster:vm_memory_actual_used:bytes = sum(kubevirt_vmi_memory_used_bytes)
//   cluster:vm_cpu_actual_used:cores    = sum(rate(kubevirt_vmi_cpu_usage_seconds_total[5m]))
//
// This lets stddev_over_time() and quantile_over_time() read from
// TSDB rather than re-evaluating the sum at every 5m step over the
// observation window (up to 8 640 evaluations for 30d).

// ── Approach 1: Empirical (no assumptions) ──────────────────────────
// Direct historical quantile of the aggregate usage series.
// No distributional or independence assumptions.
#memEmpirical: """
	sum(kubevirt_vmi_memory_domain_bytes)
	/
	quantile_over_time($risk_quantile,
	  cluster:vm_memory_actual_used:bytes[$observation_period]
	)
	"""

#cpuEmpirical: """
	sum(vmi:kubevirt_vmi_vcpu:count)
	/
	quantile_over_time($risk_quantile,
	  cluster:vm_cpu_actual_used:cores[$observation_period]
	)
	"""

// ── Approach 2: Normal + actual correlation ─────────────────────────
// mean + z×σ on the aggregate. Captures real VM correlation.
// Assumes the aggregate sum follows a normal distribution.
#memNormal: """
	sum(kubevirt_vmi_memory_domain_bytes)
	/ (
	  avg_over_time(cluster:vm_memory_actual_used:bytes[$observation_period])
	  + $z_score
	    * stddev_over_time(cluster:vm_memory_actual_used:bytes[$observation_period])
	)
	"""

#cpuNormal: """
	sum(vmi:kubevirt_vmi_vcpu:count)
	/ (
	  avg_over_time(cluster:vm_cpu_actual_used:cores[$observation_period])
	  + $z_score
	    * stddev_over_time(cluster:vm_cpu_actual_used:cores[$observation_period])
	)
	"""

// ── Approach 3: Normal + independence ───────────────────────────────
// mean + z×√Σσᵢ².  Diversified stddev is smaller than the actual
// aggregate stddev when VMs are correlated, so this approach gives
// a higher (more optimistic) overcommit than approach 2.
#memIndependence: """
	sum(kubevirt_vmi_memory_domain_bytes)
	/ (
	  sum(avg_over_time(kubevirt_vmi_memory_used_bytes[$observation_period]))
	  + $z_score
	    * sqrt(sum(
	        stddev_over_time(kubevirt_vmi_memory_used_bytes[$observation_period]) ^ 2
	      ))
	)
	"""

#cpuIndependence: """
	sum(vmi:kubevirt_vmi_vcpu:count)
	/ (
	  sum(avg_over_time(
	    rate(kubevirt_vmi_cpu_usage_seconds_total[5m])[$observation_period:5m]
	  ))
	  + $z_score
	    * sqrt(sum(
	        stddev_over_time(
	          rate(kubevirt_vmi_cpu_usage_seconds_total[5m])[$observation_period:5m]
	        ) ^ 2
	      ))
	)
	"""

// ── Approach 4: Chebyshev / Cantelli (distribution-free bound) ──────
// Cantelli inequality: P(X ≥ μ+kσ) ≤ 1/(1+k²) for ANY distribution.
// Solving for k given quantile q (= 1−eviction probability):
//   k = √(q / (1−q))
// Most conservative — makes no distributional assumption.
#memChebyshev: """
	sum(kubevirt_vmi_memory_domain_bytes)
	/ (
	  avg_over_time(cluster:vm_memory_actual_used:bytes[$observation_period])
	  + sqrt(vector($risk_quantile / (1 - $risk_quantile)))
	    * stddev_over_time(cluster:vm_memory_actual_used:bytes[$observation_period])
	)
	"""

#cpuChebyshev: """
	sum(vmi:kubevirt_vmi_vcpu:count)
	/ (
	  avg_over_time(cluster:vm_cpu_actual_used:cores[$observation_period])
	  + sqrt(vector($risk_quantile / (1 - $risk_quantile)))
	    * stddev_over_time(cluster:vm_cpu_actual_used:cores[$observation_period])
	)
	"""

// ── Diagnostics ─────────────────────────────────────────────────────
// Correlation index: actual aggregate σ / independence-assumed σ.
// >1 → VMs correlate (spikes coincide).  ≈1 → independent.
#memCorrelation: """
	stddev_over_time(cluster:vm_memory_actual_used:bytes[$observation_period])
	/
	sqrt(sum(
	  stddev_over_time(kubevirt_vmi_memory_used_bytes[$observation_period]) ^ 2
	))
	"""

#cpuCorrelation: """
	stddev_over_time(cluster:vm_cpu_actual_used:cores[$observation_period])
	/
	sqrt(sum(
	  stddev_over_time(
	    rate(kubevirt_vmi_cpu_usage_seconds_total[5m])[$observation_period:5m]
	  ) ^ 2
	))
	"""

#vmCount: "count(kubevirt_vmi_memory_domain_bytes)"

// ── Per-VM tables (empirical quantile per VM) ───────────────────────
#topMemory: """
	topk(10,
	  sum by (namespace, name) (kubevirt_vmi_memory_domain_bytes)
	  /
	  sum by (namespace, name) (
	    quantile_over_time($risk_quantile, kubevirt_vmi_memory_used_bytes[$observation_period])
	  )
	)
	"""

#topCPU: """
	topk(10,
	  sum by (namespace, name) (vmi:kubevirt_vmi_vcpu:count)
	  /
	  sum by (namespace, name) (
	    quantile_over_time($risk_quantile,
	      rate(kubevirt_vmi_cpu_usage_seconds_total[5m])[$observation_period:5m]
	    )
	  )
	)
	"""

// ── Dashboard ───────────────────────────────────────────────────────

dashboardBuilder & {
	#name:    "vm-overcommit"
	#project: "openshift-operators"
	#display: {
		name: "VM Overcommit"
		description: """
			Statistical overcommit analysis.
			Empirical = historical quantile (no assumptions).
			Normal = parametric (assumes bell-curve aggregate).
			Independence = parametric + uncorrelated VMs (optimistic).
			Chebyshev = Cantelli bound (any distribution, most conservative).
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
				#name:    "risk_quantile"
				#display: name: "Confidence level"
				#values: [
					{value: "0.95", label:  "95% (p=5%)"},
					{value: "0.99", label:  "99% (p=1%)"},
					{value: "0.995", label: "99.5% (p=0.5%)"},
					{value: "0.999", label: "99.9% (p=0.1%)"},
				]
				variable: spec: defaultValue: singleValue: "0.999"
			},
			staticListVarBuilder & {
				#name:    "z_score"
				#display: name: "Normal z-score"
				#values: [
					{value: "1.645", label: "95% (z=1.645)"},
					{value: "2.326", label: "99% (z=2.326)"},
					{value: "2.576", label: "99.5% (z=2.576)"},
					{value: "3.090", label: "99.9% (z=3.090)"},
				]
				variable: spec: defaultValue: singleValue: "3.090"
			},
		]
	}}.variables

	#panelGroups: panelGroupsBuilder & {
		#input: [
			// ── Row 1: Memory overcommit ratios ─────────────
			{
				#title: "Memory Overcommit Ratio"
				#cols:  4
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "Empirical"
								description: "Granted / quantile of observed aggregate usage. Distribution-free; captures actual VM correlation."
							}
							plugin: statChart & {spec: {calculation: "last-number", format: {unit: "decimal", decimalPlaces: 2}}}
							queries: [{#q & {#query: #memEmpirical, #format: "empirical"}}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Normal"
								description: "Granted / (μ + z×σ) of aggregate. Assumes normal distribution; captures VM correlation."
							}
							plugin: statChart & {spec: {calculation: "last-number", format: {unit: "decimal", decimalPlaces: 2}}}
							queries: [{#q & {#query: #memNormal, #format: "normal"}}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Independence"
								description: "Granted / (μ + z×√Σσᵢ²). Assumes normal + independent VMs. Optimistic if VMs correlate."
							}
							plugin: statChart & {spec: {calculation: "last-number", format: {unit: "decimal", decimalPlaces: 2}}}
							queries: [{#q & {#query: #memIndependence, #format: "independence"}}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Chebyshev"
								description: "Granted / (μ + k×σ) with Cantelli k=√(q/(1−q)). Any distribution, most conservative."
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
				#cols:  4
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "Empirical"
								description: "Granted vCPUs / quantile of aggregate CPU usage."
							}
							plugin: statChart & {spec: {calculation: "last-number", format: {unit: "decimal", decimalPlaces: 2}}}
							queries: [{#q & {#query: #cpuEmpirical, #format: "empirical"}}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Normal"
								description: "Granted vCPUs / (μ + z×σ) of aggregate CPU usage."
							}
							plugin: statChart & {spec: {calculation: "last-number", format: {unit: "decimal", decimalPlaces: 2}}}
							queries: [{#q & {#query: #cpuNormal, #format: "normal"}}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Independence"
								description: "Granted vCPUs / (μ + z×√Σσᵢ²). Assumes independent VMs."
							}
							plugin: statChart & {spec: {calculation: "last-number", format: {unit: "decimal", decimalPlaces: 2}}}
							queries: [{#q & {#query: #cpuIndependence, #format: "independence"}}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Chebyshev"
								description: "Granted vCPUs / (μ + k×σ) with Cantelli bound."
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
				#cols:  3
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "Memory correlation"
								description: "σ_actual / σ_independent. >1 = VMs correlate (spikes coincide). ≈1 = independent. Explains the gap between Normal and Independence."
							}
							plugin: statChart & {spec: {calculation: "last-number", format: {unit: "decimal", decimalPlaces: 2}}}
							queries: [{#q & {#query: #memCorrelation, #format: "ρ"}}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "CPU correlation"
								description: "Same ratio for CPU."
							}
							plugin: statChart & {spec: {calculation: "last-number", format: {unit: "decimal", decimalPlaces: 2}}}
							queries: [{#q & {#query: #cpuCorrelation, #format: "ρ"}}]
						}
					},
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
								description: "All four approaches over time. The spread between lines shows how much the choice of method matters."
							}
							plugin: #trendChart
							queries: [
								{#q & {#query: #memEmpirical, #format: "Empirical"}},
								{#q & {#query: #memNormal, #format: "Normal"}},
								{#q & {#query: #memIndependence, #format: "Independence"}},
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
								description: "All four approaches over time."
							}
							plugin: #trendChart
							queries: [
								{#q & {#query: #cpuEmpirical, #format: "Empirical"}},
								{#q & {#query: #cpuNormal, #format: "Normal"}},
								{#q & {#query: #cpuIndependence, #format: "Independence"}},
								{#q & {#query: #cpuChebyshev, #format: "Chebyshev"}},
							]
						}
					},
				]
			},

			// ── Row 6: Per-VM tables ────────────────────────
			{
				#title:  "Most Overestimated VMs"
				#cols:   2
				#height: 12
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "Memory"
								description: "The ten VMs whose granted memory is largest relative to the selected quantile of actual usage."
							}
							plugin: table & {
								spec: {
									density: "compact"
									columnSettings: [
										{name: "namespace", header: "Namespace", enableSorting: true},
										{name: "name", header: "VM", enableSorting: true},
										{
											name:          "value"
											header:        "Overcommit ratio"
											enableSorting: true
											sort:          "desc"
											format: {unit: "decimal", decimalPlaces: 2}
										},
										{name: "timestamp", hide: true},
									]
								}
							}
							queries: [{#q & {#query: #topMemory, #format: "{{namespace}}/{{name}}"}}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "CPU"
								description: "The ten VMs whose granted vCPUs are largest relative to the selected quantile of CPU usage."
							}
							plugin: table & {
								spec: {
									density: "compact"
									columnSettings: [
										{name: "namespace", header: "Namespace", enableSorting: true},
										{name: "name", header: "VM", enableSorting: true},
										{
											name:          "value"
											header:        "Overcommit ratio"
											enableSorting: true
											sort:          "desc"
											format: {unit: "decimal", decimalPlaces: 2}
										},
										{name: "timestamp", hide: true},
									]
								}
							}
							queries: [{#q & {#query: #topCPU, #format: "{{namespace}}/{{name}}"}}]
						}
					},
				]
			},
		]
	}
}
