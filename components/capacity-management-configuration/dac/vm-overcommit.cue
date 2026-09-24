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

// Cluster packing: granted guest memory vs selected-percentile used over the window.
#memoryOvercommit: """
	sum(kubevirt_vmi_memory_domain_bytes)
	/
	sum(
	  quantile_over_time($quantile, kubevirt_vmi_memory_used_bytes[$observation_period])
	)
	"""

// Cluster packing: allocated vCPUs vs selected-percentile QEMU usage over the window.
// Subquery is required because quantile_over_time cannot wrap rate() directly.
#cpuOvercommit: """
	sum(vmi:kubevirt_vmi_vcpu:count)
	/
	sum(
	  quantile_over_time(
	    $quantile,
	    rate(kubevirt_vmi_cpu_usage_seconds_total[5m])[$observation_period:5m]
	  )
	)
	"""

// Per-VM ratio, ranked. sum by keeps namespace and name as table columns
// and drops pod/job/instance labels that would otherwise mismatch the divide.
#topMemory: """
	topk(10,
	  sum by (namespace, name) (kubevirt_vmi_memory_domain_bytes)
	  /
	  sum by (namespace, name) (
	    quantile_over_time($quantile, kubevirt_vmi_memory_used_bytes[$observation_period])
	  )
	)
	"""

#topCPU: """
	topk(10,
	  sum by (namespace, name) (vmi:kubevirt_vmi_vcpu:count)
	  /
	  sum by (namespace, name) (
	    quantile_over_time(
	      $quantile,
	      rate(kubevirt_vmi_cpu_usage_seconds_total[5m])[$observation_period:5m]
	    )
	  )
	)
	"""

dashboardBuilder & {
	#name:    "vm-overcommit"
	#project: "openshift-operators"
	#display: {
		name:        "VM Overcommit"
		description: "Suggested cluster overcommit ratios from granted vs actual VM usage, and the VMs with the largest unused allocation."
	}
	#duration: "5m"

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
			staticListVarBuilder & {
				#name: "quantile"
				#display: name: "Quantile"
				#values: [
					{value: "0.90", label: "90th percentile"},
					{value: "0.95", label: "95th percentile"},
					{value: "0.99", label: "99th percentile"},
				]
				variable: spec: defaultValue: singleValue: "0.95"
			},
		]
	}}.variables

	#panelGroups: panelGroupsBuilder & {
		#input: [
			{
				#title: "Suggested overcommit"
				#cols:  2
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "Memory"
								description: "Total guest domain memory divided by the selected percentile of used memory over the observation period."
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {
										unit:          "decimal"
										decimalPlaces: 2
									}
								}
							}
							queries: [
								{
									kind: "TimeSeriesQuery"
									spec: plugin: promQuery & {
										spec: {
											query:            #memoryOvercommit
											seriesNameFormat: "memory overcommit"
											minStep:          "5m"
										}
									}
								},
							]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "CPU"
								description: "Total allocated vCPUs divided by the selected percentile of QEMU CPU usage over the observation period."
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {
										unit:          "decimal"
										decimalPlaces: 2
									}
								}
							}
							queries: [
								{
									kind: "TimeSeriesQuery"
									spec: plugin: promQuery & {
										spec: {
											query:            #cpuOvercommit
											seriesNameFormat: "cpu overcommit"
											minStep:          "5m"
										}
									}
								},
							]
						}
					},
				]
			},
			{
				#title:  "Most overestimated VMs"
				#cols:   2
				#height: 12
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "Memory"
								description: "The ten VMs whose domain memory is largest relative to used memory over the observation period."
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
											format: {
												unit:          "decimal"
												decimalPlaces: 2
											}
										},
										{name: "timestamp", hide: true},
									]
								}
							}
							queries: [
								{
									kind: "TimeSeriesQuery"
									spec: plugin: promQuery & {
										spec: {
											query:            #topMemory
											seriesNameFormat: "{{namespace}}/{{name}}"
											minStep:          "5m"
										}
									}
								},
							]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "CPU"
								description: "The ten VMs whose allocated vCPUs are largest relative to QEMU CPU usage over the observation period."
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
											format: {
												unit:          "decimal"
												decimalPlaces: 2
											}
										},
										{name: "timestamp", hide: true},
									]
								}
							}
							queries: [
								{
									kind: "TimeSeriesQuery"
									spec: plugin: promQuery & {
										spec: {
											query:            #topCPU
											seriesNameFormat: "{{namespace}}/{{name}}"
											minStep:          "5m"
										}
									}
								},
							]
						}
					},
				]
			},
		]
	}
}
