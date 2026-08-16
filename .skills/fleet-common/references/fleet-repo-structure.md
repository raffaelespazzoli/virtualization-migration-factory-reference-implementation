# Fleet Repo Structure

This reference codifies the architecture of the virtualization-migration-factory GitOps repository. All fleet workflows load this as shared context.

## Three-Tier Hierarchy

```
components/       Reusable Kustomize bases — one concern per directory
    ↓ referenced by
groups/           Cluster-role aggregation — values.yaml drives an app-of-apps Helm chart
    ↓ composed by
clusters/         Per-cluster composition — kustomization.yaml + values.yaml + overlays/
```

## Component Lifecycle Groups

Related components share a name prefix and form an ordered lifecycle group:

| Suffix | Role | Default sync-wave |
|--------|------|-------------------|
| `<name>-operator` | Deploys the operator via OperatorPolicy | 5 |
| `<name>-instance` | Creates the operand CR | 15 |
| `<name>-configuration` | Day-2 configuration (CRs, ConfigMaps) | 15 |
| `<name>-application` | Workloads depending on the operator config | 25 |

Not every component is an operator. Standalone components (e.g. `openshift-config`, `kube-ops-view`, `bookinfo`) have no lifecycle suffix and deploy raw manifests (Deployments, ConfigMaps, Routes, etc.).

## Sync-Wave Contract

- **5** = operators
- **6** = early dependencies other wave-15 components need (cert-manager-configuration, external-dns-configuration, nmstate-instance)
- **15** = operator instances / configurations
- **25** = anything depending on operator configuration

## Overlay Pattern

Cluster-specific customization: `clusters/<name>/overlays/<component>/`

These patch or extend the base component via Kustomize. The cluster's `values.yaml` points ArgoCD Applications at the overlay path instead of the base component when customization is needed.

## Values-Driven App-of-Apps

Each cluster/group has a `values.yaml` consumed by the `argocd-app-of-app` Helm chart. Structure:

```yaml
applications:
  <component-name>:
    annotations:
      argocd.argoproj.io/sync-wave: '<wave>'
    source:
      path: components/<component-name>
    # optional: destination.namespace, extraFields
```

Commented-out entries are available but inactive inventory — not dead code.

## Node File Pattern

Per-node files in hub overlays (`clusters/hub/overlays/cluster-<name>/`):
- `<hostname>-baremetal-host.yaml` — BareMetalHost CR with BMC credentials
- `<hostname>-nmstate-config.yaml` — NMState network configuration
- `<hostname>-fqdn.yaml` — DNS FQDN entry

## Version Pinning

`clusters/cluster-versions.yaml` maps cluster names to git refs. Kustomize replacements inject these as `targetRevision` on every ArgoCD Application for that cluster.

## Key Helm Charts (internal)

| Chart | Purpose |
|-------|---------|
| `argocd-app-of-app` | Generates ArgoCD Application resources from values.yaml |
| `bm-cluster-agent-install` | Bare-metal provisioning (InfraEnv, AgentClusterInstall, ClusterDeployment) |
| `cluster-registration` | ACM registration (labels, cluster set) |

## Environment Variable Interpolation

All manifests can use `${VAR}` syntax, rendered by the `envsub` CMP sidecar. Key variables: `CLUSTER_NAME`, `CLUSTER_BASE_DOMAIN`, `PLATFORM_BASE_DOMAIN`, `HUB_BASE_DOMAIN`, `INFRA_GITOPS_REPO`.

## OperatorPolicy Structure

Operators are deployed via `OperatorPolicy` (ACM policy-based lifecycle). Key fields:
- `spec.subscription.name` — the operator package name
- `spec.subscription.channel` — update channel
- `spec.subscription.source` — catalog source (redhat-operators, certified-operators, community-operators)
- `spec.subscription.namespace` — target namespace
- `spec.subscription.startingCSV` — pinned version
- `spec.versions[]` — approved version list
- `spec.upgradeApproval` — Automatic or Manual
