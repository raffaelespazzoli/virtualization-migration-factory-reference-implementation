---
title: "Epic: Zero-Trust Secret Delivery to VM Workloads via SPIFFE/Vault on etl7"
created: 2026-09-14
status: draft
cluster: etl7
tags: [spiffe, spire, vault, rhel-image-mode, zero-trust, openshift-virtualization]
stories:
  - S1-ztwim-operator
  - S2-ztwim-instance
  - S3-vault-etl7
  - S4-vault-config-operator
  - S5-spire-vault-trust
  - S6a-bootc-image
  - S6b-spire-agent-helper
  - S6c-vault-agent-httpd
  - S6d-deploy-vm
  - S7-tpm-devid-vm
stepsCompleted: []
---

## Epic 1: Zero-Trust Secret Delivery to VM Workloads via SPIFFE/Vault on etl7

### Epic Statement

**As a** platform engineer experimenting with zero-trust workload identity,
**I want** a VM running RHEL 10 image-mode on OpenShift Virtualization to obtain Vault secrets using only its SPIFFE identity,
**So that** I can validate a passwordless, certificate-based secret delivery pipeline for VM workloads.

### Success Criteria

An httpd endpoint on the RHEL 10 VM displays a KV2 secret retrieved from Vault, authenticated solely via a SPIRE-issued JWT-SVID — no pre-shared Vault tokens, AppRole credentials, or Kubernetes service account tokens involved.

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│  etl7 OpenShift Cluster                                                 │
│                                                                         │
│  ┌──────────────────┐    ┌──────────────────┐   ┌────────────────────┐ │
│  │  ZTWIM Operator   │    │  vault-config-   │   │  Vault (Helm)      │ │
│  │  (OperatorPolicy) │    │  operator         │   │  1.20.4-ubi        │ │
│  └────────┬─────────┘    └────────┬─────────┘   │  + auto-init/unseal│ │
│           │                       │              └────────┬───────────┘ │
│  ┌────────▼─────────┐    ┌────────▼─────────┐            │             │
│  │  SpireServer      │    │  vault-admin ns   │   ┌───────▼──────────┐ │
│  │  + OIDC Discovery │◄───┤  VCO CRDs:        │   │  KV2 Engine      │ │
│  │  + x509pop attestor│   │  - JWT Auth       │   │  secret/data/    │ │
│  │  + CSI Driver     │    │  - OIDC config    │   │  experiment/demo │ │
│  └────────┬─────────┘    │  - Policy         │   └──────────────────┘ │
│           │              │  - Role           │                         │
│           │              └──────────────────┘                         │
│  ┌────────▼──────────────────────────────────────────────────────────┐ │
│  │  RHEL 10 Image-Mode VM (OpenShift Virtualization)                 │ │
│  │                                                                    │ │
│  │  ┌─────────────┐  ┌──────────────┐  ┌────────────┐  ┌──────────┐│ │
│  │  │ spire-agent  │─►│ spiffe-helper │─►│ vault-agent │─►│  httpd   ││ │
│  │  │ (x509pop)    │  │ (JWT+certs)  │  │ (JWT auth) │  │ (secret) ││ │
│  │  └──────┬───────┘  └──────────────┘  └────────────┘  └──────────┘│ │
│  │         │                                                          │ │
│  │  bootstrap cert (cert-manager, 1yr, via cloud-init)               │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                                                         │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │  RHEL 10 Image-Mode VM #2 — tpm_devid attestation (Story 1.7)    │ │
│  │                                                                    │ │
│  │  ┌─────────────┐  ┌──────────────┐  ┌────────────┐  ┌──────────┐│ │
│  │  │ spire-agent  │─►│ spiffe-helper │─►│ vault-agent │─►│  httpd   ││ │
│  │  │ (tpm_devid)  │  │ (JWT+certs)  │  │ (JWT auth) │  │ (secret) ││ │
│  │  └──────┬───────┘  └──────────────┘  └────────────┘  └──────────┘│ │
│  │         │                                                          │ │
│  │  vTPM + DevID cert (cert-manager, cloud-init provisions vTPM)     │ │
│  │  bootstrap cert removed post-boot (manual demo step)              │ │
│  └────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

### Trust Chain

1. **cert-manager** provides the single root of trust via a ClusterIssuer chain (deployed by `ztwim-instance`)
2. **SPIRE Server** obtains its intermediate signing CA from cert-manager via the **UpstreamAuthority cert-manager plugin** (declarative, no manual steps)
3. **cert-manager** issues a 1-year bootstrap leaf certificate for the VM from the same root CA ClusterIssuer
4. The root CA cert is added to the **SPIRE Server's** x509pop trusted CA bundle (manual patch — CRD limitation)
5. **cloud-init** injects the leaf cert + key into the VM at `/etc/spire/bootstrap/`
6. **spire-agent** boots, presents the bootstrap cert, SPIRE Server validates and attests
7. **spiffe-helper** extracts all supported identity types: X.509-SVIDs, JWT-SVIDs, and JWT Bundle (JWKS)
8. **vault-agent** reads the JWT-SVID, authenticates to Vault via OIDC-federated JWT auth
9. **vault-agent** templates the KV2 secret to disk
10. **httpd** serves the secret file at a public URL

### VM Container Isolation and Shared Folder Architecture

Each Quadlet container on the VM operates at a distinct privilege level. Folders are shared only between the containers that need them, with strict ownership, permissions, and SELinux context.

```
┌──────────────────────────────────────────────────────────────────────┐
│  RHEL 10 Image-Mode VM — Folder & Permission Map                     │
│                                                                       │
│  /etc/spire/bootstrap/              ← ONLY spire-agent              │
│    agent.crt.pem   (0400 spire:spire)   can read.                   │
│    agent.key.pem   (0400 spire:spire)   Private key — most          │
│    dir perms:      (0500 spire:spire)   sensitive asset on the VM.  │
│                                                                       │
│  /run/spire/sockets/                ← spire-agent writes socket,    │
│    agent.sock                         spiffe-helper connects.       │
│    (standard unix socket perms)       No extra restriction needed.  │
│                                                                       │
│  /var/run/secrets/spiffe/           ← SHARED: spiffe-helper → vault │
│    svid.crt.pem    (0640 spiffe-helper:spiffe-consumers)            │
│    svid.key.pem    (0640 spiffe-helper:spiffe-consumers)            │
│    bundle.crt.pem  (0640 spiffe-helper:spiffe-consumers)            │
│    jwt-svid.token  (0640 spiffe-helper:spiffe-consumers)            │
│    jwt_bundle.json (0640 spiffe-helper:spiffe-consumers)            │
│    dir perms:      (0750 spiffe-helper:spiffe-consumers)            │
│    vault-agent user is member of spiffe-consumers group.            │
│    httpd has NO access to this folder.                               │
│                                                                       │
│  /var/www/html/                     ← SHARED: vault-agent → httpd   │
│    secret.txt      (0644 vault-agent:apache)                        │
│    dir perms:      (0755 root:root)                                  │
│    SELinux:        httpd_sys_rw_content_t                            │
│    httpd reads via standard apache group membership.                │
│    vault-agent writes with correct perms and SELinux context.       │
└──────────────────────────────────────────────────────────────────────┘
```

