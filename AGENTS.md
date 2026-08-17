<!-- bmad:context -->
<!-- Verified 2026-08-15 against 03f86ea. Managed by bmad-project-context; edits inside this block are replaced on refresh. Keep anything you want preserved outside the markers. -->

## virtualization-migration-factory-reference-implementation

GitOps reference implementation for deploying a multi-cluster OpenShift virtualization migration factory. Pure declarative YAML — Kustomize + Helm rendered through ArgoCD with a custom `envsubst` CMP sidecar. Follows the Red Hat CoP ArgoCD app-of-apps pattern. Architecture docs in `cluster-creation.md`, `storage.md`, and per-component `readme.md` files.

## Policy

- Never commit secrets — `.gitignore` lists pull-secrets, BMC credentials, AWS secrets, htpasswd, license files. Verify against `.gitignore` before staging any new secret-shaped file.
- Never hand-edit files under `.helm-charts/` templates without understanding the Helm values contract — `values.yaml` in each cluster/group directory drives the rendered Applications.
- Never modify the root `kustomization.yaml` — it is a placeholder, not the entry point. The real roots are `clusters/<name>/kustomization.yaml`.
- Gitleaks is configured (`.gitleaks.toml`); paths in its allowlist are acknowledged exceptions, not permission to add more.
- All operators must be deployed via `OperatorPolicy` (ACM policy-based lifecycle). Legacy `Subscription` or `ClusterExtension` files in some operator components are migration artifacts — the `operator-policy.yaml` is the canonical deployment mechanism.

## Where things are

- **Bootstrap entry point:** `.bootstrap/` — subscription, ArgoCD config, root Application. Run order matters (see README).
- **Components (reusable building blocks):** `components/<name>/` — each is a self-contained Kustomize base. Every component should have a `readme.md` explaining what it does, its configuration, and expected customization points. Related components share a name prefix and form a lifecycle group:
  - `<name>-operator` — deploys the operator via OperatorPolicy (namespace, operator-policy.yaml)
  - `<name>-instance` or `<name>-configuration` — creates the operand CR or day-2 configuration
  - Some components have all three tiers (`trident-operator`, `trident-instance`, `trident-configuration`); the naming convention is the relationship graph.
- **Groups (cluster-role aggregation):** `groups/all/` applies to every cluster; `groups/prod/` adds virtualization, HA, and observability for managed clusters. Each group has a `kustomization.yaml` rendering the `argocd-app-of-app` Helm chart from its `values.yaml`.
- **Clusters (per-cluster composition):** `clusters/<name>/kustomization.yaml` composes groups and renders its own app-of-apps. Cluster-specific customization lives in `clusters/<name>/overlays/<component>/`. The hub cluster's overlays also hold provisioning manifests for managed clusters at `clusters/hub/overlays/cluster-<name>/`.
- **Cluster provisioning (hub-side):** Each managed cluster needs: a namespace, BareMetalHost definitions (one per node with BMC credentials, MAC address, boot mode), NMState configs (per-node network bonding), FQDN entries (per-node DNS), and a `cluster-registration` Helm release (registers to ACM with labels and cluster set). The `bm-cluster-agent-install` Helm chart handles the full agent-based install (InfraEnv, AgentClusterInstall, ClusterDeployment).
- **Helm charts (internal, not published):** `.helm-charts/argocd-app-of-app` (Application generator from values), `bm-cluster-agent-install` (bare-metal provisioning), `cluster-registration` (ACM registration), `grafana` (Grafana instances), `gateway` (Gateway API), `oauth-proxy`, `v-cluster-hcp`.
- **Version pinning:** `clusters/cluster-versions.yaml` — maps each cluster name to a git ref; Kustomize replacements inject it as `targetRevision` on every ArgoCD Application. Adding a cluster requires an entry here.
- **Component-level docs:** Components with `readme.md`: acm-configuration, cert-manager-configuration, metallb-configuration, nmstate-configuration, openshift-config, openshift-virtualization-instance, acm-observability, user-workload-monitoring, external-dns-configuration, trilio-instance, infinidat-appliance. All components should eventually have one. Some components also have a structured JSON documentation file (e.g. `metallb.json`) viewable through the fleet component viewer.

## Conventions that differ from defaults

- **Sync-wave contract:** 5 = operators, 15 = operator instance or operator configuration, 25 = anything depending on operator configuration (typically `<name>-application` or cross-cluster concerns). Exceptions exist for ordering dependencies — e.g. cert-manager-configuration at wave 6 because other wave-15 components depend on it.
- **Component naming is load-bearing:** The `<name>-operator` / `<name>-instance` / `<name>-configuration` convention is not stylistic — sync-wave ordering and component relationship discovery depend on it.
- **Environment variable interpolation:** Every manifest can use `${VAR}` syntax — rendered by the `envsub` CMP sidecar, not by Kustomize. Variables come from the `environment-variables` ConfigMap in `openshift-gitops` (set during bootstrap). Key vars: `CLUSTER_NAME`, `CLUSTER_BASE_DOMAIN`, `PLATFORM_BASE_DOMAIN`, `HUB_BASE_DOMAIN`, `INFRA_GITOPS_REPO`.
- **Reflector-based ConfigMap propagation:** ConfigMaps needing cross-namespace visibility carry `reflector.v1.k8s.emberstack.com` annotations. The `reflector-operator` component must be deployed early (sync-wave 5).
- **Commented-out blocks are intentional inventory.** Many `values.yaml` files contain commented-out application entries — these document available components not currently enabled. Do not delete them.
- **Node definitions follow a per-node file pattern:** Each bare-metal node gets its own NMState config (`<hostname>-nmstate-config.yaml`), FQDN entry (`<hostname>-fqdn.yaml`), and optionally a BareMetalHost (`<hostname>-baremetal-host.yaml`) in the cluster overlay directory.

## Known pitfalls

- The root `kustomization.yaml` references `oci://ghcr.io/my-org/my-configs:v1.0.0` — this is a placeholder/leftover, not functional. Do not attempt to resolve it.
- Adding a new cluster requires entries in `clusters/cluster-versions.yaml`, a `clusters/<name>/` directory (kustomization + values composing groups), and `clusters/hub/overlays/cluster-<name>/` for provisioning. Missing any one causes silent failures.
- The `gitops-boostrap-policy` component name is a typo (`boostrap` not `bootstrap`) — it is referenced by this exact name in multiple places and must not be "fixed" without a coordinated rename.
- ArgoCD is configured with `--load-restrictor LoadRestrictionsNone` and `--enable-alpha-plugins` — Kustomize restrictions are intentionally lifted. Do not add a restrictor.

<!-- /bmad:context -->
