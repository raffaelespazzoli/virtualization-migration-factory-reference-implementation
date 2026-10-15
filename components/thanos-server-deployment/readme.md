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
          ├── Receive etl6 (via Route, reencrypt + h2)
          └── Receive etl7 (via Route, reencrypt + h2)
```

## Components

| Component | Kind | Replicas | Purpose |
|-----------|------|----------|---------|
| **Store Gateway** | StatefulSet | 2 | Reads TSDB blocks from S3, serves historical data via StoreAPI gRPC. Each cluster runs two for HA — both see the entire bucket, so no cross-cluster Store GW traffic is needed. Index and chunk data cached in memcached-store. |
| **Query** | Deployment | 2 | Fan-out PromQL engine. Connects to local Store Gateway, local Ruler, and both clusters' Receive endpoints (via Routes). Deduplicates results. Serves the Prometheus-compatible HTTP API secured by kube-rbac-proxy. |
| **Query Frontend** | Deployment | 2 | Caching and query-splitting layer in front of Query. Response cache backed by memcached-qf. |
| **Compactor** | StatefulSet | 1 (singleton) | Compacts and downsamples blocks in S3. Enforces retention policy. Runs with `concurrency=4` for both compact and downsample. **Active/standby**: runs on etl6 (active), etl7 overrides `replicaCount=0` (standby). Protected by a ValidatingAdmissionPolicy — see [Compactor Safety](#compactor-safety-validatingadmissionpolicy). |
| **Ruler** | StatefulSet | 2 | Evaluates recording rules against the full Thanos dataset (up to 1 year). Results are written to S3 as new pre-computed series. Alertmanager endpoint is commented out (no Alertmanager deployed); alerting rules evaluate but alerts are not routed. Auto-imports PrometheusRule CRDs from `thanos-system` namespace only. |
| **Bucket Web** | Deployment | 1 | Read-only web UI showing block status, compaction state, and gaps in the bucket. Behind GLB. |
| **memcached-qf** | StatefulSet | 3 | Memcached cluster for Query Frontend response caching. Headless service for DNS SRV discovery. |
| **memcached-store** | StatefulSet | 3 | Memcached cluster for Store Gateway index cache and caching-bucket. Headless service for DNS SRV discovery. Higher concurrency settings than QF to handle Store GW's parallel block scans. |

## Retention & Downsampling

Configured on the Compactor:

| Resolution | Retention | Effective Range |
|------------|-----------|-----------------|
| Raw (scrape interval) | 30 days | Month 1 |
| 5-minute downsampling | 180 days | Months 1–6 |
| 1-hour downsampling | 365 days | Months 1–12 |

Data older than 1 year is deleted by the Compactor.

## TLS Strategy

No CPU limits are configured on any component — only memory limits (to prevent OOM). CPU limits cause unnecessary throttling without safety benefit on OpenShift.

### Internal Connections (same cluster)

All Thanos gRPC services use **OpenShift service-serving certificates**. Each Service is annotated with `service.beta.openshift.io/serving-cert-secret-name`, which causes the service CA operator to:

1. Generate a TLS certificate for `<service>.<namespace>.svc`
2. Store it in the named Secret
3. Auto-renew every 2 years

| Service | Secret | Flags |
|---------|--------|-------|
| `thanos-storegateway` | `thanos-storegateway-tls` | `--grpc-server-tls-cert`, `--grpc-server-tls-key` |
| `thanos-query` | `thanos-query-tls` | `--grpc-server-tls-cert`, `--grpc-server-tls-key` |
| `thanos-ruler` | `thanos-ruler-tls` | `--grpc-server-tls-cert`, `--grpc-server-tls-key` |
| `thanos-query-frontend` | `thanos-query-frontend-tls` | — (HTTP only) |
| `thanos-compactor` | `thanos-compactor-tls` | — (HTTP only) |
| `thanos-bucketweb` | `thanos-bucketweb-tls` | — (HTTP only) |

Query's gRPC client trusts the local service CA via `--grpc-client-tls-ca` pointing at the `thanos-service-ca` ConfigMap (annotated with `service.beta.openshift.io/inject-cabundle: "true"`).

### Memcached

Memcached pods (memcached-qf, memcached-store) communicate **within the `thanos-system` namespace only** — there is no cross-namespace or cross-cluster memcached traffic. TLS is not enabled in the initial configuration, matching ACM observability's memcached pattern. Unlike the Bitnami chart, the HelmForge chart natively supports TLS with exporter passthrough (`tls.existingSecret` + `metrics.memcachedTLS`), so TLS can be enabled later by:

1. Adding `service.beta.openshift.io/serving-cert-secret-name` to `headlessService.annotations`
2. Setting `tls.enabled: true` and `tls.existingSecret` to the generated secret
3. Setting `metrics.memcachedTLS.enabled: true` and `metrics.memcachedTLS.insecureSkipVerify: true`
4. Adding `tls_enabled: true`, `server_name`, and `ca_file` to the Thanos client `cacheConfig` / `cachingBucketConfig`

### External Connections (cross-cluster and user-facing)

All Routes use **TLS reencrypt**. gRPC Routes (Receive) additionally set `haproxy.router.openshift.io/backend-protocol-version: h2` for HTTP/2 negotiation.

| Route | TLS Mode | Backend | Notes |
|-------|----------|---------|-------|
| `thanos-query` | reencrypt | kube-rbac-proxy (port 9091) | User-facing, behind GLB |
| `thanos-bucket-web` | reencrypt | Bucket Web HTTP | User-facing, behind GLB |

Query connects to both clusters' Receive endpoints via their reencrypt + h2 Routes in `thanos-local-configuration`. Query must trust the router CA (public CA or propagated internal CA) for these connections.

## RBAC Strategy

### Query Endpoint (kube-rbac-proxy)

The Thanos Query HTTP endpoint is secured with a `kube-rbac-proxy` sidecar. The proxy intercepts all requests and performs a Kubernetes SubjectAccessReview to verify the caller has `cluster-reader` level access:

```
--authorization-resourceattributes-resource=namespaces
--authorization-resourceattributes-verb=get
--authorization-resourceattributes-apigroup=
```

This checks that the authenticated user can `GET` namespaces cluster-wide — a permission granted by the `cluster-reader` ClusterRole. The proxy serves TLS on port 9091; the Route targets this port.

### Ruler Rule Importer (namespace-scoped)

The Ruler sidecar auto-imports PrometheusRule CRDs with two layers of scoping:

1. **Label selector** (chart-native): only CRDs labeled `thanos-ruler: "true"` are imported.
2. **Namespace scope** (RBAC enforcement): the chart's default ClusterRole/ClusterRoleBinding are deleted and replaced with a namespace-scoped `Role`/`RoleBinding` in `ruler-rbac-namespace-scope.yaml`. The sidecar's ServiceAccount can only see PrometheusRules in `thanos-system`, even though the import script runs `kubectl get -A`.

To create a recording rule, deploy a PrometheusRule in `thanos-system` with the label:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: capacity-recording-rules
  namespace: thanos-system
  labels:
    thanos-ruler: "true"
spec:
  groups:
    - name: capacity-weekly
      interval: 5m
      rules:
        - record: cluster:cpu_usage:7d_avg
          expr: avg_over_time(node_cpu_seconds_total{mode!="idle"}[7d])
```

