# Thanos Local Configuration

Per-cluster metrics ingest pipeline: collects Prometheus metrics filtered to `container_*` series and ships them to S3-compatible object storage via Thanos Receive. Deployed on **every cluster** that produces metrics.

## Architecture

```
Prometheus (openshift-monitoring)
    │ remote_write (HTTPS, service-serving cert)
    │ writeRelabelConfigs: keep container_*
    │ externalLabels: cluster_name=<cluster>
    ▼
Thanos Receive (statefulset, 3 replicas, replication-factor=2)
    │ writes TSDB blocks to S3 every ~2h
    │ serves StoreAPI gRPC for cross-cluster Query
    │ adds label: cluster=<cluster> via --label flag
    ▼
S3 Object Storage
```

> **OTel Collector removed** — The OpenTelemetry Collector was originally
> deployed as an intermediary between Prometheus and Receive for metric
> filtering and cluster labeling. It was removed because the
> `prometheusremotewritereceiver` v0.158.0 only supports Prometheus Remote
> Write V2 (`io.prometheus.write.v2.Request`), while CMO on OCP 4.22
> hardcodes V1 (`prometheus.WriteRequest`). The filtering and labeling are
> now handled natively by Prometheus via `writeRelabelConfigs` and
> `externalLabels` in the `cluster-monitoring-config` ConfigMap.

## Deployed Resources

| Resource | Kind | Purpose |
|----------|------|---------|
| `namespace.yaml` | Namespace | `thanos-local` namespace |
| `values-receive.yaml` | Helm values | Thanos Receive via the vendored thanos-community chart (`.helm-charts/thanos/`). 3 replicas with `replication-factor=2` for write-path durability. |
| `objstore-secret.yaml` | Secret | S3 credentials placeholder — populate before deployment |
| `receive-route.yaml` | Route | Exposes Receive's gRPC StoreAPI for cross-cluster Query access (edge termination) |
| `service-ca-bundle.yaml` | ConfigMap | OpenShift service CA bundle (auto-injected) |
| `rbac.yaml` | RBAC | ServiceAccount and permissions |
| ~~`otel-metrics-collector.yaml`~~ | ~~OpenTelemetryCollector~~ | Removed — commented out in kustomization. See note above. |

### Ready but not enabled

