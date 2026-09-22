# Cluster Observability Configuration

Configures the Cluster Observability Operator (COO) UI plugins and observability features.

## Prerequisites

- Cluster Observability Operator v1.5+ installed (deployed via `cluster-observability-operator` component in `groups/all`)
- OpenShift 4.15+

## What This Component Deploys

| Resource | Kind | Purpose |
|----------|------|---------|
| `monitoring-ui.yaml` | UIPlugin (Monitoring) | Enables the Perses dashboarding UI integrated into the OpenShift console at **Observe → Dashboards (Perses)** |
| `distributed-tracing-ui.yaml` | UIPlugin (DistributedTracing) | Enables the distributed tracing UI at **Observe → Traces** |
| `troubleshooting-ui.yaml` | UIPlugin (TroubleshootingPanel) | Enables the troubleshooting panel in the console |
| `namespace.yaml` | Namespace | Creates `openshift-observability` namespace |

## Perses Dashboards

When the monitoring UIPlugin is created with `perses.enabled: true`, the COO automatically:

1. Deploys the **Perses Operator** and its CRDs (`PersesDashboard`, `PersesDatasource`, `PersesGlobalDatasource`)
2. Creates a **Perses server instance**
3. Installs an **accelerator datasource** connected to the platform Thanos Querier (provides access to all cluster metrics)
4. Adds the **Observe → Dashboards (Perses)** menu to the OpenShift console

### Creating Dashboards

**Via the Console (interactive):**

1. Navigate to **Observe → Dashboards (Perses)**
2. Select a namespace from the project selector
3. Click **Create** to open the graphical dashboard editor
4. Add panels (Time Series, Stat, Gauge, Bar Chart, Table, etc.) and configure PromQL queries

**Via GitOps (declarative):**

Create `PersesDashboard` custom resources in any namespace:

```yaml
apiVersion: perses.dev/v1alpha2
kind: PersesDashboard
metadata:
  name: my-dashboard
  namespace: my-project
spec:
  config:
    display:
      name: "My Dashboard"
    panels:
      cpu:
        kind: Panel
        spec:
          display:
            name: "CPU Usage"
          plugin:
            kind: TimeSeriesChart
            spec: {}
          queries:
            - kind: TimeSeriesQuery
              spec:
                plugin:
                  kind: PrometheusTimeSeriesQuery
                  spec:
                    query: "rate(node_cpu_seconds_total{mode!='idle'}[5m])"
    layouts:
      - kind: Grid
        spec:
          display:
            title: "Metrics"
            collapse:
              open: true
          items:
            - x: 0
              y: 0
              width: 24
              height: 8
              content:
                $ref: "#/spec/panels/cpu"
    duration: 1h
```

**Importing Grafana dashboards:**

Use the console import feature or `percli` CLI:

```sh
oc -n openshift-cluster-observability-operator port-forward svc/perses 8080:8080
percli login https://localhost:8080 --kube --insecure-skip-tls-verify
percli migrate -f grafana-dashboard.json --online -o yaml --format cr --project my-namespace > perses-dashboard.yaml
oc apply -f perses-dashboard.yaml
```

### Custom Datasources

The accelerator datasource auto-created by COO covers most use cases. To create additional datasources (e.g., for user-defined metrics with namespace filtering):

```yaml
apiVersion: perses.dev/v1alpha2
kind: PersesDatasource
metadata:
  name: user-workload-metrics
  namespace: my-project
spec:
  config:
    display:
      name: "User Workload Metrics"
    default: false
    plugin:
      kind: "PrometheusDatasource"
      spec:
        proxy:
          kind: HTTPProxy
          spec:
            url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9092?namespace=my-project
            secret: user-workload-secret
  client:
    tls:
      enable: true
      caCert:
        type: file
        certPath: /ca/service-ca.crt
```

### RBAC

COO creates ClusterRoles for Perses access. Bind them to users as needed:

| ClusterRole | Grants |
|-------------|--------|
| `persesdashboard-editor-role` | Create, read, update, delete dashboards |
| `persesdashboard-viewer-role` | Read-only dashboard access |
| `persesdatasource-editor-role` | Manage datasources |
| `persesdatasource-viewer-role` | Read-only datasource access |

Example RoleBinding for a developer:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dev-dashboard-editor
  namespace: my-project
subjects:
  - kind: User
    apiGroup: rbac.authorization.k8s.io
    name: developer1
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: persesdashboard-editor-role
```

## References

- [Red Hat Perses Documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_cluster_observability_operator/1-latest/html/ui_plugins_for_red_hat_openshift_cluster_observability_operator/perses-dashboard)
- [Perses Operator User Guide](https://perses.dev/perses-operator/docs/user-guide/)
- [Community Dashboard Mixins](https://github.com/perses/community-mixins)
