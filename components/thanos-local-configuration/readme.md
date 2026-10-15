# Thanos Local Configuration

Per-cluster metrics ingest pipeline: collects all Prometheus metrics and ships them to S3-compatible object storage via Thanos Receive. Deployed on **every cluster** that produces metrics.

## Architecture

```
Prometheus (openshift-monitoring)
    │ remote_write (HTTP, same cluster)
    ▼
OTel Collector (deployment, 2 replicas)
    │ filter / relabel / batch
    │ prometheusremotewrite exporter (HTTPS, service-serving cert)
    ▼
Thanos Receive (statefulset, 3 replicas, replication-factor=2)
    │ writes TSDB blocks to S3 every ~2h
    │ serves StoreAPI gRPC (TLS, service-serving cert)
    ▼
S3 Object Storage
```

## Deployed Resources

| Resource | Kind | Purpose |
|----------|------|---------|
| `namespace.yaml` | Namespace | `thanos-local` namespace |
| `otel-metrics-collector.yaml` | OpenTelemetryCollector, ServiceAccount, ClusterRole, ClusterRoleBinding | OTel Collector receiving Prometheus remote-write, filtering, forwarding to Receive over TLS |
| `values-receive.yaml` | Helm values | Thanos Receive via the vendored thanos-community chart (`.helm-charts/thanos/`). 3 replicas with `replication-factor=2` for write-path durability, gRPC TLS via service-serving cert. |
| `objstore-secret.yaml` | Secret | S3 credentials placeholder — populate before deployment |
| `receive-route.yaml` | Route | Exposes Receive's gRPC StoreAPI for cross-cluster Query access (reencrypt + `backend-protocol-version: h2`) |
| `service-ca-bundle.yaml` | ConfigMap | OpenShift service CA bundle (auto-injected), mounted into OTel Collector for TLS verification |

No CPU limits are configured — only memory limits. CPU limits cause unnecessary throttling without safety benefit on OpenShift.

## TLS Strategy

All connections use TLS. Internal connections leverage OpenShift service-serving certificates; external connections use the router's wildcard certificate via reencrypt Routes.

| Connection | TLS Method | Detail |
|------------|-----------|--------|
| Prometheus → OTel Collector | HTTP | `remoteWrite` URL points to the OTel Collector in the same cluster. TLS can be added via `remoteWrite.tlsConfig` if required. |
| OTel Collector → Thanos Receive | **HTTPS (service-serving cert)** | OTel Collector mounts the `thanos-local-service-ca` ConfigMap (injected with the cluster service CA) and validates Receive's TLS cert via `ca_file`. Endpoint uses `https://`. |
| Cross-cluster Query → Receive gRPC | **Route (reencrypt + h2)** | Route annotation `haproxy.router.openshift.io/backend-protocol-version: h2` enables HTTP/2 for gRPC. Router terminates external TLS (wildcard cert), re-encrypts to the Receive service-serving cert. |

### Service-Serving Certificates

The Receive Service is annotated with `service.beta.openshift.io/serving-cert-secret-name: thanos-receive-tls`. OpenShift's service CA operator automatically:

1. Generates a TLS certificate for `thanos-receive.thanos-local.svc`
2. Stores it in Secret `thanos-receive-tls`
3. Auto-renews every 2 years

Thanos Receive mounts this secret and uses `--grpc-server-tls-cert` / `--grpc-server-tls-key` to serve TLS on its gRPC port.

The OTel Collector verifies Receive's cert by mounting the `thanos-local-service-ca` ConfigMap (annotated with `service.beta.openshift.io/inject-cabundle: "true"`) at `/etc/tls/service-ca/service-ca.crt`.

## RBAC Strategy

- **OTel Collector** runs under `otel-metrics-collector` ServiceAccount with cluster-wide read access to pods, namespaces, replicasets, and OpenShift infrastructure resources (for k8s attribute enrichment).
- **Thanos Receive** uses the chart-created ServiceAccount (`thanos-thanos`). No special cluster RBAC needed — it only writes to S3 and serves gRPC.

## Prometheus Remote Write

The `remoteWrite` stanza is configured in the existing `openshift-config` overlay (`cluster-monitoring-configmap.yaml`), not in this component. It points Prometheus at the OTel Collector's `prometheusremotewrite` receiver:

```yaml
prometheusK8s:
  remoteWrite:
    - url: http://metrics-collector.thanos-local.svc.cluster.local:19291/api/v1/write
      writeRelabelConfigs: []
```

This is a supported CMO configuration knob — it does not modify the Prometheus deployment or add sidecars.

## Customization

- **Metric filtering**: Uncomment and configure the `filter` processor in `otel-metrics-collector.yaml` to drop high-cardinality or unwanted metrics before they reach S3.
- **OTel Collector sizing**: Adjust `replicas`, `memory_limiter` percentages, and `batch` settings based on active series count (`prometheus_tsdb_head_series`).
- **Receive sizing**: Adjust `replicaCount`, `persistence.size`, and `resources` in `values-receive.yaml`.
- **S3 credentials**: Replace the placeholder in `objstore-secret.yaml` or use an ExternalSecret/SealedSecret.

## Onboarding a New Cluster

To add a new metrics-producing cluster (e.g., etl8):

1. Deploy `thanos-local-configuration` on etl8 (provides OTel Collector + Receive)
2. Add `remoteWrite` to etl8's `cluster-monitoring-configmap.yaml` overlay
3. Populate the S3 credentials secret on etl8
4. Add the new Receive Route endpoint (`thanos-receive-grpc-thanos-local.apps.etl8...`) to the `query.stores` list in `thanos-server-deployment/values.yaml`
5. No changes needed to Store Gateway — it already reads the entire S3 bucket

## Prerequisites

- OpenTelemetry Operator deployed (`otel-operator` component, sync wave 5)
- S3-compatible object storage provisioned (out of scope)
- `openshift-config` overlay updated with `remoteWrite` stanza