The sidecar picks it up within 60 seconds, the Ruler evaluates it against the full Thanos Query dataset, and the result is written back to S3 as a queryable series.

### ServiceAccounts

Each Thanos component runs under a chart-managed ServiceAccount (`thanos-thanos`). No elevated cluster RBAC is required — Store Gateway, Compactor, and Ruler access S3 via the objstore secret, not the Kubernetes API.

## Compactor Safety (ValidatingAdmissionPolicy)

The Compactor is a **singleton** — running two instances against the same S3 bucket causes data corruption (overlapping blocks). A ValidatingAdmissionPolicy enforces this:

### Resources

| Resource | Purpose |
|----------|---------|
| `compactor-attestation` ConfigMap | Contains `data.attestation` — must match a magic string to allow scaling to 1 |
| `thanos-compactor-singleton` ValidatingAdmissionPolicy | Two CEL rules (see below) |
| `thanos-compactor-singleton` ValidatingAdmissionPolicyBinding | Wires the policy to the ConfigMap, scoped to `app.kubernetes.io/component: compactor` |

### CEL Rules

| Rule | Expression | Effect |
|------|------------|--------|
| Max replicas | `object.spec.replicas <= 1` | Hard cap — never more than 1. Prevents accidents. |
| Attestation required | `object.spec.replicas == 0 \|\| params.data.attestation == "I confirm that there are no other compactors running in other thanos server deployments"` | Scaling to 1 requires the attestation. Scaling to 0 (shutdown) is always allowed. |

### Failover Procedure

1. Confirm etl6's Compactor is down or being decommissioned
2. On etl7, edit the `compactor-attestation` ConfigMap:
   ```
   attestation: "I confirm that there are no other compactors running in other thanos server deployments"
   ```
3. Scale the Compactor StatefulSet to 1 — the VAP allows it
4. When etl6 returns, scale its Compactor to 0 first, then optionally transfer the attestation back

ArgoCD is configured with `ignoreDifferences` on `/spec/replicas` for the Compactor StatefulSet, so manual replica changes are not reverted by sync.

## Cross-Cluster Connectivity

Query on each cluster connects to **both** clusters' Thanos Receive endpoints via Routes for uniform TLS handling. Both Receive endpoints are hardcoded in the base `values.yaml` — no per-cluster overlay needed:

```
Query (etl6 or etl7):
  ├── Store Gateway (local, auto-discovered by chart, internal gRPC TLS)
  ├── Ruler (local, auto-discovered by chart, internal gRPC TLS)
  ├── Receive etl6 (via Route: thanos-receive-grpc-thanos-local.apps.etl6.ocp.rht-labs.com:443)
  └── Receive etl7 (via Route: thanos-receive-grpc-thanos-local.apps.etl7.ocp.rht-labs.com:443)
```

Store Gateway does NOT need cross-cluster access — both clusters' Store Gateways read the same S3 bucket and see all data.

## Customization

- **Compactor active/standby**: etl7's overlay patches `compactor.replicas=0`. To activate, update the attestation ConfigMap and scale to 1.
- **Receive endpoints**: Both etl6 and etl7 Route endpoints are in the base `values.yaml`. Update them if cluster names or domains change.
- **S3 credentials**: Replace the placeholder in `objstore-secret.yaml`.
- **Memcached sizing**: Adjust `-m` (memory), `-c` (connections), `replicaCount` in `values-memcached-qf.yaml` / `values-memcached-store.yaml`. The default 1 GiB per pod matches ACM.
- **Cache tuning**: Modify `cacheConfig` (Query Frontend) or `cachingBucketConfig` / `storegateway-index-cache-config.yaml` (Store Gateway) to adjust TTLs, concurrency, and item sizes.
- **Alertmanager**: Uncomment the alertmanager config in `values.yaml` under `ruler.alertmanagers` when an Alertmanager is available.
- **Recording rules**: Create PrometheusRule CRDs in `thanos-system` with label `thanos-ruler: "true"`.

## Prerequisites

- `thanos-local-configuration` deployed on the same cluster (provides Receive)
- S3-compatible object storage provisioned
- OpenShift 4.14+ (for HTTP/2 reencrypt Route support)
