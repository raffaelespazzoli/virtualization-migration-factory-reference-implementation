---
baseline_commit: c17fdf40fe5bd9f4bbdf6d45062e21a78fe4233d
---

# Story 1.3: Deploy Vault on etl7 with Latest Images

Status: done

## Story

As a platform engineer,
I want Vault deployed on etl7 with up-to-date Red Hat certified images,
so that the zero-trust experiment has a local secret store running a current, supported version.

## Acceptance Criteria

1. New overlay directory `clusters/etl7/overlays/vault/` created containing **only** `kustomization.yaml` and `values.yaml` — derived from `clusters/etl4/overlays/vault/` (do NOT copy the `charts/` directory; the Kustomize `helmCharts` feature fetches the chart from the remote repo)
2. `kustomization.yaml` updated: Helm chart version changed from `0.28.0` to `0.31.0`
3. `values.yaml` updated with latest Red Hat certified UBI image tags:
   - Server image: `registry.connect.redhat.com/hashicorp/vault:1.20.4-ubi`
   - Injector image: `registry.connect.redhat.com/hashicorp/vault-k8s:1.7.0-ubi`
   - Injector agent image: `registry.connect.redhat.com/hashicorp/vault:1.20.4-ubi`
   - CSI image: `registry.connect.redhat.com/hashicorp/vault-csi-provider:1.6.0-ubi`
   - Auto-initializer sidecar: `registry.connect.redhat.com/hashicorp/vault:1.20.4-ubi`
   - Auto-unsealer sidecar: `registry.connect.redhat.com/hashicorp/vault:1.20.4-ubi`
   - Vault-admin-initializer sidecar: `registry.connect.redhat.com/hashicorp/vault:1.20.4-ubi`
4. Route host set to `vault.apps.${CLUSTER_BASE_DOMAIN}` (already uses envsubst, resolves to etl7 domain)
5. ConsoleLink href updated for etl7 (already uses `${CLUSTER_BASE_DOMAIN}`, so the envsubst replacement handles this)
6. Vault-admin-initializer sidecar updated: Kubernetes auth path changed from `hub` to `etl7` (etl7 is not the hub cluster)
7. Utility-downloader init container UBI image updated from `registry.access.redhat.com/ubi8/ubi:8.5` to `registry.access.redhat.com/ubi9/ubi:9.5` (RHEL 8 is in ELS; UBI9 is the current standard)
8. Application entry added to `clusters/etl7/values.yaml` at sync-wave `15`
9. **etl4 Vault overlay is NOT modified** — no changes to any file under `clusters/etl4/`

## Tasks / Subtasks

