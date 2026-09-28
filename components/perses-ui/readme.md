# Perses UI

Deploys the upstream [Perses](https://perses.dev/) v0.54.0 as a companion UI alongside the Cluster Observability Operator's headless Perses backend. The COO ships `perses-rhel9` without the React frontend — this component provides the full upstream UI with complete plugin feature support (including `querySettings`, explorer mode, etc.).

## What it deploys

| Resource | Purpose |
|---|---|
| `ServiceAccount/perses-ui` | Identity for Thanos querier access |
| `ClusterRoleBinding/perses-ui-monitoring-view` | Grants `cluster-monitoring-view` to the SA |
| `ConfigMap/perses-ui-config` | Perses server configuration (provisioning path, file database) |
| `ConfigMap/perses-ui-ca-bundle` | OpenShift-injected service-serving CA for TLS to Thanos |
| `ConfigMap/perses-ui-dashboards` | All capacity-management dashboards (pre-patched for defaultValue format) |
| `Deployment/perses-ui` | Single-replica Perses with init container for provisioning setup |
| `Service/perses-ui` | ClusterIP service on port 8080 |
| `Route/perses-ui` | Edge-terminated TLS route |

## Architecture

```
Browser → Route (TLS edge) → Service → Perses container (port 8080)
                                            ↓ proxy
                              Thanos querier (openshift-monitoring, port 9091)
```

The init container:
1. Reads the projected SA token from `/var/run/secrets/kubernetes.io/serviceaccount/token`
2. Generates a `GlobalDatasource` YAML with the bearer token in the `Authorization` header
3. Creates a `Project` YAML for `perses`
4. Copies dashboard YAML files from the `perses-ui-dashboards` ConfigMap
5. All files land in `/etc/perses/provisioning/` — Perses loads them at startup

## Dashboards provisioned

- **Node Memory** — cgroup v2 memory decomposition per node (non-reclaimable, hot/cold reclaimable, free)
- **How many VMs fit** — VM capacity planning (how many VMs of a given size fit on the cluster)
- **Time to Capacity Exhaustion** — days until the cluster runs out of schedulable resources
- **VM Overcommit** — overcommit ratio analysis for memory and CPU

## Updating dashboards

The dashboards ConfigMap is generated from the `dac/built/` output of the `capacity-management-configuration` component with `defaultValue` patches applied (Perses provisioning requires plain strings, not the `{singleValue, sliceValues}` objects emitted by `percli`).

To regenerate after dashboard changes:

```bash
# 1. Rebuild the CUE dashboards
cd components/capacity-management-configuration/dac
percli dac build -f <dashboard>.cue

# 2. Create a temp kustomization with defaultValue patches, build, split, and regenerate the ConfigMap
# (see the capacity-management-configuration kustomization.yaml for the patch definitions)
```

## Known limitations

- **SA token is static at pod startup.** The bearer token injected into the datasource is read once by the init container. Kubernetes refreshes projected tokens after ~1 hour, but Perses won't pick up the new token until the pod restarts. For long-running deployments, consider adding a `CronJob` or annotation-based rollout trigger.
- **No authentication.** The Perses UI is exposed without auth. For production use, add an `oauth-proxy` sidecar or configure Perses's built-in OIDC authentication.
- **File-based database.** Uses an `emptyDir` volume — dashboards are re-provisioned on every pod restart. Any manual edits through the UI are lost on restart.