### Users and Groups (created in the Containerfile)

| User/Group | Purpose |
|---|---|
| `spire` (user+group) | Runs spire-agent. Sole owner of bootstrap cert files. |
| `spiffe-helper` (user) | Runs spiffe-helper. Writes SVID files. |
| `spiffe-consumers` (group) | Shared group for reading SVID output. Members: `spiffe-helper`, `vault-agent-user`. |
| `vault-agent-user` (user) | Runs vault-agent. Reads SVIDs, writes secrets to httpd docroot. |
| `apache` (group) | Standard httpd group. vault-agent writes files with this group ownership. |

### SELinux Contexts (set in the Containerfile)

| Path | SELinux Context | Reason |
|---|---|---|
| `/var/www/html/` | `httpd_sys_rw_content_t` | httpd requires this context to serve files; `rw` variant because vault-agent writes at runtime |
| `/var/run/secrets/spiffe/` | `container_file_t` (or default) | Standard runtime data, no special httpd requirement |
| `/etc/spire/bootstrap/` | `cert_t` (or default) | Certificate storage, restricted by file permissions |

### Dependency Graph

```
Story 1 (ZTWIM Operator)
    └── Story 2 (ZTWIM Instance: SpireServer + OIDC + CSI)
              └─────────────────────────┐
Story 3 (Vault on etl7, fresh images)──┤
                                        │
Story 4 (vault-config-operator) ────────┤
                                        │
                           Story 5 (SPIRE↔Vault Trust, vault-admin ns)
                                        │
Story 6a (Bootc image build) ───────────┤
                                        │
Story 6b (SPIRE Agent + Helper config)──┤
                                        │
Story 6c (Vault Agent + httpd config) ──┤
                                        │
                           Story 6d (Deploy VM, end-to-end)
                                        │
                           Story 1.7 (tpm_devid VM — same overlay, shared image)
```

**Parallelizable starts:** Stories 1, 3, 4, and 6a can all begin simultaneously. Story 1.7 can begin after Story 6d (shares the bootc image and overlay).

### Future Work

- Investigate the **Vault UpstreamAuthority plugin** (ZTWIM docs §12.13.6) to have Vault's PKI engine serve as the SPIRE root CA, closing the trust circle (cert-manager → Vault PKI → SPIRE).
- Evaluate **SPIRE federation** across clusters (etl6 ↔ etl7) for cross-cluster identity.
- Explore replacing the experiment's `containerDisk` VM with a `DataVolume` for persistence.
- **Automate the tpm_devid bootstrap cleanup** — the manual demo step (remove cert disk + restart) could be automated via a Job or controller in a future iteration.
- **Investigate Approach A for tpm_devid** — out-of-band vTPM provisioning via a pre-created PVC + Kubernetes Job, eliminating the bootstrap cert exposure entirely (requires KubeVirt PVC adoption testing).
- **EK-based provisioning** — use the vTPM's auto-generated Endorsement Key for trust establishment, eliminating the need for any bootstrap cert (requires a provisioning webhook service).

### Key References

