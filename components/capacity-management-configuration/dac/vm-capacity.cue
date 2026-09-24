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

// How many more guests of the selected shape fit.
// Division and multiplication are left-associative: (available / size) * overcommit.
// clamp_max(v, scalar(limit)) is the smaller of the two counts. OpenShift
// Prometheus parses min() as an aggregator, so min(a, b) is a query error.
#vmsThatFit: """
	floor(clamp_max(
	  cluster:available_capacity_memory:bytes / $vm_memory * $memory_overcommit,
	  scalar(cluster:available_capacity_cpu:cores / $vm_cpu * $cpu_overcommit)
	))
	"""

// 1 when CPU is the tighter limit, 0 when memory is. StatChart mappings
// turn that into "CPU bound" / "Memory bound".
#limitedBy: """
	(
	  cluster:available_capacity_memory:bytes / $vm_memory * $memory_overcommit
	  > bool
	  scalar(cluster:available_capacity_cpu:cores / $vm_cpu * $cpu_overcommit)
	)
	"""

// COO Perses ships BarChart 0.11.1, which has no stacking fields.
// TimeSeriesChart visual.stack=all is the stacked column that version accepts.
// seriesNameFormat is the segment name. Non-VM + VM + available equals total.
#stackedQuery: {
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

#capacityChart: {
	#unit: string
	kind:  "TimeSeriesChart"
	spec: {
		legend: {
			position: "bottom"
			mode:     "list"
		}
		visual: {
			display: "bar"
			stack:   "all"
		}
		yAxis: format: unit: #unit
	}
}

dashboardBuilder & {
	#name:    "vm-capacity"
	#project: "openshift-operators"
	#display: {
		name:        "How many VMs fit"
		description: "How many more virtual machines of a chosen shape fit in the remaining schedulable capacity."
	}
	#duration: "1h"

	#variables: {varGroupBuilder & {
		#input: [
			staticListVarBuilder & {
				#name: "vm_memory"
				#display: name: "VM memory"
				#values: [
					{value: "4294967296", label: "4 GiB"},
					{value: "8589934592", label: "8 GiB"},
					{value: "17179869184", label: "16 GiB"},
					{value: "34359738368", label: "32 GiB"},
					{value: "68719476736", label: "64 GiB"},
				]
				// CUE schema is {singleValue, sliceValues}. kustomize
				// flattens this to a string for the Perses operator.
				variable: spec: defaultValue: singleValue: "8589934592"
			},
			staticListVarBuilder & {
				#name: "vm_cpu"
				#display: name: "VM CPU"
				#values: [
					{value: "1", label: "1 vCPU"},
					{value: "2", label: "2 vCPU"},
					{value: "4", label: "4 vCPU"},
					{value: "8", label: "8 vCPU"},
					{value: "16", label: "16 vCPU"},
				]
				variable: spec: defaultValue: singleValue: "4"
			},
			staticListVarBuilder & {
				#name: "memory_overcommit"
				#display: name: "Memory overcommit"
				#values: ["1", "1.5", "2", "2.5", "3", "4"]
				variable: spec: defaultValue: singleValue: "1"
			},
			staticListVarBuilder & {
				#name: "cpu_overcommit"
				#display: name: "CPU overcommit"
				#values: ["1", "2", "4", "6", "8", "10", "12"]
				variable: spec: defaultValue: singleValue: "1"
			},
		]
	}}.variables

	#panelGroups: panelGroupsBuilder & {
		#input: [
			{
				#title: "How many more VMs fit"
				#cols:  3
				#panels: [
					panelBuilder & {
						spec: {
							display: name: "VMs that fit"
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {
										unit:          "decimal"
										decimalPlaces: 0
									}
								}
							}
							queries: [
								{
									kind: "TimeSeriesQuery"
									spec: plugin: promQuery & {
										spec: query: #vmsThatFit
									}
								},
							]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Limited by"
								description: "Whether remaining capacity runs out of memory or CPU first for the selected VM shape."
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {
										unit:          "decimal"
										decimalPlaces: 0
									}
									mappings: [
										{
											kind: "Range"
											spec: {
												from: 0
												to:   0.5
												result: value: "Memory bound"
											}
										},
										{
											kind: "Range"
											spec: {
												from: 0.5
												to:   1.5
												result: value: "CPU bound"
											}
										},
									]
								}
							}
							queries: [
								{
									kind: "TimeSeriesQuery"
									spec: plugin: promQuery & {
										spec: query: #limitedBy
									}
								},
							]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Memory / CPU"
								description: "GiB of memory request per CPU request. The node shape that matches the current workload."
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
											query:            "cluster:memory_cpu_ratio:gib_per_core"
											seriesNameFormat: "GiB per core"
										}
									}
								},
							]
						}
					},
				]
			},
			{
				#title:  "Capacity"
				#cols:   2
				#height: 12
				#panels: [
					panelBuilder & {
						spec: {
							display: name: "Memory"
							plugin: #capacityChart & {#unit: "bytes"}
							queries: [
								#stackedQuery & {
									#segment: "Non-VM used"
									#query:   "cluster:non_vm_used_capacity_memory:bytes"
								},
								#stackedQuery & {
									#segment: "VM used"
									#query:   "cluster:vm_used_capacity_memory:bytes"
								},
								#stackedQuery & {
									#segment: "Available"
									#query:   "cluster:available_capacity_memory:bytes"
								},
							]
						}
					},
					panelBuilder & {
						spec: {
							display: name: "CPU"
							plugin: #capacityChart & {#unit: "decimal"}
							queries: [
								#stackedQuery & {
									#segment: "Non-VM used"
									#query:   "cluster:non_vm_used_capacity_cpu:cores"
								},
								#stackedQuery & {
									#segment: "VM used"
									#query:   "cluster:vm_used_capacity_cpu:cores"
								},
								#stackedQuery & {
									#segment: "Available"
									#query:   "cluster:available_capacity_cpu:cores"
								},
							]
						}
					},
				]
			},
		]
	}
}
