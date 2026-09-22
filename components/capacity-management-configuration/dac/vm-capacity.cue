package dac

import (
	dashboardBuilder "github.com/perses/perses/cue/dac-utils/dashboard"
	panelGroupsBuilder "github.com/perses/perses/cue/dac-utils/panelgroups"
	varGroupBuilder "github.com/perses/perses/cue/dac-utils/variable/group"
	panelBuilder "github.com/perses/plugins/prometheus/sdk/cue/panel"
	barChart "github.com/perses/plugins/barchart/schemas:model"
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

// sum by (resource) drops every label except the shared category, so the
// stacked bar uses seriesNameFormat as the segment name. Non-VM + VM +
// available equals cluster total capacity.
#stackedQuery: {
	#query:  string
	#segment: string
	kind: "TimeSeriesQuery"
	spec: plugin: promQuery & {
		spec: {
			query:            #query
			seriesNameFormat: #segment
		}
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
				#values: ["1", "1.5", "2"]
				variable: spec: defaultValue: singleValue: "1"
			},
			staticListVarBuilder & {
				#name: "cpu_overcommit"
				#display: name: "CPU overcommit"
				#values: ["1", "2", "4", "10"]
				variable: spec: defaultValue: singleValue: "1"
			},
		]
	}}.variables

	#panelGroups: panelGroupsBuilder & {
		#input: [
			{
				#title: "How many more VMs fit"
				#cols:  1
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
				]
			},
			{
				#title:  "Capacity"
				#cols:   2
				#height: 10
				#panels: [
					panelBuilder & {
						spec: {
							display: name: "Memory"
							plugin: barChart & {
								spec: {
									calculation: "last-number"
									orientation: "vertical"
									isStacked:   true
									groupBy: ["resource"]
									format: unit: "bytes"
								}
							}
							queries: [
								#stackedQuery & {
									#segment: "Non-VM used"
									#query: """
										sum by (resource) (
										  label_replace(cluster:non_vm_used_capacity_memory:bytes, "resource", "Memory", "__name__", ".+")
										)
										"""
								},
								#stackedQuery & {
									#segment: "VM used"
									#query: """
										sum by (resource) (
										  label_replace(cluster:vm_used_capacity_memory:bytes, "resource", "Memory", "__name__", ".+")
										)
										"""
								},
								#stackedQuery & {
									#segment: "Available"
									#query: """
										sum by (resource) (
										  label_replace(cluster:available_capacity_memory:bytes, "resource", "Memory", "__name__", ".+")
										)
										"""
								},
							]
						}
					},
					panelBuilder & {
						spec: {
							display: name: "CPU"
							plugin: barChart & {
								spec: {
									calculation: "last-number"
									orientation: "vertical"
									isStacked:   true
									groupBy: ["resource"]
									format: unit: "decimal"
								}
							}
							queries: [
								#stackedQuery & {
									#segment: "Non-VM used"
									#query: """
										sum by (resource) (
										  label_replace(cluster:non_vm_used_capacity_cpu:cores, "resource", "CPU", "__name__", ".+")
										)
										"""
								},
								#stackedQuery & {
									#segment: "VM used"
									#query: """
										sum by (resource) (
										  label_replace(cluster:vm_used_capacity_cpu:cores, "resource", "CPU", "__name__", ".+")
										)
										"""
								},
								#stackedQuery & {
									#segment: "Available"
									#query: """
										sum by (resource) (
										  label_replace(cluster:available_capacity_cpu:cores, "resource", "CPU", "__name__", ".+")
										)
										"""
								},
							]
						}
					},
				]
			},
		]
	}
}
