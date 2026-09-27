package dac

import (
	dashboardBuilder "github.com/perses/perses/cue/dac-utils/dashboard"
	panelGroupsBuilder "github.com/perses/perses/cue/dac-utils/panelgroups"
	varGroupBuilder "github.com/perses/perses/cue/dac-utils/variable/group"
	panelBuilder "github.com/perses/plugins/prometheus/sdk/cue/panel"
	promQuery "github.com/perses/plugins/prometheus/schemas/prometheus-time-series-query:model"
	labelValuesVarBuilder "github.com/perses/plugins/prometheus/sdk/cue/variable/labelvalues"
	statChart "github.com/perses/plugins/statchart/schemas:model"
)

// ── Chart templates ─────────────────────────────────────────────────
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

#lineChart: {
	kind: "TimeSeriesChart"
	spec: {
		legend: {
			position: "bottom"
			mode:     "list"
		}
		visual: {
			display:    "line"
			areaOpacity: 0
			lineWidth:   2
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
_f: "name=~\"$vm\", namespace=~\"$namespace\""

// ── PromQL fragments ────────────────────────────────────────────────

// Panel 1: VM memory decomposition (4 stacked layers summing to domain)
//
//   domain = kernel_reserved + used + reclaimable + free
//   where:
//     kernel_reserved = domain - available
//     used            = available - usable  (= used_bytes)
//     reclaimable     = usable - unused
//     free            = unused

#kernelReserved: """
	kubevirt_vmi_memory_domain_bytes{\( _f )}
	- kubevirt_vmi_memory_available_bytes{\( _f )}
	"""

#used:        "kubevirt_vmi_memory_used_bytes{" + _f + "}"
#reclaimable: "kubevirt_vmi_memory_usable_bytes{" + _f + "} - kubevirt_vmi_memory_unused_bytes{" + _f + "}"
#free:        "kubevirt_vmi_memory_unused_bytes{" + _f + "}"
#domain:      "kubevirt_vmi_memory_domain_bytes{" + _f + "}"
#available:   "kubevirt_vmi_memory_available_bytes{" + _f + "}"

// Panel 2: Launcher overhead — estimated vs actual
//
// Estimated = kubevirt_vmi_launcher_memory_overhead_bytes (virt-controller prediction)
// Actual    = vmi:virt_launcher_overhead_memory:bytes     (recording rule:
//             sum(working_set of all containers) − sum(resident_bytes))
//
// When actual exceeds estimated the pod's memory request may be too tight.

#overheadEstimated: "kubevirt_vmi_launcher_memory_overhead_bytes{" + _f + "}"
#overheadActual:    "vmi:virt_launcher_overhead_memory:bytes{" + _f + "}"

// Overhead delta: estimated − actual.  Positive = headroom, negative = under-estimated.
#overheadDelta: """
	scalar(kubevirt_vmi_launcher_memory_overhead_bytes{\( _f )})
	- scalar(vmi:virt_launcher_overhead_memory:bytes{\( _f )})
	"""

// Summary stats
#utilization: """
	kubevirt_vmi_memory_used_bytes{\( _f )}
	/ kubevirt_vmi_memory_available_bytes{\( _f )}
	"""

// ── Dashboard ───────────────────────────────────────────────────────

dashboardBuilder & {
	#name:    "vm-memory"
	#project: "openshift-operators"
	#display: {
		name:        "VM Memory"
		description: "Guest memory decomposition (kernel, non-reclaimable, reclaimable, free) and launcher overhead: estimated vs actual."
	}
	#duration: "6h"

	#variables: {varGroupBuilder & {
		#input: [
			labelValuesVarBuilder & {
				#name:     "namespace"
				#display:  name: "Namespace"
				#metric:   "kubevirt_vmi_memory_available_bytes"
				#label:    "namespace"
				#allowAllValue: false
				#allowMultiple: false
			},
			labelValuesVarBuilder & {
				#name:     "vm"
				#display:  name: "VM"
				#label:    "name"
				#query:    "kubevirt_vmi_memory_available_bytes{namespace=~\"$namespace\"}"
				#allowAllValue: false
				#allowMultiple: false
			},
		]
	}}.variables

	#panelGroups: panelGroupsBuilder & {
		#input: [
			// ── Row 1: Summary stats ────────────────────────
			{
				#title: "Summary"
				#cols:  5
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "Domain"
								description: "Total memory allocated to the QEMU domain — the VM's configured size."
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: { unit: "bytes", decimalPlaces: 1 }
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {
									spec: query: #domain
								}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Available (MemTotal)"
								description: "Usable memory inside the guest — domain minus kernel reserved."
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: { unit: "bytes", decimalPlaces: 1 }
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {
									spec: query: #available
								}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Used (non-reclaimable)"
								description: "Memory actively in use — cannot be freed without swap or OOM."
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: { unit: "bytes", decimalPlaces: 1 }
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {
									spec: query: #used
								}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Utilization"
								description: "used / available — how close to guest OOM."
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: { unit: "percent-decimal", decimalPlaces: 1 }
									thresholds: steps: [
										{ value: 0, color: "#32ac2d" },
										{ value: 80, color: "#ed8128" },
										{ value: 95, color: "#f53636" },
									]
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {
									spec: query: #utilization + " * 100"
								}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Overhead Δ"
								description: "Estimated overhead minus actual overhead. Positive = headroom. Negative = virt-controller under-estimated."
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: { unit: "bytes", decimalPlaces: 1 }
									thresholds: steps: [
										{ value: -536870912, color: "#f53636" },
										{ value: 0, color: "#ed8128" },
										{ value: 104857600, color: "#32ac2d" },
									]
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {
									spec: query: #overheadDelta
								}
							}]
						}
					},
				]
			},
			// ── Row 2: Decomposition + Overhead ─────────────
			{
				#title: "Memory Decomposition"
				#cols:  2
				#panels: [
					// Panel 1: Guest memory decomposition (stacked)
					panelBuilder & {
						spec: {
							display: {
								name:        "Guest Memory Decomposition"
								description: "Four layers summing to domain: kernel reserved + non-reclaimable + reclaimable + free."
							}
							plugin: #stackedAreaChart & {
								spec: {
									visual: lineWidth: 2
									querySettings: [
										// Domain threshold
										{
											queryIndex:  4
											colorMode:   "fixed-single"
											colorValue:  "#FFFFFF"
											lineStyle:   "dotted"
											stack:       false
											areaOpacity: 0
										},
									]
								}
							}
							queries: [
								#memQuery & { #query: #kernelReserved, #segment: "Kernel reserved" },
								#memQuery & { #query: #used, #segment:           "Non-reclaimable (used)" },
								#memQuery & { #query: #reclaimable, #segment:    "Reclaimable" },
								#memQuery & { #query: #free, #segment:           "Free" },
								#memQuery & { #query: #domain, #segment:         "── Domain (configured)" },
							]
						}
					},
					// Panel 2: Overhead — estimated vs actual (line chart)
					panelBuilder & {
						spec: {
							display: {
								name:        "Launcher Overhead: Estimated vs Actual"
								description: "Estimated = virt-controller prediction. Actual = pod working_set minus guest RSS (recording rule). When actual exceeds estimated, the overhead budget is too tight."
							}
							plugin: #lineChart & {
								spec: {
									querySettings: [
										{
											queryIndex:  0
											colorMode:   "fixed-single"
											colorValue:  "#32ac2d"
											lineStyle:   "dotted"
										},
										{
											queryIndex:  1
											colorMode:   "fixed-single"
											colorValue:  "#2E79B5"
										},
									]
								}
							}
							queries: [
								#memQuery & { #query: #overheadEstimated, #segment: "Estimated overhead" },
								#memQuery & { #query: #overheadActual, #segment:    "Actual overhead" },
							]
						}
					},
				]
			},
		]
	}
}
