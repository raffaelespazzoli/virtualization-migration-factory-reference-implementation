# ZTWIM Instance

Deploys the **Zero Trust Workload Identity Manager (ZTWIM)** operand CRs that create the SPIFFE/SPIRE infrastructure on the cluster.

## What It Does

This component creates five singleton operand CRs (all named `cluster`) in the `zero-trust-workload-identity-manager` namespace:

| CR | Purpose |
|---|---|
| `ZeroTrustWorkloadIdentityManager` | Primary manager — sets trust domain and cluster name |
| `SpireServer` | Central identity authority — issues SVIDs, manages CA, exposes OIDC |
| `SpireAgent` | Node-level DaemonSet — attests workloads via k8sPSAT |
| `SpiffeCSIDriver` | CSI driver — mounts SPIFFE credentials into pods |
| `SpireOIDCDiscoveryProvider` | OIDC endpoint — enables external JWT-SVID validation (e.g. Vault) |

## Deployment Order

The ZTWIM operator controller handles internal ordering, but resources are listed in the recommended sequence:

1. `ZeroTrustWorkloadIdentityManager` (creates controller infrastructure)
2. `SpireServer` (central identity authority)
3. `SpireAgent` (node-level agent DaemonSet)
4. `SpiffeCSIDriver` (CSI driver for workload socket mounting)
5. `SpireOIDCDiscoveryProvider` (OIDC endpoint for external JWT validation)

## Customization

The base component uses `PLACEHOLDER` values that **must** be patched via a cluster overlay:

| Field | CR | Example Value |
|---|---|---|
| `trustDomain` | ZeroTrustWorkloadIdentityManager | `etl7.ocp.rht-labs.com` |
| `clusterName` | ZeroTrustWorkloadIdentityManager | `etl7` |
| `jwtIssuer` | SpireServer, SpireOIDCDiscoveryProvider | `https://oidc-discovery.apps.<cluster-domain>` |
| `storageClass` | SpireServer | `ontap-san` |

> **⚠️ Immutable fields:** `trustDomain`, `clusterName`, and all `persistence` fields on SpireServer are immutable after creation (CEL-enforced). If set incorrectly, the CRs must be deleted and recreated.

> **⚠️ jwtIssuer consistency:** The `jwtIssuer` value MUST be identical on both `SpireServer` and `SpireOIDCDiscoveryProvider`. A mismatch causes JWT validation failures.

## Sync Wave

This component runs at sync-wave **15** (instance tier), after the `ztwim-operator` at wave 5.

## Context

- **Epic:** Zero-Trust Secret Delivery to VM Workloads via SPIFFE/Vault on etl7
- **Depends on:** `ztwim-operator` (Story 1.1) — operator must be installed for CRDs to exist
- **Next in chain:** Story 1.5 (SPIRE↔Vault Trust) uses the OIDC discovery Route URL
- **SpireAgent and SpiffeCSIDriver** are deployed with defaults as part of the standard operand set but are not functionally used in the current experiment (the VM uses x509pop attestation separately)
