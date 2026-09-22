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

The usage rules are actual consumption, not requests. Memory uses the cAdvisor gauge `container_memory_working_set_bytes` (the same number `oc adm top` uses). CPU has no gauge: cAdvisor exposes the counter `container_cpu_usage_seconds_total`, and `rate(...[5m])` converts it to cores, matching OpenShift's own container CPU recording rules. The `cpu="total"` matcher keeps the per-container aggregate and leaves out the per-core series cAdvisor also publishes, which would otherwise be added on top of the total. `container!=""` and `container!="POD"` drop the pod cgroup rollup and the pause container.

The `vm-capacity` dashboard is written with the Perses CUE SDK in `dac/`. `perses-dashboard.yaml` is the OpenShift `PersesDashboard` produced from that build. It lives in `openshift-operators`, the project where the monitoring UIPlugin places Perses and the default Thanos Querier datasource. Open it from the console at **Observe → Dashboards (Perses)**, select `openshift-operators`, and open **How many VMs fit**. Four list variables set VM memory, VM CPU, memory overcommit, and CPU overcommit. The first panel is a stat of `floor` of the smaller of the memory-limited and CPU-limited counts. Two stacked bar panels, Memory and CPU, show non-VM used, VM used, and available. Those three segments are limited to kubevirt-schedulable nodes, so they add up to `cluster:total_capacity_memory:bytes` and `cluster:total_capacity_cpu:cores`.

How many more VMs of a given shape fit is a query-time calculation, not a recording rule, because the VM size and overcommit ratios change per question. Division and multiplication are left-associative, so this is `(available / vm_size) * overcommit`:

```promql
min(
  cluster:available_capacity_memory:bytes / <vm_memory_bytes> * <memory_overcommit>,
  cluster:available_capacity_cpu:cores / <vm_cpu_cores> * <cpu_overcommit>
)
```

Example for an 8GiB, 4-vCPU guest with no overcommit (`1`):

```promql
min(
  cluster:available_capacity_memory:bytes / (8 * 1024 * 1024 * 1024) * 1,
  cluster:available_capacity_cpu:cores / 4 * 1
)
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
