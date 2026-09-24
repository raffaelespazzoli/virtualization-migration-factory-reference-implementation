# Capacity Management Configuration

Recording rules that turn kube-state-metrics and kubelet cAdvisor data into cluster capacity and usage numbers for OpenShift Virtualization. The rules run on every cluster in the prod group and are evaluated by the platform Prometheus, so Thanos Querier (and Perses) can query them.

## Upstream Project

- **Product:** OpenShift Cluster Monitoring (kube-state-metrics + Prometheus)
- **Documentation:** [Managing metrics](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/monitoring/managing-metrics)

## Configuration

A single `PrometheusRule` named `capacity-management` in `openshift-monitoring`. The labels `prometheus: k8s` and `role: alert-rules` are what the platform Prometheus uses to select rules.

Only nodes labeled `kubevirt.io/schedulable=true` count toward capacity. kube-state-metrics exposes that label as `label_kubevirt_io_schedulable`. Nodes KubeVirt will not place virtual machines on are left out of the totals.

`capacity:nodes_down:count` defaults to `1`. Total capacity subtracts that many copies of the largest schedulable node's allocatable, which keeps headroom for one node failure. Memory is in bytes and CPU is in cores, matching kube-state-metrics.

`sum(...) or vector(0)` is used on the used-capacity rules so a cluster with no matching pod requests records `0` instead of an absent series. Available capacity is then total minus used.

| Recording rule | Meaning |
|----------------|---------|
| `capacity:nodes_down:count` | How many largest nodes to hold back from total capacity |
| `cluster:total_capacity_memory:bytes` | Schedulable memory minus the HA reserve |
| `cluster:used_capacity_memory:bytes` | Memory requests on schedulable nodes |
| `cluster:available_capacity_memory:bytes` | Total minus used |
| `cluster:vm_used_capacity_memory:bytes` | Memory requests of `virt-launcher-*` pods on schedulable nodes |
| `cluster:non_vm_used_capacity_memory:bytes` | Memory requests of every other pod on schedulable nodes |
| `cluster:total_capacity_cpu:cores` | Schedulable CPU minus the HA reserve |
| `cluster:used_capacity_cpu:cores` | CPU requests on schedulable nodes |
| `cluster:available_capacity_cpu:cores` | Total minus used |
| `cluster:vm_used_capacity_cpu:cores` | CPU requests of `virt-launcher-*` pods on schedulable nodes |
| `cluster:non_vm_used_capacity_cpu:cores` | CPU requests of every other pod on schedulable nodes |
| `cluster:vm_memory_usage:bytes` | Working set of `virt-launcher-*` containers |
| `cluster:non_vm_memory_usage:bytes` | Working set of every other container |
| `cluster:vm_cpu_usage:cores` | CPU cores used by `virt-launcher-*` containers |
| `cluster:non_vm_cpu_usage:cores` | CPU cores used by every other container |
| `vmi:virt_launcher_overhead_memory:bytes` | Per-VM virt-launcher memory overhead (pod working set minus guest RSS) |
| `vmi:virt_launcher_overhead_cpu:cores` | Per-VM virt-launcher CPU overhead (pod cAdvisor minus domain CPU) |

### Time-to-Exhaustion Rules

A second rule group (`capacity-exhaustion.rules`) answers "how many days before we run out of capacity?" by extrapolating the trend of available capacity. Each rule uses `deriv()` to compute the least-squares slope of available capacity over a lookback window. When the slope is negative (capacity shrinking), `-available / slope` gives seconds until zero; dividing by 86400 converts to days. When the slope is zero or positive (capacity stable or growing), the result is `+Inf` (the cluster never runs out at the current trend).

Four observation windows are provided. Shorter windows react faster to recent changes but are noisier; longer windows smooth out daily and weekly cycles but lag behind sudden shifts. The 180d and 360d windows require matching Prometheus retention.

| Recording rule | Window | Meaning |
|----------------|--------|---------|
| `cluster:days_to_exhaustion_memory_7d:days` | 7 days | Days until memory runs out (7-day trend) |
| `cluster:days_to_exhaustion_cpu_7d:days` | 7 days | Days until CPU runs out (7-day trend) |
| `cluster:days_to_exhaustion_7d:days` | 7 days | Days until whichever resource runs out first (7-day trend) |
| `cluster:days_to_exhaustion_memory_30d:days` | 30 days | Days until memory runs out (30-day trend) |
| `cluster:days_to_exhaustion_cpu_30d:days` | 30 days | Days until CPU runs out (30-day trend) |
| `cluster:days_to_exhaustion_30d:days` | 30 days | Days until whichever resource runs out first (30-day trend) |
| `cluster:days_to_exhaustion_memory_180d:days` | 180 days | Days until memory runs out (6-month trend) |
| `cluster:days_to_exhaustion_cpu_180d:days` | 180 days | Days until CPU runs out (6-month trend) |
| `cluster:days_to_exhaustion_180d:days` | 180 days | Days until whichever resource runs out first (6-month trend) |
| `cluster:days_to_exhaustion_memory_360d:days` | 360 days | Days until memory runs out (annual trend) |
| `cluster:days_to_exhaustion_cpu_360d:days` | 360 days | Days until CPU runs out (annual trend) |
| `cluster:days_to_exhaustion_360d:days` | 360 days | Days until whichever resource runs out first (annual trend) |

The combined rules use `clamp_max(memory_days, scalar(cpu_days))` to pick whichever resource runs out first, following the same pattern as the dashboard's "VMs that fit" calculation (OpenShift Prometheus treats `min()` as an aggregator so `min(a, b)` does not parse).

