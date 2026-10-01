# Capacity Management Configuration

Recording rules, alerts, and Perses dashboards for OpenShift Virtualization capacity management. This component references an external repository as the single source of truth.

## Source of Truth

**Upstream repo:** <https://github.com/raffaelespazzoli/openshift-monitoring-addson>

The `kustomization.yaml` in this directory references the upstream repo as a remote Kustomize resource. All recording rules, alerts, and dashboard definitions are maintained there.

## What Gets Deployed

The upstream repo deploys:

| Functional Area | PrometheusRule CRs | Content |
|---|---|---|
| **memory/** | Recording rules + alerts | Node memory breakdown, PSI, OOM proximity, ECC |
| **cpu/** | Recording rules + alerts | CPU PSI at all scopes, vCPU scheduling delay |
| **networking/** | Recording rules + alerts | NIC utilization, drops/errors, VM network metrics |
| **storage/** | Recording rules + alerts | I/O PSI, FC HBA, DM-multipath, VM storage latency |
| **capacity/** | Recording rules + alerts | Capacity accounting, exhaustion projections, overhead |
| **dashboards/** | PersesDashboard CRs | vm-capacity, capacity-exhaustion, vm-overcommit, node-memory, pod-memory, vm-memory |

All PrometheusRule CRs deploy to `openshift-monitoring` with labels `prometheus: k8s` and `role: alert-rules`. PersesDashboard CRs deploy to `openshift-operators`.

## Cluster Deployment

| Cluster | Source |
|---------|--------|
| etl4, etl6, etl7 | `groups/prod` |

## Dependencies

- OpenShift Cluster Monitoring (kube-state-metrics, kubelet cAdvisor, prometheus-k8s)
- OpenShift Virtualization with `kubevirt.io/schedulable=true` node labels
- cgroup v2 with PSI enabled (`psi=1` kernel boot parameter) for pressure rules
- Cluster Observability Operator with Perses for dashboards

## Customization

To override upstream defaults (e.g. alert thresholds, HA reserve), add `patches:` entries in `kustomization.yaml` targeting the relevant PrometheusRule by name.

To pin to a specific version, change `?ref=main` to a tag or commit SHA:
```yaml
resources:
  - github.com/raffaelespazzoli/openshift-monitoring-addson?ref=v1.0.0
```

Dashboard CUE sources and build instructions are in the upstream repo's `dashboards/dac/` directory.