- [OCP 4.22 Zero Trust Workload Identity Manager docs](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/security_and_compliance/zero-trust-workload-identity-manager)
- [SPIFFE/Vault OIDC federation tutorial](https://spiffe.io/docs/latest/keyless/vault/readme/)
- [SPIRE x509pop agent plugin](https://github.com/spiffe/spire/blob/main/doc/plugin_agent_nodeattestor_x509pop.md)
- [SPIRE x509pop server plugin](https://github.com/spiffe/spire/blob/main/doc/plugin_server_nodeattestor_x509pop.md)
- [Vault Agent JWT auto-auth](https://developer.hashicorp.com/vault/docs/agent-and-proxy/autoauth/methods/jwt)
- [vault-config-operator](https://github.com/redhat-cop/vault-config-operator/)
- [RHEL 10 image-mode containerizing workloads](https://developers.redhat.com/articles/2025/01/13/containerizing-workloads-image-mode-rhel#managing_workloads_on_image_mode)
- [Red Hat Ecosystem Catalog - Vault](https://catalog.redhat.com/software/containers/hashicorp/vault/5fda55bd2937386820429e0c)
- [X.509 Node Attestation walkthrough (Yulia Paterson)](https://medium.com/@yulia.paterson/spire-x-509-node-attestation-033bd157ce0d)
- [SPIRE tpm_devid agent plugin](https://github.com/spiffe/spire/blob/main/doc/plugin_agent_nodeattestor_tpm_devid.md)
- [SPIRE tpm_devid server plugin](https://github.com/spiffe/spire/blob/main/doc/plugin_server_nodeattestor_tpm_devid.md)
- [tpm2-tools documentation](https://github.com/tpm2-software/tpm2-tools)
- [KubeVirt vTPM documentation](https://kubevirt.io/user-guide/compute/virtual-hardware/#trusted-platform-module-tpm)

---

## Stories

---

### Story 1.1: Install Zero Trust Workload Identity Manager Operator on etl7

**ID:** S1-ztwim-operator

**As a** platform engineer,
**I want** the ZTWIM operator installed on etl7 via OperatorPolicy,
**So that** I can deploy SPIRE server/agent and SPIFFE infrastructure.

### Acceptance Criteria

- [ ] New component `components/ztwim-operator/` created following the repo `<name>-operator` naming convention
- [ ] Contains `namespace.yaml` creating namespace `openshift-zero-trust-workload-identity-manager` with:
  - `argocd.argoproj.io/sync-options: Delete=false` annotation
  - `argocd.argoproj.io/managed-by: openshift-gitops` label
- [ ] Contains `operator-policy.yaml` with OperatorPolicy targeting subscription `openshift-zero-trust-workload-identity-manager` in channel `stable`
- [ ] Contains `kustomization.yaml` referencing the above resources
- [ ] Sync-wave annotation set to `5` (operator tier)
- [ ] Component has a `readme.md` explaining what it deploys
- [ ] Application entry added to `clusters/etl7/values.yaml` (etl7 only — **not** `groups/prod`) at wave 5:
  ```yaml
  ztwim-operator:
    annotations:
      argocd.argoproj.io/sync-wave: '5'
    source:
      path: components/ztwim-operator
  ```

### Dependencies

None

### Implementation Notes

- Follow the OperatorPolicy pattern established by other operators in the repo (e.g., `percona-operator`, `trident-operator`)
- The operator package name on OperatorHub is `openshift-zero-trust-workload-identity-manager`
- Channel: `stable` (OCP 4.22)

---

### Story 1.2: Deploy ZTWIM Operands (SpireServer, OIDC Discovery Provider, CSI Driver)

**ID:** S2-ztwim-instance

**As a** platform engineer,
**I want** the SPIRE server, OIDC discovery provider, and SPIFFE CSI driver deployed on etl7,
**So that** workloads can receive SPIFFE identities and external services can validate JWT-SVIDs via OIDC.

### Acceptance Criteria

- [ ] New component `components/ztwim-instance/` created following the `<name>-instance` naming convention
- [ ] Contains `ZeroTrustWorkloadIdentityManager` CR deploying the operand
- [ ] Contains `SpireServer` CR configured with:
  - Trust domain (e.g., `spiffe://etl7.ocp.rht-labs.com`)
  - OIDC Discovery Provider enabled and configured
  - **UpstreamAuthority cert-manager plugin** via `spec.upstreamAuthority.certManager` referencing the `spire-root-ca-issuer` ClusterIssuer (SPIRE's intermediate signing cert comes from cert-manager — fully declarative, no manual CA provisioning)
- [ ] Contains cert-manager `ClusterIssuer` resources (`spire-cert-manager-ca.yaml`):
  - `selfsigned-bootstrap` — self-signed ClusterIssuer for bootstrapping the root CA
  - `spire-root-ca-issuer` — ClusterIssuer backed by the root CA Secret (shared with VM bootstrap cert)
- [ ] Contains SPIFFE CSI Driver CR
- [ ] Contains `kustomization.yaml` referencing the above resources
- [ ] Overlay at `clusters/etl7/overlays/ztwim-instance/` with cluster-specific configuration:
  - Trust domain
  - OIDC discovery domain / Route host
  - `upstreamAuthority.certManager` patch pointing to the `spire-root-ca-issuer` ClusterIssuer
  - Root CA `Certificate` CR (`spire-cert-manager-ca.yaml`) in `cert-manager` namespace — must be in the overlay (not the component) to avoid namespace transformer override
- [ ] Sync-wave set to `15` (instance tier)
- [ ] Application entry in `clusters/etl7/values.yaml`:
  ```yaml
  ztwim-instance:
    annotations:
      argocd.argoproj.io/sync-wave: '15'
    source:
      path: clusters/etl7/overlays/ztwim-instance
  ```
- [ ] OIDC discovery endpoint is accessible via Route (for Vault's JWT auth to reach it)
- [ ] Component has a `readme.md`

### Dependencies

- Story 1 (ZTWIM Operator must be installed)

### Implementation Notes

- **SpireAgent and SpiffeCSIDriver are deployed with all defaults** — they are standard ZTWIM operands and part of the complete operand set, but they are not functionally used in this experiment. The VM's spire-agent (Story 6b) uses x509pop attestation and runs standalone inside the VM, not via the cluster-level SpireAgent DaemonSet. Deploy both with defaults for completeness.
- The OIDC discovery Route URL will be referenced by Story 5 (Vault trust config)
- **cert-manager UpstreamAuthority** (ZTWIM 1.1 feature) — the `SpireServer` CR's `spec.upstreamAuthority.certManager` is patched in the overlay to point at the `spire-root-ca-issuer` ClusterIssuer. ZTWIM auto-reconciles the SPIRE Server StatefulSet to load the plugin. No manual intermediate cert provisioning is needed.
- The same root CA ClusterIssuer issues the VM bootstrap cert (Story 6b) — one root of trust for everything
- The x509pop CA bundle still requires manual patching on the SPIRE Server (CRD limitation) but uses the same `spire-root-ca-secret` from the `cert-manager` namespace
- Reference: [OCP 4.22 ZTWIM docs §12.13 - UpstreamAuthority plugins](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/security_and_compliance/zero-trust-workload-identity-manager)

---

### Story 1.3: Deploy Vault on etl7 with Latest Images

**ID:** S3-vault-etl7

**As a** platform engineer,
**I want** Vault deployed on etl7 with up-to-date Red Hat certified images,
**So that** the zero-trust experiment has a local secret store running a current, supported version.

### Acceptance Criteria

- [ ] New overlay directory `clusters/etl7/overlays/vault/` created as a **copy** of `clusters/etl4/overlays/vault/`
- [ ] `kustomization.yaml` updated:
  - Helm chart version updated from `0.28.0` to `0.31.0`
- [ ] `values.yaml` updated with latest Red Hat certified image tags:
  - Server image: `registry.connect.redhat.com/hashicorp/vault:1.20.4-ubi`
  - Injector image: `registry.connect.redhat.com/hashicorp/vault-k8s:1.7.0-ubi`
  - Injector agent image: `registry.connect.redhat.com/hashicorp/vault:1.20.4-ubi`
  - CSI image: `registry.connect.redhat.com/hashicorp/vault-csi-provider:1.6.0-ubi`
  - Auto-initializer sidecar: `registry.connect.redhat.com/hashicorp/vault:1.20.4-ubi`
  - Auto-unsealer sidecar: `registry.connect.redhat.com/hashicorp/vault:1.20.4-ubi`
  - Vault-admin-initializer sidecar: `registry.connect.redhat.com/hashicorp/vault:1.20.4-ubi`
- [ ] Route host set to `vault.apps.${CLUSTER_BASE_DOMAIN}` (resolves to etl7 domain)
- [ ] ConsoleLink href updated for etl7
- [ ] Verify Helm values compatibility with chart version `0.31.0` — document any breaking changes from `0.28.0` → `0.31.0`
- [ ] Consider updating the `utility-downloader` init container UBI image from `ubi8:8.5`
- [ ] Application entry added to `clusters/etl7/values.yaml` at sync-wave `15`:
  ```yaml
  vault:
    annotations:
      argocd.argoproj.io/sync-wave: '15'
      argocd.argoproj.io/manifest-generate-paths: ".;/components/vault"
    destination:
      namespace: vault
    source:
      path: clusters/etl7/overlays/vault
    extraFields: |
      ignoreDifferences:
        - group: 'apps'
          jsonPointers:
            - /spec/volumeClaimTemplates
          kind: StatefulSet
  ```
- [ ] **etl4 Vault overlay is NOT modified**

### Dependencies

None

### Implementation Notes

- Copy from `clusters/etl4/overlays/vault/` as starting point
- The auto-init/unseal sidecar pattern from etl4 is acceptable for this experiment
- Latest image tags confirmed via:
  - [Red Hat Ecosystem Catalog](https://catalog.redhat.com/software/containers/hashicorp/vault/5fda55bd2937386820429e0c)
  - [vault-helm OpenShift docs](https://deepwiki.com/hashicorp/vault-helm/9.1-openshift)
  - [vault-helm issue #1168](https://github.com/hashicorp/vault-helm/issues/1168) — note the `-ubi` suffix requirement for Red Hat registry images
- The vault-admin-initializer sidecar configures Kubernetes auth at path `hub` — for etl7 this path naming should be reviewed (consider `etl7` instead of `hub`)

---

### Story 1.4: Deploy vault-config-operator on etl7

**ID:** S4-vault-config-operator

**As a** platform engineer,
**I want** the vault-config-operator deployed on etl7,
**So that** Vault configuration (auth methods, policies, secret engines, roles) can be managed declaratively via Kubernetes CRDs.

### Acceptance Criteria

- [ ] New component `components/vault-config-operator/` created
- [ ] Deployment via OperatorPolicy (if available on OperatorHub) or Helm chart:
  ```
  helm repo add vault-config-operator https://redhat-cop.github.io/vault-config-operator
  ```
- [ ] Targets namespace `vault-config-operator`
- [ ] Namespace created with:
  - `openshift.io/cluster-monitoring: "true"` label (for Prometheus metrics)
  - `argocd.argoproj.io/managed-by: openshift-gitops` label
- [ ] Sync-wave set to `5` (operator tier)
- [ ] Overlay at `clusters/etl7/overlays/vault-config-operator/` if cluster-specific config is needed
- [ ] Application entry in `clusters/etl7/values.yaml`:
  ```yaml
  vault-config-operator:
    annotations:
      argocd.argoproj.io/sync-wave: '5'
    source:
      path: components/vault-config-operator  # or clusters/etl7/overlays/vault-config-operator
  ```
- [ ] Component has a `readme.md`

### Dependencies

None (can deploy in parallel with Vault)

### Implementation Notes

- vault-config-operator v0.8.50 is the latest (July 2026)
- Available on OperatorHub as a community operator, or via Helm from [redhat-cop](https://github.com/redhat-cop/vault-config-operator)
- Key CRDs: `AuthEngineMount`, `KubernetesAuthEngineConfig`, `KubernetesAuthEngineRole`, `JWTOIDCAuthEngineConfig`, `JWTOIDCAuthEngineRole`, `SecretEngineMount`, `Policy`, `KVSecretEngineConfig`
- Prometheus metrics are exposed automatically when the namespace label is set

---

### Story 1.5: Configure SPIRE-Vault OIDC Trust via vault-config-operator

**ID:** S5-spire-vault-trust

**As a** platform engineer,
**I want** Vault configured to trust SPIRE-issued JWT-SVIDs via OIDC federation,
**So that** workloads with SPIFFE identities can authenticate to Vault without pre-shared credentials.

### Acceptance Criteria

- [ ] `vault-admin` namespace created with:
  - `argocd.argoproj.io/managed-by: openshift-gitops` label
  - ServiceAccount for vault-config-operator authentication to Vault
- [ ] **All** vault-config-operator CRDs created in the `vault-admin` namespace:

  **Authentication setup:**
  - [ ] `AuthEngineMount` — enables JWT auth engine at path `spire-jwt`
  - [ ] `JWTOIDCAuthEngineConfig` — configures the JWT auth engine:
    - `oidc_discovery_url` set to the SPIRE OIDC discovery Route URL (from Story 2)
    - `default_role` set to `spire-vm-role`

  **Authorization setup:**
  - [ ] `Policy` — Vault policy granting KV2 read access:
    ```hcl
    path "secret/data/experiment/*" {
      capabilities = ["read"]
    }
    ```
  - [ ] `JWTOIDCAuthEngineRole` — role `spire-vm-role`:
    - `role_type = "jwt"`
    - `bound_audiences` matching the audience used by spiffe-helper (e.g., `["vault"]`)
    - `bound_subject` matching the VM's SPIFFE ID (e.g., `spiffe://etl7.ocp.rht-labs.com/spire/agent/x509pop/<fingerprint>`)
    - `token_policies` referencing the read policy above
    - `token_ttl = "1h"`

  **Secret engine setup:**
  - [ ] `SecretEngineMount` — enables KV2 engine at path `secret/`
  - [ ] A manifest or Job writing a test secret at `secret/data/experiment/demo`:
    - Key: `message`
    - Value: a recognizable test string (e.g., `"Hello from Vault via SPIFFE zero-trust!"`)

  **Operator authentication:**
  - [ ] All CRDs include the `authentication` block referencing Kubernetes auth for the vault-admin SA:
    ```yaml
    spec:
      authentication:
        path: <kubernetes-auth-path>
        role: vault-admin
    ```
  - [ ] Vault Kubernetes auth engine configured to trust the vault-admin SA (may be handled by the auto-init sidecar from Story 3, or added here)

- [ ] Overlay at `clusters/etl7/overlays/vault-spire-trust/`
- [ ] Sync-wave set to `25` (depends on both Vault and ZTWIM instance being ready)
- [ ] Application entry in `clusters/etl7/values.yaml`:
  ```yaml
  vault-spire-trust:
    annotations:
      argocd.argoproj.io/sync-wave: '25'
    source:
      path: clusters/etl7/overlays/vault-spire-trust
  ```

### Dependencies

- Story 2 (SPIRE Server + OIDC discovery endpoint must be running)
- Story 3 (Vault must be deployed and initialized)
- Story 4 (vault-config-operator must be running)

### Implementation Notes

- Reference the [SPIFFE/Vault OIDC federation tutorial](https://spiffe.io/docs/latest/keyless/vault/readme/) for the overall flow
- Reference [OCP ZTWIM Vault OIDC docs §12.7.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/security_and_compliance/zero-trust-workload-identity-manager) for OpenShift-specific config
- The vault-config-operator CRD field names differ from raw `vault write` CLI commands — consult the [operator API types](https://github.com/redhat-cop/vault-config-operator/)
- The `bound_subject` in the JWT role must match exactly what SPIRE puts in the `sub` claim of the JWT-SVID. For x509pop-attested agents, this is typically `spiffe://<trust-domain>/spire/agent/x509pop/<cert-fingerprint>`
- The OIDC discovery URL must be reachable from Vault. If Vault runs on the same cluster, internal service URLs may work; otherwise, use the external Route

---

### Story 1.6a: Build RHEL 10 Image-Mode Bootc Image

**ID:** S6a-bootc-image

**As a** platform engineer,
**I want** a custom RHEL 10 bootc image containing all the components needed for the zero-trust demo,
**So that** I can deploy it as a VM on OpenShift Virtualization with all services pre-configured.

### Acceptance Criteria

- [ ] Directory `clusters/etl7/overlays/spire-vault-demo/image/` created containing:

  **Containerfile:**
  - [ ] Based on `registry.redhat.io/rhel10/rhel-bootc:10`
  - [ ] Installs spire-agent binary (from upstream SPIRE release tarball or RPM)
  - [ ] Installs spiffe-helper binary (from Red Hat SPIFFE Helper container image extraction or upstream release)
  - [ ] Installs vault binary (for vault-agent functionality)
  - [ ] Installs httpd (via `dnf install httpd`)
  - [ ] Installs `policycoreutils-python-utils` (for `semanage`)

  **Users, groups, and directory structure:**
  - [ ] Creates system users and groups:
    - `spire` user+group (runs spire-agent)
    - `spiffe-helper` user (runs spiffe-helper)
    - `spiffe-consumers` group (shared read access to SVID output)
    - `vault-agent-user` user (runs vault-agent)
    - Adds `spiffe-helper` and `vault-agent-user` to `spiffe-consumers` group
  - [ ] Creates required directories with correct ownership and permissions:
    - `/etc/spire/` (0755 root:root) — agent config
    - `/etc/spire/bootstrap/` (0500 spire:spire) — bootstrap cert, populated by cloud-init
    - `/var/run/secrets/spiffe/` (0750 spiffe-helper:spiffe-consumers) — SVID output
    - `/var/www/html/` (0755 root:root) — httpd document root
    - `/run/spire/sockets/` (0755 root:root) — agent socket
    - `/var/run/vault/` (0750 vault-agent-user:vault-agent-user) — vault token sink
    - `/etc/vault-agent/` (0755 root:root) — vault-agent config
    - `/etc/spiffe-helper/` (0755 root:root) — spiffe-helper config

  **SELinux contexts (set at build time):**
  - [ ] `semanage fcontext -a -t httpd_sys_rw_content_t "/var/www/html(/.*)?"`
  - [ ] `restorecon -Rv /var/www/html`
  - [ ] Ensures vault-agent written files inherit `httpd_sys_rw_content_t` context

  **Quadlet files at `/etc/containers/systemd/`:**
  - [ ] `spire-agent.container`:
    - Runs as user `spire`
    - Bind-mounts: `/etc/spire/bootstrap/:ro` (bootstrap cert), `/run/spire/sockets/` (socket output), `/etc/spire/agent.conf:ro`
    - Only container with access to `/etc/spire/bootstrap/`
  - [ ] `spiffe-helper.container`:
    - Runs as user `spiffe-helper`
    - Bind-mounts: `/run/spire/sockets/:ro` (agent socket), `/var/run/secrets/spiffe/` (SVID output), `/etc/spiffe-helper/:ro`
    - Writes SVID files with group `spiffe-consumers` (0640)
    - Depends on `spire-agent.container`
  - [ ] `vault-agent.container`:
    - Runs as user `vault-agent-user` (member of `spiffe-consumers` group)
    - Bind-mounts: `/var/run/secrets/spiffe/:ro` (reads JWT-SVID), `/var/www/html/` (writes secret), `/var/run/vault/` (token sink), `/etc/vault-agent/:ro`
    - Writes `secret.txt` with owner `vault-agent-user:apache`, mode `0644`, SELinux context `httpd_sys_rw_content_t`
    - No access to `/etc/spire/bootstrap/` or `/run/spire/sockets/`
    - Depends on `spiffe-helper.container`
  - [ ] `httpd.container`:
    - Runs as user `apache`
    - Bind-mounts: `/var/www/html/:ro` (reads secret only)
    - No access to `/etc/spire/`, `/run/spire/`, or `/var/run/secrets/spiffe/`
    - Depends on `vault-agent.container`

  **Configuration files embedded in the image:**
  - [ ] `/etc/spire/agent.conf` — SPIRE agent configuration (details in Story 6b)
  - [ ] `/etc/spiffe-helper/helper.conf` — SPIFFE helper configuration (details in Story 6b)
  - [ ] `/etc/vault-agent/agent.hcl` — Vault agent configuration (details in Story 6c)

- [ ] `readme.md` in `clusters/etl7/overlays/spire-vault-demo/` documenting:
  - How to build the image: `podman build -t quay.io/<org>/rhel10-spire-vault-demo:latest -f image/Containerfile image/`
  - How to push to quay.io: `podman push quay.io/<org>/rhel10-spire-vault-demo:latest`
  - The expected quay.io image reference
  - Prerequisites (Red Hat registry access, quay.io credentials)

- [ ] Image builds successfully and can be pushed to quay.io

### Dependencies

None (image build is independent of cluster deployment)

### Implementation Notes

- Follow the [RHEL 10 image-mode containerizing workloads guide](https://developers.redhat.com/articles/2025/01/13/containerizing-workloads-image-mode-rhel#managing_workloads_on_image_mode) for Quadlet patterns
- The image will be built and pushed manually — document the process in the readme
- Quadlet containers share state via bind-mounted host directories (socket, secrets, html)
- Consider using [logically bound images](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems/introducing-image-mode-for-rhel) for pre-fetching container images at update time

---

### Story 1.6b: Configure SPIRE Agent and SPIFFE Helper on the VM

**ID:** S6b-spire-agent-helper

**As a** platform engineer,
**I want** the SPIRE agent on the VM to attest to the cluster's SPIRE Server and the SPIFFE helper to extract both X.509 certificates and JWT-SVIDs,
**So that** the VM has a continuously refreshed SPIFFE identity and JWT token for Vault authentication.

### Acceptance Criteria

**SPIRE Agent configuration (`/etc/spire/agent.conf`):**
- [ ] `trust_domain` matching the SPIRE Server (e.g., `etl7.ocp.rht-labs.com`)
- [ ] `server_address` / `server_port` pointing to the cluster SPIRE Server (via Route or direct service if pod-network attached)
- [ ] `NodeAttestor "x509pop"` plugin configured with:
  - `private_key_path = "/etc/spire/bootstrap/agent.key.pem"`
  - `certificate_path = "/etc/spire/bootstrap/agent.crt.pem"`
- [ ] Workload API socket: `socket_path = "/run/spire/sockets/agent.sock"`
- [ ] Log level set appropriately for debugging (e.g., `DEBUG` initially)

**Bootstrap certificate provisioning:**
- [ ] cert-manager `Certificate` CR (`cert-bootstrap.yaml`) issuing a **1-year** leaf certificate:
  - Signed by the `spire-root-ca-issuer` **ClusterIssuer** (deployed by Story 1.2's `ztwim-instance` component/overlay)
  - Includes `digitalSignature` key usage (required by x509pop)
  - Unique common name per VM (e.g., `spire-vault-demo-vm.etl7.ocp.rht-labs.com`)
  - Stored in a Kubernetes Secret (`spire-bootstrap-cert` in `spire-vault-demo` namespace)
- [ ] **No separate CA Issuer chain in this overlay** — the old `cert-issuer.yaml` is deleted; the root CA is managed by `ztwim-instance`
- [ ] The **root CA certificate** from `spire-root-ca-secret` (in `cert-manager` namespace) is used for SPIRE Server's x509pop `ca_bundle_path` configuration (manual patching step — see readme.md)
- [ ] The leaf cert + private key are injected into the VM via **cloud-init** `write_files` directive:
  - `/etc/spire/bootstrap/agent.crt.pem` — leaf certificate (mode `0400`, owner `spire:spire`)
  - `/etc/spire/bootstrap/agent.key.pem` — private key (mode `0400`, owner `spire:spire`)
  - Source: the cert-manager-generated Secret
  - cloud-init must set correct ownership so only spire-agent can read the private key

**SPIFFE Helper configuration (`/etc/spiffe-helper/helper.conf`):**
- [ ] Watches the SPIRE Agent workload API socket at `/run/spire/sockets/agent.sock`
- [ ] Extracts **all supported identity types**:
  - **X.509 SVID:** Certificate (`svid.crt.pem`), private key (`svid.key.pem`), trust bundle (`bundle.crt.pem`)
  - **JWT-SVID:** Token for audience `vault` (`jwt-svid.token`) — must match `bound_audiences` in Vault JWT role from Story 5
  - **JWT Bundle (JWKS):** Verification keys (`jwt_bundle.json`) — enables local JWT-SVID validation without contacting SPIRE Server
  - *(Note: SPIFFE also defines WIT-SVIDs but spiffe-helper does not support them)*
- [ ] All output files written with ownership `spiffe-helper:spiffe-consumers` and mode `0640`
  - vault-agent (member of `spiffe-consumers`) can read; httpd and other processes cannot
- [ ] Continuously refreshes credentials as they rotate

### Dependencies

- Story 2 (SPIRE Server must be running with x509pop CA bundle configured)

### Implementation Notes

- The [x509pop agent plugin](https://github.com/spiffe/spire/blob/main/doc/plugin_agent_nodeattestor_x509pop.md) requires the leaf cert to have `digitalSignature` key usage
- The bootstrap cert is signed by the same `spire-root-ca-issuer` ClusterIssuer that provides SPIRE's UpstreamAuthority — one root of trust for everything
- The old `cert-issuer.yaml` (self-signed Issuer chain in `spire-vault-demo` namespace) has been deleted — replaced by ClusterIssuers in the `ztwim-instance` component
- See [Yulia Paterson's walkthrough on X.509 node attestation](https://medium.com/@yulia.paterson/spire-x-509-node-attestation-033bd157ce0d) for a step-by-step reference
- The SPIRE Server also needs a **registration entry** for this VM's workload — either via `ClusterSPIFFEID` CR or manual `spire-server entry create` — this is handled in Story 6d

---

### Story 1.6c: Configure Vault Agent and httpd on the VM

**ID:** S6c-vault-agent-httpd

**As a** platform engineer,
**I want** vault-agent on the VM to automatically authenticate to Vault using the SPIRE-issued JWT-SVID and serve the retrieved secret via httpd,
**So that** the end-to-end zero-trust secret delivery is demonstrated.

### Acceptance Criteria

**Vault Agent configuration (`/etc/vault-agent/agent.hcl`):**
- [ ] `vault` stanza with `address` set to `https://vault.apps.${CLUSTER_BASE_DOMAIN}`
- [ ] [JWT auto-auth method](https://developer.hashicorp.com/vault/docs/agent-and-proxy/autoauth/methods/jwt) configured:
  ```hcl
  auto_auth {
    method "jwt" {
      mount_path = "auth/spire-jwt"
      config = {
        path                     = "/var/run/secrets/spiffe/jwt-svid.token"
        role                     = "spire-vm-role"
        remove_jwt_after_reading = false
      }
    }
    sink "file" {
      config = {
        path = "/var/run/vault/token"
      }
    }
  }
  ```
- [ ] Template stanza that reads the KV2 secret and writes it to `/var/www/html/secret.txt`:
  ```hcl
  template {
    contents    = <<-EOF
      {{ with secret "secret/data/experiment/demo" }}{{ .Data.data.message }}{{ end }}
    EOF
    destination = "/var/www/html/secret.txt"
    perms       = "0644"
  }
  ```
- [ ] `enable_reauth_on_new_credentials = true` for JWT rotation handling
- [ ] TLS configured to trust the cluster CA (Vault's serving cert CA — either the OpenShift service-ca or Route CA)
- [ ] vault-agent runs as `vault-agent-user` (member of `spiffe-consumers` group for JWT-SVID read access)
- [ ] Written files at `/var/www/html/` must have:
  - Ownership: `vault-agent-user:apache`
  - Mode: `0644` (set via template `perms`)
  - SELinux context: `httpd_sys_rw_content_t` (inherited from parent directory fcontext set in Containerfile)

**httpd configuration:**
- [ ] httpd Quadlet `.container` file configured per [Red Hat containerizing workloads guide](https://developers.redhat.com/articles/2025/01/13/containerizing-workloads-image-mode-rhel#managing_workloads_on_image_mode)
- [ ] Bind-mounts `/var/www/html/:ro` from the host (read-only — httpd only reads, vault-agent writes from its own container)
- [ ] Serves a simple page at `/secret.txt` showing the secret content
- [ ] Listens on a known port (e.g., 8080)
- [ ] Accessible from the cluster network
- [ ] httpd runs as user `apache` — standard for RHEL httpd
- [ ] Verify httpd can read files with `httpd_sys_rw_content_t` SELinux context and `apache` group ownership

### Dependencies

- Story 5 (Vault JWT auth and KV2 secret must be configured)
- Story 6a (image must include vault and httpd binaries)
- Story 6b (SPIRE agent + helper must be providing the JWT-SVID)

### Implementation Notes

- Vault Agent handles token lifecycle automatically — initial auth, token renewal, re-auth on JWT rotation
- The template stanza will re-render `secret.txt` whenever the secret changes in Vault
- vault-agent's template `perms` field sets the file mode; the `group` field is not natively supported in older vault versions — verify with vault 1.20.4. If not supported, a wrapper script or `umask` in the Quadlet may be needed to ensure the `apache` group can read
- For the experiment, `VAULT_SKIP_VERIFY=true` may be needed if the Vault Route uses a self-signed cert — document this trade-off
- The httpd container can be a simple `registry.access.redhat.com/ubi9/httpd-24` or built into the bootc image directly
- **SELinux note:** On image-mode RHEL, the `semanage fcontext` rules set at build time in the Containerfile persist across boots. Files created at runtime by vault-agent in `/var/www/html/` will inherit the `httpd_sys_rw_content_t` context if the parent directory rule is set correctly. If not, a `restorecon` in vault-agent's Quadlet `ExecStartPost=` may be needed as a fallback

---

### Story 1.6d: Deploy the RHEL 10 Image-Mode VM on OpenShift Virtualization

**ID:** S6d-deploy-vm

**As a** platform engineer,
**I want** the demo VM deployed on etl7 via a VirtualMachine CR managed by ArgoCD,
**So that** the complete zero-trust secret delivery pipeline is running end-to-end.

### Acceptance Criteria

**VirtualMachine CR:**
- [ ] `VirtualMachine` CR in `clusters/etl7/overlays/spire-vault-demo/` referencing the quay.io bootc image
  - Source: `containerDisk` (ephemeral, simpler for experiment) or `DataVolume` — document the choice
- [ ] Adequate resources allocated (CPU, memory) for running spire-agent + spiffe-helper + vault-agent + httpd

**cloud-init configuration:**
- [ ] Injects bootstrap cert + key at `/etc/spire/bootstrap/`:
  - `agent.crt.pem` — leaf certificate (from cert-manager Secret)
  - `agent.key.pem` — private key (from cert-manager Secret)
- [ ] Sets the SPIRE Server address (environment variable or config file override)
- [ ] Sets the Vault address (environment variable or config file override)
- [ ] Any first-boot configuration: hostname, SSH keys for debugging, timezone

**Networking:**
- [ ] VM can reach the SPIRE Server (cluster service or route)
- [ ] VM can reach Vault (route)
- [ ] Service + Route (or NodePort) exposing the httpd endpoint on the VM

**SPIRE registration:**
- [ ] SPIRE Server registration entry for the VM created:
  - Via `ClusterSPIFFEID` CR or manual `spire-server entry create`
  - Maps the x509pop certificate fingerprint to a SPIFFE ID
  - The SPIFFE ID must match the `bound_subject` in the Vault JWT role (Story 5)

**ArgoCD integration:**
- [ ] Application entry in `clusters/etl7/values.yaml` at sync-wave `25`:
  ```yaml
  spire-vault-demo:
    annotations:
      argocd.argoproj.io/sync-wave: '25'
    source:
      path: clusters/etl7/overlays/spire-vault-demo
  ```

**End-to-end verification:**
- [ ] VM boots successfully
- [ ] spire-agent attests to SPIRE Server (check agent logs)
- [ ] spiffe-helper extracts JWT-SVID to `/var/run/secrets/spiffe/jwt-svid.token`
- [ ] vault-agent authenticates to Vault and writes secret to `/var/www/html/secret.txt`
- [ ] Browsing the httpd URL displays the Vault secret: `"Hello from Vault via SPIFFE zero-trust!"`

### Dependencies

- Story 2 (SPIRE Server running)
- Story 3 (Vault running on etl7)
- Story 5 (SPIRE↔Vault trust configured)
- Story 6a (bootc image built and pushed to quay.io)
- Story 6b (SPIRE agent + helper configs embedded in image)
- Story 6c (vault-agent + httpd configs embedded in image)

### Implementation Notes

- For `containerDisk`, the VM image is pulled as a container image on every boot — no persistence, but simple
- The cloud-init `write_files` directive can reference base64-encoded content from the cert-manager Secret
- Consider using a `Secret` resource and KubeVirt's `cloudInitNoCloud` with `secretRef` for the cert injection
- The SPIRE registration entry is critical — without it, the agent will attest but workloads won't receive SVIDs
- Debug workflow: `oc console <vm>` or SSH into the VM, check `systemctl status spire-agent`, `journalctl -u spire-agent`, verify socket exists, check spiffe-helper logs, check vault-agent logs

---

### Story 1.7: Add tpm_devid VM to the SPIRE/Vault Demo

**ID:** S7-tpm-devid-vm

**As a** platform engineer evaluating zero-trust workload identity,
**I want** a second VM in the `spire-vault-demo` overlay using `tpm_devid` attestation alongside the existing `x509pop` VM,
**So that** I can compare attestation methods side-by-side and demonstrate hardware-bound identity with vTPM.

### Acceptance Criteria

#### AC1: Shared bootc image supports both attestation methods

- [ ] The existing bootc image is updated to include `tpm2-tools` and `tpm2-tss` RPMs
- [ ] Ships dual SPIRE agent configs:
  - `/etc/spire/agent-x509pop.conf` — existing x509pop config (renamed from `agent.conf`)
  - `/etc/spire/agent-tpm-devid.conf` — new tpm_devid config with:
    ```hcl
    NodeAttestor "tpm_devid" {
        plugin_data {
            devid_cert_path  = "/etc/spire/tpm-devid/devid.crt.pem"
            devid_key_handle = "0x81000001"
        }
    }
    ```
- [ ] Ships dual Quadlet units:
  - `/etc/containers/systemd/spire-agent-x509pop.container` — enabled by default (renamed from `spire-agent.container`)
  - `/etc/containers/systemd/spire-agent-tpm-devid.container` — masked by default, includes `PodmanArgs=--device /dev/tpmrm0`
- [ ] Creates directory `/etc/spire/tpm-devid/` (0500 spire:spire) for DevID cert storage
- [ ] The existing x509pop VM continues to work unchanged with the updated image
- [ ] spiffe-helper, vault-agent, and httpd Quadlet units are unchanged and shared by both VMs

#### AC2: New Certificate CR for tpm_devid bootstrap

- [ ] `tpm-cert-bootstrap.yaml` creates a cert-manager `Certificate` in `spire-vault-demo` namespace:
  - Secret name: `tpm-devid-bootstrap-cert`
  - Issuer: `spire-root-ca-issuer` ClusterIssuer (same as x509pop)
  - Duration: 1 year (`8760h`), renewBefore: 30 days (`720h`)
  - Common name: `spire-vault-demo-tpm-vm.etl7.ocp.rht-labs.com`
  - Key usages: `digital signature`, `key encipherment`

#### AC3: New VirtualMachine CR with vTPM

- [ ] `tpm-virtual-machine.yaml` deploys `spire-vault-demo-tpm-vm` in `spire-vault-demo` namespace:
  - Uses the same shared bootc containerDisk image as the x509pop VM
  - `spec.template.spec.domain.devices.tpm: {}` enables persistent vTPM
  - Bootstrap cert Secret (`tpm-devid-bootstrap-cert`) mounted as a virtio disk with serial `TPMBOOTCERT`
  - cloud-init `runcmd` performs the following:
    1. Mask `spire-agent-x509pop.service`, unmask `spire-agent-tpm-devid.service`
    2. Mount the bootstrap cert CD-ROM
    3. Create storage root key: `tpm2_createprimary -C o -c /tmp/srk.ctx`
    4. Create LDevID key pair: `tpm2_create -C /tmp/srk.ctx -u /tmp/devid.pub -r /tmp/devid.priv`
    5. Load LDevID: `tpm2_load -C /tmp/srk.ctx -u /tmp/devid.pub -r /tmp/devid.priv -c /tmp/devid.ctx`
    6. Persist to handle `0x81000001`: `tpm2_evictcontrol -C o -c /tmp/devid.ctx 0x81000001`
    7. Copy DevID cert from mounted Secret to `/etc/spire/tpm-devid/devid.crt.pem`
    8. Set ownership: `chown spire:spire /etc/spire/tpm-devid/devid.crt.pem`, mode `0400`
    9. Unmount bootstrap cert CD-ROM, clean up temp files
    10. Create data directory, pre-pull images, start Quadlet services
  - SSH access via `raffa-key` Secret (same as x509pop VM)
  - Adequate resources: 2 cores, 4Gi memory, 20Gi root disk

#### AC4: Service and Route for the tpm VM

- [ ] `tpm-service.yaml` — Service targeting `spire-vault-demo-tpm-vm` on port 8080
- [ ] `tpm-route.yaml` — Route at `spire-vault-demo-tpm.apps.${CLUSTER_BASE_DOMAIN}`

#### AC5: x509pop-setup Job updated for tpm_devid attestor

- [ ] The existing `x509pop-setup-job.yaml` in `clusters/etl7/overlays/ztwim-instance/` is updated to also add the `tpm_devid` NodeAttestor plugin to the SPIRE Server ConfigMap:
  ```json
  {"tpm_devid":{"plugin_data":{"ca_bundle_path":"/tmp/x509pop-ca/ca.crt.pem"}}}
  ```
- [ ] Both attestors share the same root CA bundle (same `spire-root-ca-secret`)
- [ ] The awk script inserts both entries in a single ConfigMap patch (idempotent — skips if already present)

#### AC6: Separate registration Job for the tpm_devid VM

- [ ] `tpm-spire-registration-job.yaml` in `spire-vault-demo` overlay:
  - ArgoCD PostSync hook at sync-wave 10
  - Extracts SHA1 fingerprint from `tpm-devid-bootstrap-cert` Secret
  - Computes agent parentID: `spiffe://etl7.ocp.rht-labs.com/spire/agent/tpm_devid/<fingerprint>`
  - Creates workload registration entry with:
    - `spiffeID`: `spiffe://etl7.ocp.rht-labs.com/spire-vault-demo/tpm-workload`
    - `selector`: `unix:uid:10002` (spiffe-helper UID)
    - `jwt-svid-ttl`: `3600`
  - Idempotent — checks for existing entry before creating
  - Separate ServiceAccount and RBAC (same pattern as existing registration Job)
  - Cross-namespace RBAC for exec into ZTWIM namespace (same pattern as `spire-registration-rbac.yaml` in `ztwim-instance` overlay)

#### AC7: ArgoCD ignoreDifferences for the tpm VM

- [ ] The ArgoCD Application for `spire-vault-demo` in `clusters/etl7/values.yaml` includes:
  ```yaml
  ignoreDifferences:
    - group: kubevirt.io
      kind: VirtualMachine
      name: spire-vault-demo-tpm-vm
      jsonPointers:
        - /spec/template/spec/volumes
        - /spec/template/spec/domain/devices/disks
  ```
- [ ] This allows the manual demo step (remove bootstrap cert disk + restart) without ArgoCD drift

#### AC8: Documentation updated

- [ ] `readme.md` updated with:
  - tpm_devid VM architecture and cloud-init provisioning script
  - Manual demo steps: `oc patch vm` to remove bootstrap cert disk, `virtctl restart`
  - Debug-via-SSH workflow for cloud-init troubleshooting
  - Side-by-side comparison: x509pop vs tpm_devid (trust properties, key exposure, rotation)
  - New file layout listing the added files
  - End-to-end verification procedure for the tpm_devid VM

#### AC9: Manual demo steps documented (not automated)

- [ ] After the VM boots and cloud-init completes, the operator manually:
  1. Verifies tpm_devid provisioning: `virtctl ssh cloud-user@spire-vault-demo-tpm-vm`, check `/etc/spire/tpm-devid/devid.crt.pem`, `tpm2_getcap handles-persistent`
  2. Removes bootstrap cert disk: `oc patch vm spire-vault-demo-tpm-vm -n spire-vault-demo --type=json -p '[{"op":"remove","path":"/spec/template/spec/volumes/2"},{"op":"remove","path":"/spec/template/spec/domain/devices/disks/2"}]'`
  3. Restarts VM: `virtctl restart spire-vault-demo-tpm-vm -n spire-vault-demo`
  4. Verifies the VM re-attests using the persistent vTPM DevID (no bootstrap cert needed)
- [ ] These steps are documented in the readme but NOT automated via a Job

### Dependencies

- Story 1.6d (existing x509pop VM deployed and working — proves the shared infrastructure)
- Story 1.2 (SPIRE Server with x509pop attestor patched — the Job will add tpm_devid to the same server)

### Implementation Notes

- **Debug workflow**: The cloud-init TPM provisioning script is novel integration work. Debug iteratively:
  1. Deploy the VM with SSH access
  2. SSH in: `virtctl ssh cloud-user@spire-vault-demo-tpm-vm -n spire-vault-demo`
  3. Run `tpm2-tools` commands by hand to validate the provisioning sequence
  4. Once working, copy the validated commands back into the cloud-init `runcmd`
- **KubeVirt vTPM**: Setting `spec.template.spec.domain.devices.tpm: {}` enables persistent vTPM. KubeVirt creates a VM State PVC automatically. The vTPM device appears as `/dev/tpmrm0` inside the VM.
- **Shared image**: The Quadlet unit renaming (`spire-agent.container` → `spire-agent-x509pop.container`) requires updating the existing x509pop VM's cloud-init to reference the new service name (`spire-agent-x509pop.service` instead of `spire-agent.service`).
- **tpm_devid SPIFFE ID**: The agent SPIFFE ID for `tpm_devid` is `spiffe://<trust-domain>/spire/agent/tpm_devid/<fingerprint>`. The fingerprint is the SHA1 of the DevID certificate, which in our case is the same cert-manager leaf cert — so the registration Job can compute it the same way as the x509pop Job.
- **Vault bound_subject**: The tpm_devid VM uses a different workload SPIFFE ID (`spire-vault-demo/tpm-workload`). The Vault JWT role's `bound_subject` or `bound_claims` must be updated to accept both SPIFFE IDs, or a second role must be created. Evaluate whether `bound_claims_type = "glob"` with a wildcard pattern is acceptable for the demo.
- **Estimate**: 3-4 days implementation + 1-2 days cloud-init debugging