The usage rules are actual consumption, not requests. Memory uses the cAdvisor gauge `container_memory_working_set_bytes` (the same number `oc adm top` uses). CPU has no gauge: cAdvisor exposes the counter `container_cpu_usage_seconds_total`, and `rate(...[5m])` converts it to cores, matching OpenShift's own container CPU recording rules. The `cpu="total"` matcher keeps the per-container aggregate and leaves out the per-core series cAdvisor also publishes, which would otherwise be added on top of the total. `container!=""` and `container!="POD"` drop the pod cgroup rollup and the pause container.

Both dashboards are written with the Perses CUE SDK in `dac/`. `percli dac build` writes a Perses `Dashboard` to `dac/built/`. The component `kustomization.yaml` imports those files and applies `wrap-perses-dashboard.yaml` so GitOps ships `PersesDashboard` CRs in `openshift-operators`, the project where the monitoring UIPlugin places Perses and the default Thanos Querier datasource. List variable `defaultValue` is flattened to a string by kustomize; the CUE SDK emits `{singleValue, sliceValues}` and the Perses operator rejects that object.

The `capacity-exhaustion` dashboard is `dac/capacity-exhaustion.cue`. It visualises the time-to-exhaustion rules. Open it from **Observe → Dashboards (Perses)**, select `openshift-operators`, and open **Time to Capacity Exhaustion**. A list variable selects the observation period (7 days, 30 days, 180 days, 360 days; default 30 days). The top row is a GaugeChart showing days until the cluster runs out of capacity (whichever resource exhausts first), with thresholds at 30 days (red→orange) and 90 days (orange→green), capped at 365. The bottom row is a TimeSeriesChart with two lines — Memory and CPU — showing how the days-to-exhaustion estimate has changed over time. When capacity is stable or growing the recording rule returns `+Inf`; the gauge clamps that to 365 (reads as "365+") and the time series line disappears for those periods.

The `vm-overcommit` dashboard is `dac/vm-overcommit.cue`. Open it from **Observe → Dashboards (Perses)**, select `openshift-operators`, and open **VM Overcommit**. Two list variables set the observation period (7, 30, 180, 360 days; default 30 days) and the usage percentile (90th, 95th, 99th; default 95th). The first row is two StatCharts: suggested cluster overcommit for memory (`sum(domain) / sum(p95 used)`) and CPU (`sum(vCPUs) / sum(p95 QEMU usage)`). The second row is two Tables of the ten VMs with the largest allocated-to-used ratio on each resource.

The `vm-capacity` dashboard is `dac/vm-capacity.cue`. Open it from the console at **Observe → Dashboards (Perses)**, select `openshift-operators`, and open **How many VMs fit**. Four list variables set VM memory, VM CPU, memory overcommit (`1` through `4`), and CPU overcommit (`1`, `2`, `4`, `6`, `8`, `10`, `12`). The first row is a stat of how many VMs fit and a second stat that maps `0`/`1` to Memory bound / CPU bound. Two stacked TimeSeriesChart bar panels, Memory and CPU, show non-VM used, VM used, and available, with a bottom legend. Cluster Observability Operator ships BarChart 0.11.1, which has no stacking fields, so the stacked columns use `visual.display: bar` and `visual.stack: all` on TimeSeriesChart. Those three segments are limited to kubevirt-schedulable nodes, so they add up to `cluster:total_capacity_memory:bytes` and `cluster:total_capacity_cpu:cores`.

How many more VMs of a given shape fit is a query-time calculation, not a recording rule, because the VM size and overcommit ratios change per question. Division and multiplication are left-associative, so each side is `(available / vm_size) * overcommit`. OpenShift Prometheus treats `min()` as an aggregator, so `min(a, b)` fails to parse. `clamp_max(memory_count, scalar(cpu_count))` keeps the smaller count, and `floor` drops the fraction:

```promql
floor(clamp_max(
  cluster:available_capacity_memory:bytes / <vm_memory_bytes> * <memory_overcommit>,
  scalar(cluster:available_capacity_cpu:cores / <vm_cpu_cores> * <cpu_overcommit>)
))
```

Example for an 8GiB, 4-vCPU guest with no overcommit (`1`):

```promql
floor(clamp_max(
  cluster:available_capacity_memory:bytes / (8 * 1024 * 1024 * 1024) * 1,
  scalar(cluster:available_capacity_cpu:cores / 4 * 1)
))
```

## Cluster Deployment

| Cluster | Source |
|---------|--------|
| etl4, etl6, etl7 | `groups/prod` |

## Dependencies

Depends on the in-cluster monitoring stack (kube-state-metrics, kubelet cAdvisor, and `prometheus-k8s`), which OpenShift installs before GitOps configuration syncs. Sync-wave 15 matches other day-2 configuration. The `kubevirt.io/schedulable` label appears after OpenShift Virtualization marks nodes schedulable; until then the capacity series stay absent.

## Customization Points

- `capacity:nodes_down:count` in `prometheus-rule.yaml` — set the HA reserve. `vector(1)` holds back the largest schedulable node; `vector(2)` holds back two.
- VM shape and overcommit belong in the dashboard query, not in these rules.
- Dashboards live in `dac/*.cue`. After a CUE change, run `percli dac build -f <file>.cue` in `dac/` so `dac/built/` updates; kustomize wraps that output into a `PersesDashboard`.