| Resource | Kind | Purpose |
|----------|------|---------|
| `receive-route-passthrough.yaml` | Route | Passthrough route for gRPC — requires cert-manager. See [Route Strategy](#route-strategy). |
| `receive-certificate.yaml` | Certificate | cert-manager Certificate covering the route FQDN. Required by the passthrough route. |

## Connection Map

| # | From | To | Protocol | TLS | Port | Notes |
|---|------|-----|----------|-----|------|-------|
| 1 | Prometheus (openshift-monitoring) | Thanos Receive | HTTP remote write | ✅ service-serving cert | 10908 | `remoteWrite` in cluster-monitoring-config. CA from `serving-certs-ca-bundle` ConfigMap. |
| 2 | Thanos Receive (peer) | Thanos Receive (peer) | gRPC hashring replication | ❌ plaintext | 10901 | Via headless service. Peers forward writes based on hashring assignment. |
| 3 | Thanos Receive | S3 object storage | HTTPS | ✅ | 443 | Uploads TSDB blocks every ~2h. Credentials from `thanos-objstore` Secret. |
| 4 | Thanos Query (cross-cluster) | Thanos Receive | gRPC StoreAPI | ❌ plaintext HTTP | 80 | Via Route. Plain HTTP with h2c backend — no TLS. Temporary; switch to passthrough with cert-manager for production. |

## Route Strategy

### Current: Plain HTTP (no TLS)

The gRPC route has **no TLS section** — it serves on port 80 as plain HTTP. HAProxy forwards plaintext h2c to the Receive backend without any TLS termination or h2 frame re-encoding. This is a temporary workaround to bypass the reencrypt h2-to-h2 issue where HAProxy silently drops gRPC server-streaming responses.

gRPC TLS is **disabled** on the Receive's gRPC port (10901). The remote-write port (10908) retains TLS via `--remote-write.server-tls-cert`.

**⚠️ Not for production** — Query → Receive traffic is unencrypted. Switch to passthrough with cert-manager when available.

### Future: Passthrough termination

For production, the route should be switched to **passthrough**. With passthrough, HAProxy tunnels raw TCP/TLS bytes end-to-end — HTTP/2, ALPN, and gRPC streaming all work natively without frame re-encoding.

Passthrough requires a TLS certificate whose SAN matches the route hostname (e.g., `thanos-receive-grpc-thanos-local.apps.etl6.ocp.rht-labs.com`). The service-serving cert only covers `thanos-receive.thanos-local.svc`, so a cert-manager Certificate is needed.

**To switch to passthrough:**

1. Add `receive-certificate.yaml` to `kustomization.yaml` → cert-manager issues the cert
2. Replace `receive-route.yaml` with `receive-route-passthrough.yaml` in `kustomization.yaml`
3. In `values-receive.yaml`, re-enable `--grpc-server-tls-cert` and `--grpc-server-tls-key`, and change the secret mount from `thanos-receive-tls` to `thanos-receive-grpc-route-tls`
4. Remove `GRPC_ENFORCE_ALPN_ENABLED=false` from Query (passthrough preserves ALPN)

### Known issue: reencrypt + gRPC streaming

OpenShift's HAProxy 2.8 does not properly forward gRPC server-streaming responses through reencrypt routes. The h2-to-h2 frame re-encoding path (frontend h2 → HAProxy HTX → backend h2) drops or truncates DATA frames from server-streaming RPCs. Unary RPCs work because they fit the normal request→response pattern. This is a similar class of problem to [haproxy/haproxy#162](https://github.com/haproxy/haproxy/issues/162) (h2 backend limitations), though that specific issue was about WebSocket CONNECT rather than gRPC streaming.

### Known issue: gRPC ALPN enforcement

grpc-go ≥1.67 (bundled in Thanos 0.42.4) enforces h2 ALPN negotiation during TLS handshakes. HAProxy's reencrypt and edge routes do not advertise h2 in the frontend TLS ALPN response, even with `ingress.operator.openshift.io/default-enable-http2: "true"` on the IngressController. Workaround: set `GRPC_ENFORCE_ALPN_ENABLED=false` on the Query pods.

## Prometheus Remote Write

The `remoteWrite` stanza is configured in the **existing** `openshift-config` overlay (`cluster-monitoring-configmap.yaml`), not in this component:

```yaml
prometheusK8s:
  remoteWrite:
    - url: https://thanos-receive.thanos-local.svc.cluster.local:10908/api/v1/receive
      tlsConfig:
        ca:
          configMap:
            key: service-ca.crt
            name: serving-certs-ca-bundle
      writeRelabelConfigs:
        - sourceLabels: [__name__]
          regex: "container_.+"
          action: keep
  externalLabels:
    cluster_name: <cluster-name>
    managed_cluster: <cluster-uuid>
```

### Labels

Each metric carries two cluster identifiers:

| Label | Set by | Value |
|-------|--------|-------|
| `cluster_name` | Prometheus `externalLabels` | Cluster name (e.g., `etl6`) |
| `cluster` | Thanos Receive `--label` flag | Same value, injected by Receive |

CMO reserves the label name `cluster` in `externalLabels`, so `cluster_name` is used there instead. The `cluster` label from Receive's `--label` flag is the canonical label for Thanos deduplication and store filtering.

## Customization

- **Metric filtering**: Adjust the `writeRelabelConfigs` regex in the cluster's `cluster-monitoring-configmap.yaml` overlay.
- **Receive sizing**: Adjust `replicaCount`, `persistence.size`, and `resources` in `values-receive.yaml`.
- **S3 credentials**: Replace the placeholder in `objstore-secret.yaml` or use an ExternalSecret/SealedSecret.

## Onboarding a New Cluster

1. Deploy `thanos-local-configuration` on the new cluster
2. Add `remoteWrite` to the cluster's `cluster-monitoring-configmap.yaml` overlay
3. Populate the S3 credentials secret
4. Add the new Receive Route endpoint to the `query.stores` list in `thanos-server-deployment/values.yaml`
5. No changes needed to Store Gateway — it already reads the entire S3 bucket

## Prerequisites

- S3-compatible object storage provisioned (out of scope)
- `openshift-config` overlay updated with `remoteWrite` stanza
- cert-manager operator deployed (only needed for passthrough route)