- [x] Task 1: Create `clusters/etl7/overlays/vault/` directory (AC: #1)
- [x] Task 2: Create `kustomization.yaml` — copy from etl4, update chart version (AC: #1, #2)
  - [x] 2.1: Copy etl4's `kustomization.yaml` structure (resources, patches, helmCharts)
  - [x] 2.2: Change `helmCharts[0].version` from `0.28.0` to `0.31.0`
  - [x] 2.3: Verify resource path `../../../../components/vault` is correct from new overlay location
- [x] Task 3: Create `values.yaml` — copy from etl4, update all image tags (AC: #3, #4, #5)
  - [x] 3.1: Update `server.image.tag` from `1.17.1-ubi` to `1.20.4-ubi`
  - [x] 3.2: Update `injector.image.tag` from `1.4.2-ubi` to `1.7.0-ubi`
  - [x] 3.3: Update `injector.agentImage.tag` from `1.17.1-ubi` to `1.20.4-ubi`
  - [x] 3.4: Update `csi.image.repository` from `docker.io/hashicorp/vault-csi-provider` to `registry.connect.redhat.com/hashicorp/vault-csi-provider`
  - [x] 3.5: Update `csi.image.tag` from `1.4.2` to `1.6.0-ubi`
  - [x] 3.6: Update auto-initializer sidecar image tag from `1.17.1-ubi` to `1.20.4-ubi`
  - [x] 3.7: Update auto-unsealer sidecar image tag from `1.17.1-ubi` to `1.20.4-ubi`
  - [x] 3.8: Update vault-admin-initializer sidecar image tag from `1.17.1-ubi` to `1.20.4-ubi`
  - [x] 3.9: Update utility-downloader image from `registry.access.redhat.com/ubi8/ubi:8.5` to `registry.access.redhat.com/ubi9/ubi:9.5`
- [x] Task 4: Update vault-admin-initializer Kubernetes auth path (AC: #6)
  - [x] 4.1: Change `vault auth enable --path hub kubernetes` to `vault auth enable --path etl7 kubernetes`
  - [x] 4.2: Change `vault write auth/hub/config` to `vault write auth/etl7/config`
  - [x] 4.3: Change `vault write auth/hub/role/vault-admin` to `vault write auth/etl7/role/vault-admin`
- [x] Task 5: Add application entry to `clusters/etl7/values.yaml` (AC: #8)
  - [x] 5.1: Add `vault` entry under `# Zero Trust` section (create section if it doesn't exist yet)
  - [x] 5.2: Sync-wave `'15'`, destination namespace `vault`, source path `clusters/etl7/overlays/vault`
  - [x] 5.3: Include `manifest-generate-paths` annotation and `ignoreDifferences` for StatefulSet volumeClaimTemplates
- [x] Task 6: Verify no etl4 files were modified (AC: #9)

### Review Findings

- [x] [Review][Defer] Helm `server.route.host` uses `${BASE_DOMAIN}` while Route/ConsoleLink patches use `${CLUSTER_BASE_DOMAIN}` [`clusters/etl7/overlays/vault/values.yaml:35`] — deferred, pre-existing
- [x] [Review][Defer] Auto-initializer echoes unseal key and root token to container logs [`clusters/etl7/overlays/vault/values.yaml:116-120`] — deferred, pre-existing
- [x] [Review][Defer] `utility-downloader` fetches kubectl/jq from the public internet with no checksums, amd64-only [`clusters/etl7/overlays/vault/values.yaml:79-89`] — deferred, pre-existing
- [x] [Review][Defer] Init/unseal/admin sidecar scripts have no failure handling (lost init material, unquoted keys, empty files, partial kubernetes auth) [`clusters/etl7/overlays/vault/values.yaml:112-206`] — deferred, pre-existing
- [x] [Review][Defer] `vault-admin-initializer` talks to `https://vault.vault.svc:8200` instead of localhost in the same pod [`clusters/etl7/overlays/vault/values.yaml:167-168`] — deferred, pre-existing
- [x] [Review][Defer] Helm chart `vault-server-test` treats a sealed Vault as success; overlay has no assertion of init/unseal/`etl7` auth [`clusters/etl7/overlays/vault/kustomization.yaml:30-36`] — deferred, pre-existing
- [x] [Review][Defer] Init/unseal sidecars set `VAULT_SKIP_VERIFY=true` while also setting `VAULT_CACERT` [`clusters/etl7/overlays/vault/values.yaml:102-107`] — deferred, pre-existing

## Dev Notes

### Overlay Structure — What to Copy and What to Skip

The etl4 overlay at `clusters/etl4/overlays/vault/` contains:
- `kustomization.yaml` — **COPY THIS** (with modifications)
- `values.yaml` — **COPY THIS** (with modifications)
- `charts/vault/` — **DO NOT COPY** — this is a stale local chart cache (version 0.25.0 per its Chart.yaml). The `helmCharts:` section in `kustomization.yaml` fetches the chart from `https://helm.releases.hashicorp.com` at the specified version. Kustomize handles chart download automatically.

The etl7 overlay directory should contain exactly 2 files:
```
clusters/etl7/overlays/vault/
├── kustomization.yaml
└── values.yaml
```

### Base Component: `components/vault/`

The base component at `components/vault/` provides supplementary Kubernetes resources alongside the Helm chart. It contains:
- `namespace.yaml` — creates the `vault` namespace with standard annotations/labels
- `link.yaml` — ConsoleLink for the OpenShift console app menu
- `role-binding.yaml` — RoleBinding granting `edit` to the `vault` ServiceAccount
- `kustomization.yaml` — references namespace.yaml, link.yaml, role-binding.yaml (route.yaml is commented out)

The overlay's `kustomization.yaml` includes this base via `resources: [../../../../components/vault]` and applies Kustomize patches to set cluster-specific values (Route host, ConsoleLink href).

### ⚠️ CRITICAL: Helm Chart 0.28.0 → 0.31.0 Compatibility

Researched the full [vault-helm CHANGELOG](https://github.com/hashicorp/vault-helm/blob/main/CHANGELOG.md) for all changes between 0.28.0 and 0.31.0:

**Changes in 0.28.1 (July 2024):**
- Default vault: 1.17.2, vault-k8s: 1.4.2, vault-csi-provider: 1.4.3
- Improvement: configurable `tlsConfig` and `authorization` for Prometheus ServiceMonitor
- No breaking changes

**Changes in 0.29.0 (Nov 2024):**
- Default vault: 1.18.1, vault-k8s: 1.5.0, vault-csi-provider: 1.5.0
- KNOWN ISSUE: Template support in server config broke ([GH-1072](https://github.com/hashicorp/vault-helm/issues/1072)) — **fixed in 0.29.1**
- Feature: CSI hostNetwork parameter support
- No breaking changes to our values

**Changes in 0.29.1 (Nov 2024):**
- Fix: restored template support in server config

**Changes in 0.30.0 (Mar 2025):**
- Default vault: 1.19.0, vault-k8s: 1.6.2
- Feature: custom preStop commands
- Bug fix: invalid yaml when volumeMounts/volumes empty
- No breaking changes

**Changes in 0.30.1 (Jul 2025):**
- Default vault: 1.20.1, vault-k8s: 1.7.0, vault-csi-provider: 1.5.1
- No breaking changes

**Changes in 0.31.0 (Sep 2025):**
- Default vault: 1.20.4, vault-csi-provider: 1.6.0
- **POTENTIAL IMPACT:** Default `csi.daemonSet.providersDir` changed to `/var/run/secrets-store-csi-providers` — since we don't use the CSI driver and don't override `providersDir` in our values, this is a no-op for us
- Feature: Red Hat certified vault-csi-provider UBI image added to OpenShift defaults

**Conclusion:** No breaking changes affect our `values.yaml` configuration. The `standalone.config` HCL block, `extraContainers`, `extraInitContainers`, `extraVolumes`, `volumes`, and `volumeMounts` values structures are unchanged across all versions. Safe to upgrade.

### ⚠️ CRITICAL: CSI Image — Registry AND Tag Both Change

The etl4 CSI image is NOT from the Red Hat certified registry:
```yaml
# etl4 (WRONG — docker.io, no -ubi suffix):
csi:
  image:
    repository: "docker.io/hashicorp/vault-csi-provider"
    tag: "1.4.2"
    pullPolicy: IfNotPresent
```

The etl7 update must change **both** repository and tag:
```yaml
# etl7 (CORRECT — Red Hat certified, UBI suffix):
csi:
  image:
    repository: "registry.connect.redhat.com/hashicorp/vault-csi-provider"
    tag: "1.6.0-ubi"
    pullPolicy: IfNotPresent
```

This matches the [vault-helm OpenShift defaults](https://deepwiki.com/hashicorp/vault-helm/9.1-openshift) and the `-ubi` suffix requirement documented in [vault-helm issue #1168](https://github.com/hashicorp/vault-helm/issues/1168).

### ⚠️ CRITICAL: Kubernetes Auth Path — `hub` → `etl7`

The `vault-admin-initializer` sidecar in etl4 creates a Kubernetes auth backend at path `hub` because etl4 is the hub cluster. In etl7, this must change to `etl7`.

Three lines must be updated in the sidecar script:
```bash
# etl4 (hub path):
vault auth enable --path hub kubernetes
vault write auth/hub/config kubernetes_host=https://kubernetes.default.svc:443 ...
vault write auth/hub/role/vault-admin ...

# etl7 (etl7 path):
vault auth enable --path etl7 kubernetes
vault write auth/etl7/config kubernetes_host=https://kubernetes.default.svc:443 ...
vault write auth/etl7/role/vault-admin ...
```

**Cross-story impact:** Story 1.5 (vault-config-operator CRDs) will reference this auth path in the `authentication.path` field. Use `etl7` here and Story 1.5 will reference `etl7`. Document this in the story file for continuity.

### ⚠️ CRITICAL: The `-ubi` Suffix is MANDATORY

All images on `registry.connect.redhat.com` require the `-ubi` suffix. Without it, the image pull will fail with `ImagePullBackOff` / "Image not found". This is confirmed by [vault-helm issue #1168](https://github.com/hashicorp/vault-helm/issues/1168) and [Red Hat Ecosystem Catalog](https://catalog.redhat.com/software/containers/hashicorp/vault/5fda55bd2937386820429e0c).

Verified available tags:
- `registry.connect.redhat.com/hashicorp/vault:1.20.4-ubi` ✅
- `registry.connect.redhat.com/hashicorp/vault-k8s:1.7.0-ubi` ✅
- `registry.connect.redhat.com/hashicorp/vault-csi-provider:1.6.0-ubi` ✅

### Exact File Templates

#### `clusters/etl7/overlays/vault/kustomization.yaml`

Copy from etl4 with only the `version` field changed:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: vault
resources:
  - ../../../../components/vault

patches:
  - target:
      kind: Service
      name: vault-internal
    patch: |
      - op: remove
        path: /metadata/annotations/service.beta.openshift.io~1serving-cert-secret-name
  - target:
      kind: Route
      name: vault
      namespace: vault
    patch: |
      - op: replace
        path: /spec/host
        value: "vault.apps.${CLUSTER_BASE_DOMAIN}"
  - target:
      kind: ConsoleLink
    patch: |
      - op: replace
        path: /spec/href
        value: "https://vault.apps.${CLUSTER_BASE_DOMAIN}"

helmCharts:
  - name: vault
    releaseName: vault
    namespace: vault
    repo: https://helm.releases.hashicorp.com
    version: 0.31.0
    valuesFile: values.yaml
```

Changes from etl4:
- `version: 0.28.0` → `version: 0.31.0`
- No other changes (Route host and ConsoleLink already use `${CLUSTER_BASE_DOMAIN}` envsubst variable)

#### `clusters/etl7/overlays/vault/values.yaml`

Copy from etl4 with all image tags and auth path updated. The complete file:

```yaml
installCRDs: true
global:
  openshift: true
  tlsDisable: false

ui:
  enabled: true

injector:
  enabled: true
  image:
    repository: "registry.connect.redhat.com/hashicorp/vault-k8s"
    tag: "1.7.0-ubi"

  agentImage:
    repository: "registry.connect.redhat.com/hashicorp/vault"
    tag: "1.20.4-ubi"

csi:
  image:
    repository: "registry.connect.redhat.com/hashicorp/vault-csi-provider"
    tag: "1.6.0-ubi"
    pullPolicy: IfNotPresent

server:
  image:
    tag: "1.20.4-ubi"
    repository: registry.connect.redhat.com/hashicorp/vault

  extraEnvironmentVars:
    VAULT_LOG_LEVEL: debug

  route:
    enabled: true
    host: vault.apps.${BASE_DOMAIN}
    tls:
      termination: reencrypt

  extraVolumes:
    - type: secret
      name: vault-server-tls

  volumes:
    - name: plugins
      emptyDir: {}
    - name: vault-root-token
      secret:
        secretName: vault-init
        optional: true

  volumeMounts:
    - mountPath: /usr/local/libexec/vault
      name: plugins
      readOnly: false

  standalone:
    enabled: true
    config: |
      ui = true
      listener "tcp" {
        address = "[::]:8200"
        cluster_address = "[::]:8201"
        tls_cert_file = "/vault/userconfig/vault-server-tls/tls.crt"
        tls_key_file  = "/vault/userconfig/vault-server-tls/tls.key"
        tls_client_ca_file = "/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt"
      }

      storage "file" {
        path = "/vault/data"
      }

      plugin_directory = "/usr/local/libexec/vault"

  service:
    annotations:
      service.beta.openshift.io/serving-cert-secret-name: vault-server-tls

  extraInitContainers:
    - name: utility-downloader
      image: registry.access.redhat.com/ubi9/ubi:9.5
      command:
      - /bin/bash
      - -c
      - |
          cd /usr/local/libexec/vault
          curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
          chmod +x kubectl
          curl -L -o jq https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64
          chmod +x jq
      volumeMounts:
        - name: plugins
          mountPath: /usr/local/libexec/vault

  extraContainers:
    - name: auto-initializer
      image: registry.connect.redhat.com/hashicorp/vault:1.20.4-ubi
      env:
      - name: NAMESPACE
        valueFrom:
          fieldRef:
            fieldPath: metadata.namespace
      - name: VAULT_SKIP_VERIFY
        value: "true"
      - name: VAULT_ADDR
        value: https://localhost:8200
      - name: VAULT_CACERT
        value: /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt
      command:
      - /bin/bash
      - -c
      - |
          while true; do
            sleep 5
            if [[ $(vault status | grep "Initialized" | grep "false") ]]; then
              export INIT_RESPONSE=$(vault operator init -format=json -key-shares 1 -key-threshold 1)
              echo "$INIT_RESPONSE"
              export UNSEAL_KEY=$(echo "$INIT_RESPONSE" | /usr/local/libexec/vault/jq -r .unseal_keys_b64[0])
              export ROOT_TOKEN=$(echo "$INIT_RESPONSE" | /usr/local/libexec/vault/jq -r .root_token)
              echo "$UNSEAL_KEY"
              echo "$ROOT_TOKEN"
              /usr/local/libexec/vault/kubectl delete secret vault-init -n ${NAMESPACE}
              /usr/local/libexec/vault/kubectl create secret generic vault-init -n ${NAMESPACE} --from-literal=unseal_key=${UNSEAL_KEY} --from-literal=root_token=${ROOT_TOKEN}
            else
              echo vault already initialized
              sleep 5
            fi
          done
      volumeMounts:
        - name: plugins
          mountPath: /usr/local/libexec/vault
    - name: auto-unsealer
      image: registry.connect.redhat.com/hashicorp/vault:1.20.4-ubi
      env:
      - name: VAULT_SKIP_VERIFY
        value: "true"
      - name: VAULT_ADDR
        value: https://localhost:8200
      - name: VAULT_CACERT
        value: /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt
      command:
      - /bin/bash
      - -c
      - |
          while true; do
            sleep 5
            if [[ $(vault status | grep "Initialized" | grep "true") ]]; then
              if [[ $(vault status | grep "Sealed" | grep "true") ]]; then
                if [[ -f /vault-root-token/unseal_key ]]; then
                  vault operator unseal $(cat /vault-root-token/unseal_key)
                else
                  echo unseal key not initialized yet
                fi
              else
                echo vault already unsealed
              fi
            else
              echo Vault not initialized yet
            fi
          done
      volumeMounts:
        - name: vault-root-token
          mountPath: /vault-root-token

    - name: vault-admin-initializer
      image: registry.connect.redhat.com/hashicorp/vault:1.20.4-ubi
      env:
      - name: VAULT_ADDR
        value: https://vault.vault.svc:8200
      - name: VAULT_CACERT
        value: /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt
      command:
      - /bin/bash
      - -c
      - |
        while true; do
          sleep 5
          if [[ -f /vault-root-token/root_token ]]; then
            export VAULT_TOKEN=$(cat /vault-root-token/root_token)
            if [[ $(vault status | grep "Sealed" | grep "false") ]]; then
                  if [[ ! $(vault policy list | grep vault-admin) ]]; then
                vault auth enable --path etl7 kubernetes
                vault write auth/etl7/config kubernetes_host=https://kubernetes.default.svc:443 kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
                vault write auth/etl7/role/vault-admin bound_service_account_names=default bound_service_account_namespaces=vault-admin policies=vault-admin ttl=1h
                cat << EOF | vault policy write vault-admin -
                  path "/*" {
                    capabilities = ["create", "read", "update", "delete", "list","sudo"]
                  }
        EOF
              else
                echo vault admin already configured
                echo creating accessor configmap
                accessor=$(vault auth list -detailed | grep etl7 | awk '{print $3}')
                if /usr/local/libexec/vault/kubectl get configmap kubeauth-accessor -n vault; then
                  /usr/local/libexec/vault/kubectl patch configmap kubeauth-accessor -n vault -p '{"data":{"accessor": "'"${accessor}"'"}}'
                else
                  /usr/local/libexec/vault/kubectl create configmap kubeauth-accessor -n vault --from-literal=accessor=${accessor}
                fi
                sleep 5
              fi
            else
              echo vault still sealed
            fi
          else
            echo root token not initialized yet
          fi
        done
      volumeMounts:
        - name: vault-root-token
          mountPath: /vault-root-token
        - name: plugins
          mountPath: /usr/local/libexec/vault
```

Changes from etl4:
1. `injector.image.tag`: `1.4.2-ubi` → `1.7.0-ubi`
2. `injector.agentImage.tag`: `1.17.1-ubi` → `1.20.4-ubi`
3. `csi.image.repository`: `docker.io/hashicorp/vault-csi-provider` → `registry.connect.redhat.com/hashicorp/vault-csi-provider`
4. `csi.image.tag`: `1.4.2` → `1.6.0-ubi`
5. `server.image.tag`: `1.17.1-ubi` → `1.20.4-ubi`
6. `utility-downloader` image: `ubi8/ubi:8.5` → `ubi9/ubi:9.5`
7. `auto-initializer` sidecar image tag: `1.17.1-ubi` → `1.20.4-ubi`
8. `auto-unsealer` sidecar image tag: `1.17.1-ubi` → `1.20.4-ubi`
9. `vault-admin-initializer` sidecar image tag: `1.17.1-ubi` → `1.20.4-ubi`
10. `vault-admin-initializer` auth path: `hub` → `etl7` (three occurrences in the script)
11. Removed commented-out `#externalVaultAddr` line (not applicable to etl7)
12. Removed commented-out `#VAULT_CACERT` env var (not applicable)

#### `clusters/etl7/values.yaml` — add this block

Insert under a `# Zero Trust` section comment. If Story 1.1 has already been implemented and the section exists, append after the existing entries. If not, create the section. Place it after the `# Storage` section:

```yaml
# Zero Trust

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

The `ignoreDifferences` for StatefulSet `volumeClaimTemplates` is required because Kubernetes adds default fields to volumeClaimTemplates that don't match the Helm-rendered template, causing ArgoCD to show perpetual out-of-sync.

### Image Version Summary Table

| Component | etl4 (current) | etl7 (target) |
|---|---|---|
| Server | `vault:1.17.1-ubi` | `vault:1.20.4-ubi` |
| Injector | `vault-k8s:1.4.2-ubi` | `vault-k8s:1.7.0-ubi` |
| Injector Agent | `vault:1.17.1-ubi` | `vault:1.20.4-ubi` |
| CSI Provider | `docker.io/.../vault-csi-provider:1.4.2` | `registry.connect.redhat.com/.../vault-csi-provider:1.6.0-ubi` |
| Auto-initializer | `vault:1.17.1-ubi` | `vault:1.20.4-ubi` |
| Auto-unsealer | `vault:1.17.1-ubi` | `vault:1.20.4-ubi` |
| Vault-admin-init | `vault:1.17.1-ubi` | `vault:1.20.4-ubi` |
| Utility-downloader | `ubi8/ubi:8.5` | `ubi9/ubi:9.5` |
| Helm chart | `0.28.0` | `0.31.0` |

### Files Created/Modified by This Story

| File | Action | Notes |
|---|---|---|
| `clusters/etl7/overlays/vault/kustomization.yaml` | NEW | Overlay Kustomize config with Helm chart v0.31.0 |
| `clusters/etl7/overlays/vault/values.yaml` | NEW | Helm values with latest UBI images |
| `clusters/etl7/values.yaml` | UPDATE | Add `vault` application entry under Zero Trust section |

### What NOT to Do

- **Do NOT copy the `charts/` directory** from etl4 — it's a stale cache (v0.25.0) and the Kustomize `helmCharts:` feature fetches from the remote repo
- **Do NOT modify any file under `clusters/etl4/`** — etl4's Vault deployment is production and must not be touched
- **Do NOT use image tags without the `-ubi` suffix** on `registry.connect.redhat.com` — they don't exist and will cause ImagePullBackOff errors
- **Do NOT use `docker.io` for the CSI provider** — use the Red Hat certified image at `registry.connect.redhat.com`
- **Do NOT keep the Kubernetes auth path as `hub`** — etl7 is not the hub cluster; use `etl7`
- **Do NOT add this to `groups/prod/values.yaml`** — this is an etl7-only experiment
- **Do NOT modify the base component at `components/vault/`** — all customization goes in the overlay

### Codebase Patterns to Follow

This story follows the established overlay pattern used by `clusters/etl4/overlays/vault/`:
- Overlay directory at `clusters/<cluster>/overlays/<component>/` with kustomization.yaml + values.yaml
- Base component at `components/vault/` provides namespace, ConsoleLink, RoleBinding
- Kustomize patches customize cluster-specific values (Route host, ConsoleLink href)
- Helm chart rendered via Kustomize's `helmCharts:` feature (not a local chart)
- The `manifest-generate-paths` annotation tells ArgoCD which paths to watch for changes
- The `ignoreDifferences` field prevents false out-of-sync on StatefulSet volumeClaimTemplates

### Cross-Story Dependencies and Impact

| Story | Relationship | Impact |
|---|---|---|
| **Story 1.1** (ZTWIM Operator) | Independent — no dependency | Both can be implemented in parallel |
| **Story 1.2** (ZTWIM Instance) | Independent — no dependency | Both can be implemented in parallel |
| **Story 1.4** (vault-config-operator) | Independent — no dependency | Can be implemented in parallel; VCO will connect to this Vault |
| **Story 1.5** (SPIRE↔Vault Trust) | Consumer — uses this Vault | VCO CRDs reference Vault; the `authentication.path` field will use `etl7` (matching our auth path) |

### Project Structure Notes

- Overlay lives at `clusters/etl7/overlays/vault/` following the `clusters/<cluster>/overlays/<component>/` convention
- References the reusable base component at `components/vault/`
- The `values.yaml` entry in `clusters/etl7/values.yaml` follows the same `applications:` map structure as all other entries in the file
- Wave `15` is appropriate — Vault is an operand/instance, same tier as other middleware

### References

- [vault-helm CHANGELOG](https://github.com/hashicorp/vault-helm/blob/main/CHANGELOG.md) — full version history 0.28.0 → 0.31.0
- [vault-helm v0.31.0 release](https://github.com/hashicorp/vault-helm/releases/tag/v0.31.0) — release notes
- [vault-helm OpenShift docs (DeepWiki)](https://deepwiki.com/hashicorp/vault-helm/9.1-openshift) — UBI image mapping table
- [Run Vault on OpenShift (HashiCorp)](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/helm/openshift) — official install guide
- [vault-helm issue #1168](https://github.com/hashicorp/vault-helm/issues/1168) — `-ubi` suffix requirement for Red Hat registry
- [Red Hat Ecosystem Catalog — Vault](https://catalog.redhat.com/software/containers/hashicorp/vault/5fda55bd2937386820429e0c) — available image tags
- [Red Hat Ecosystem Catalog — vault-csi-provider](https://catalog.redhat.com/en/software/containers/hashicorp/vault-csi-provider/68b8ae86c5013defd972d886) — CSI provider image
- [Source: epic-zero-trust-secret-delivery-etl7.md — Story 1.3]
- [Pattern reference: clusters/etl4/overlays/vault/] — source overlay being adapted

## Dev Agent Record

### Agent Model Used

Claude Opus 4.6

### Debug Log References

No issues encountered. All tasks completed in a single pass.

### Completion Notes List

- Created `clusters/etl7/overlays/vault/` with exactly 2 files (kustomization.yaml, values.yaml) — no `charts/` directory copied
- Helm chart version upgraded from 0.28.0 to 0.31.0 (no breaking changes per CHANGELOG analysis in Dev Notes)
- All 8 image tags updated to latest Red Hat certified UBI versions (server, injector, injector agent, CSI provider, auto-initializer, auto-unsealer, vault-admin-initializer, utility-downloader)
- CSI provider image changed from docker.io to registry.connect.redhat.com with -ubi suffix
- Utility-downloader base image updated from UBI8 to UBI9
- Kubernetes auth path changed from `hub` to `etl7` in all 3 vault-admin-initializer script locations plus the accessor grep
- Vault application entry added to `clusters/etl7/values.yaml` under existing `# Zero Trust` section at sync-wave 15 with ignoreDifferences for StatefulSet volumeClaimTemplates
- Removed commented-out `#externalVaultAddr` and `#VAULT_CACERT` lines (not applicable to etl7)
- Confirmed zero modifications to any file under `clusters/etl4/`
- Cross-story note: Story 1.5 (vault-config-operator CRDs) should reference `authentication.path: etl7` to match this auth backend path

### Change Log

- 2026-09-15: Story 1.3 implemented — created etl7 Vault overlay with updated images and auth path, added application entry to cluster values

### File List

| File | Action |
|---|---|
| `clusters/etl7/overlays/vault/kustomization.yaml` | NEW |
| `clusters/etl7/overlays/vault/values.yaml` | NEW |
| `clusters/etl7/values.yaml` | MODIFIED |
