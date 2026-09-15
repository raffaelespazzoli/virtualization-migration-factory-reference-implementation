# vault-config-operator

Deploys the [vault-config-operator](https://github.com/redhat-cop/vault-config-operator/) via OperatorPolicy (OLM). This operator enables declarative Vault configuration through Kubernetes CRDs — auth engines, policies, roles, and secret engines.

## Deployment Method

Deployed via OperatorPolicy from the `community-operators` catalog on OperatorHub. Follows the standard `<name>-operator` pattern used by all OLM-deployed operators in this repo.

| Field | Value |
|---|---|
| OLM package name | `vault-config-operator` |
| Channel | `alpha` |
| Source | `community-operators` |

VAULT_ADDR and VAULT_CACERT are injected into the operator pod via `subscription.config` in the OperatorPolicy, following the same pattern as `openshift-gitops-operator`.

## Key CRDs

`AuthEngineMount`, `JWTOIDCAuthEngineConfig`, `JWTOIDCAuthEngineRole`, `SecretEngineMount`, `Policy`, `KubernetesAuthEngineConfig`, `KubernetesAuthEngineRole`

## Architecture

The base component (`components/vault-config-operator/`) contains the namespace, OCP service-serving CA ConfigMap, and OperatorPolicy. No cluster-specific overlay is needed — all configuration is embedded in the OperatorPolicy's subscription config.

## OCP Service-Serving CA

The `ocp-service-ca` ConfigMap uses the `service.beta.openshift.io/inject-cabundle: "true"` annotation. OpenShift automatically injects the service-serving CA bundle, which is needed to trust Vault's TLS certificate (signed by the same CA). The OperatorPolicy mounts this ConfigMap into the operator pod via `subscription.config.volumes`.

## Dependencies

- **Vault** must be deployed on the target cluster (provides `VAULT_ADDR`) — see Story 1.3
- Sync-wave `5` (operator tier) — the operator starts and registers controllers, but does not reconcile CRs until they are created at a later wave (Story 1.5, wave 25)

## Part Of

Epic 1: Zero-Trust Secret Delivery to VM Workloads via SPIFFE/Vault on etl7
