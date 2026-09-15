# ZTWIM Operator

Deploys the **Zero Trust Workload Identity Manager (ZTWIM)** operator via ACM OperatorPolicy.

## What It Does

The ZTWIM operator manages the lifecycle of SPIFFE/SPIRE infrastructure on OpenShift:

- **SPIRE Server** — issues SPIFFE identities (SVIDs) to workloads
- **SPIRE Agent** — runs on each node, attests workloads, and delivers SVIDs
- **OIDC Discovery Provider** — exposes a JWKS endpoint so external systems (e.g. Vault) can validate SPIFFE JWTs
- **SPIFFE CSI Driver** — mounts SPIFFE credentials into pods via CSI volume

## Operator Details

| Field | Value |
|---|---|
| OLM Package | `openshift-zero-trust-workload-identity-manager` |
| Channel | `stable-v1` |
| Source | `redhat-operators` |
| Namespace | `zero-trust-workload-identity-manager` |
| CSV | `zero-trust-workload-identity-manager.v1.1.1` |

## Deployment

Installed via `OperatorPolicy` in namespace `open-cluster-management-policies`. The policy enforces the subscription and lets OLM manage the operator lifecycle with automatic upgrades.

## Context

- **Epic:** Zero-Trust Secret Delivery to VM Workloads via SPIFFE/Vault on etl7
- **Depends on:** Nothing — first component in the chain
- **Next in chain:** `ztwim-instance` (Story 1.2) deploys the five ZTWIM operand CRs (ZeroTrustWorkloadIdentityManager, SpireServer, SpireAgent, SpiffeCSIDriver, SpireOIDCDiscoveryProvider)
