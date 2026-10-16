# Thanos Server Deployment

Deploys the Thanos query and storage management tier on the HA cluster pair (etl6 + etl7). These components read from S3 object storage and serve long-term metric queries. Deployed via the vendored [thanos-community Helm chart](https://github.com/thanos-community/helm-charts) v0.47.2 from `.helm-charts/thanos/` and the vendored [HelmForge memcached chart](https://github.com/helmforgedev/charts) v1.0.8 from `.helm-charts/memcached/`.

## Architecture

```
                S3 Object Storage
                       │
          ┌────────────┼────────────┐
          ▼            ▼            ▼
    Store Gateway   Compactor    Bucket Web
      (reads)      (compacts,    (UI for
          │         downsamples,  block
          │         enforces      inspection)
          │         retention)
          ├── memcached-store (index + caching-bucket cache)
          │
          ├── Ruler (recording rules against full dataset)
          ▼
        Query ◄── Query Frontend ◄── GLB ◄── Users
                        │
                   memcached-qf (response cache)
          │
          ├── Receive etl6 (via Route, plain HTTP)
          └── Receive etl7 (via Route, plain HTTP)
```

## Components

| Component | Kind | Replicas | Purpose |
|-----------|------|----------|---------|
| **Store Gateway** | StatefulSet | 2 | Reads TSDB blocks from S3, serves historical data via StoreAPI gRPC. Each cluster runs two for HA — both see the entire bucket, so no cross-cluster Store GW traffic is needed. Index and chunk data cached in memcached-store. |
| **Query** | Deployment | 2 | Fan-out PromQL engine. Connects to local Store Gateway, local Ruler, and both clusters' Receive endpoints (via Routes). Deduplicates results. HTTP endpoint secured with TLS via `--http.config`. |
| **Query Frontend** | Deployment | 2 | Caching and query-splitting layer in front of Query. Connects to Query over HTTPS. Response cache backed by memcached-qf. HTTP endpoint secured by kube-rbac-proxy sidecar. |
| **Compactor** | StatefulSet | 1 (singleton) | Compacts and downsamples blocks in S3. Enforces retention policy. Runs with `concurrency=4` for both compact and downsample. **Active/standby**: runs on etl6 (active), etl7 overrides `replicaCount=0` (standby). Protected by a ValidatingAdmissionPolicy — see [Compactor Safety](#compactor-safety-validatingadmissionpolicy). |
| **Ruler** | StatefulSet | 2 | Evaluates recording rules against the full Thanos dataset (up to 1 year). Results are written to S3 as new pre-computed series. Connects to Query over HTTPS. Alertmanager endpoint is commented out. Auto-imports PrometheusRule CRDs from `thanos-system` namespace only. |
| **Bucket Web** | Deployment | 2 | Read-only web UI showing block status, compaction state, and gaps in the bucket. Secured by oauth-proxy sidecar. |
| **memcached-qf** | StatefulSet | 3 | Memcached cluster for Query Frontend response caching. |
| **memcached-store** | StatefulSet | 3 | Memcached cluster for Store Gateway index cache and caching-bucket. |

## Connection Map

| # | From | To | Protocol | TLS | Port |
|---|------|-----|----------|-----|------|
| 1 | Query Frontend | Query | HTTPS | ✅ service-serving cert | 9090 |
| 2 | Ruler | Query | HTTPS | ✅ service-serving cert | 9090 |
| 3 | Query | Store Gateway | gRPC | ✅ service-serving cert (mTLS) | 10901 |
| 4 | Query | Ruler | gRPC | ✅ service-serving cert (mTLS) | 10901 |
| 5 | Query | Receive etl6 (route) | gRPC | ❌ plaintext HTTP | 80 |
| 6 | Query | Receive etl7 (route) | gRPC | ❌ plaintext HTTP | 80 |
| 7 | Store Gateway | S3 | HTTPS | ✅ | 443 |
| 8 | Store Gateway | memcached-store | memcache | ❌ plaintext | 11211 |
| 9 | Compactor | S3 | HTTPS | ✅ | 443 |
| 10 | Ruler | S3 | HTTPS | ✅ | 443 |
| 11 | Bucket Web | S3 | HTTPS | ✅ | 443 |
| 12 | Query Frontend | memcached-qf | memcache | ❌ plaintext | 11211 |
| 13 | Users (GLB) | Query Frontend | HTTPS | ✅ reencrypt (kube-rbac-proxy) | 9091 |
| 14 | Users (GLB) | Bucket Web | HTTPS | ✅ reencrypt (oauth-proxy) | 9091 |

### Query gRPC client TLS

Query uses `--grpc-client-tls-secure` with a **combined CA bundle** (`/etc/tls/combined-ca/ca.crt`) that merges:

- **Service CA** (`thanos-service-ca` ConfigMap) — trusts in-cluster service-serving certs (Store GW, Ruler)
- **System CA** (`thanos-query-system-ca` ConfigMap, injected with `config.openshift.io/inject-trusted-cabundle`) — trusts the router wildcard cert for Receive route endpoints

An init container (`merge-ca`) concatenates both CAs at pod startup.

### Query HTTP TLS

Query serves HTTPS on port 9090 via `--http.config` referencing the service-serving cert. This allows Query Frontend and Ruler to connect securely. Health probes use `scheme: HTTPS` (kubelet skips certificate verification).

### gRPC ALPN workaround

grpc-go ≥1.67 (in Thanos 0.42.4) enforces h2 ALPN during TLS handshakes. HAProxy's edge/reencrypt routes do not advertise h2 in the frontend TLS ALPN, even with HTTP/2 enabled on the IngressController. Query sets `GRPC_ENFORCE_ALPN_ENABLED=false` to bypass this check while still verifying the TLS certificate chain.

## Retention & Downsampling

Configured on the Compactor:

| Resolution | Retention | Effective Range |
|------------|-----------|-----------------|
| Raw (scrape interval) | 30 days | Month 1 |
| 5-minute downsampling | 180 days | Months 1–6 |
| 1-hour downsampling | 365 days | Months 1–12 |

## TLS Strategy

No CPU limits are configured on any component — only memory limits (to prevent OOM).

### Service-serving certificates

All Thanos gRPC and HTTP services use **OpenShift service-serving certificates**:

| Service | Secret | Used by |
|---------|--------|---------|
| `thanos-storegateway` | `thanos-storegateway-tls` | gRPC server TLS |
| `thanos-query` | `thanos-query-tls` | gRPC server TLS + HTTP server TLS |
| `thanos-ruler` | `thanos-ruler-tls` | gRPC server TLS |
| `thanos-query-frontend` | `thanos-query-frontend-tls` | kube-rbac-proxy sidecar |
| `thanos-compactor` | `thanos-compactor-tls` | — (no inbound TLS) |
| `thanos-bucketweb` | `thanos-bucketweb-tls` | oauth-proxy sidecar |

### Memcached

Memcached communicates within `thanos-system` only — no cross-namespace or cross-cluster traffic. TLS is not enabled, matching ACM observability's memcached pattern.

## RBAC Strategy

### Query Frontend (kube-rbac-proxy)

Secured with kube-rbac-proxy sidecar on port 9091. Verifies the caller has `cluster-reader` access (can `GET` namespaces cluster-wide).

### Bucket Web (oauth-proxy)

Secured with oauth-proxy sidecar on port 9091. Redirects to OCP login; requires namespace `GET` access.

### Ruler Rule Importer (namespace-scoped)

Auto-imports PrometheusRule CRDs labeled `thanos-ruler: "true"` from `thanos-system` only. The chart's default ClusterRole/ClusterRoleBinding are deleted and replaced with namespace-scoped RBAC in `ruler-rbac-namespace-scope.yaml`.

## Compactor Safety (ValidatingAdmissionPolicy)

The Compactor is a **singleton** — running two instances against the same S3 bucket causes data corruption. A ValidatingAdmissionPolicy enforces this:

| Rule | Expression | Effect |
|------|------------|--------|
| Max replicas | `object.spec.replicas <= 1` | Hard cap — never more than 1 |
| Attestation required | `...attestation == "I confirm..."` | Scaling to 1 requires attestation ConfigMap |

### Failover Procedure

1. Confirm etl6's Compactor is down
2. On etl7, edit the `compactor-attestation` ConfigMap with the attestation string
3. Scale the Compactor StatefulSet to 1
4. When etl6 returns, scale its Compactor to 0 first

## Cross-Cluster Connectivity

Query connects to both clusters' Receive endpoints via Routes:

```
Query (etl6 or etl7):
  ├── Store Gateway (local, ClusterIP gRPC TLS)
  ├── Ruler (local, ClusterIP gRPC TLS)
  ├── Receive etl6 (via Route: thanos-receive-grpc-thanos-local.apps.etl6...)
  └── Receive etl7 (via Route: thanos-receive-grpc-thanos-local.apps.etl7...)
```

Store Gateway does NOT need cross-cluster access — both clusters' Store Gateways read the same S3 bucket.

### Known issue: gRPC streaming over routes

HAProxy 2.8 reencrypt routes silently drop gRPC server-streaming (Series RPC) responses due to h2-to-h2 frame re-encoding issues. The current workaround is a plain HTTP route (no TLS, port 80) with h2c backend — **not for production**. See `thanos-local-configuration/readme.md` for the full route strategy and passthrough migration plan.

## Customization

- **Compactor active/standby**: etl7's overlay patches `compactor.replicas=0`. To activate, update the attestation ConfigMap.
- **Receive endpoints**: Both etl6 and etl7 Route endpoints are in the base `values.yaml`.
- **S3 credentials**: Replace the placeholder in `objstore-secret.yaml`.
- **Memcached sizing**: Adjust in `values-memcached-qf.yaml` / `values-memcached-store.yaml`.
- **Alertmanager**: Uncomment the config in `values.yaml` under `ruler.alertmanagers`.
- **Recording rules**: Create PrometheusRule CRDs in `thanos-system` with label `thanos-ruler: "true"`.

## Prerequisites

- `thanos-local-configuration` deployed on the same cluster (provides Receive)
- S3-compatible object storage provisioned
- OpenShift 4.14+ (for HTTP/2 route support)
