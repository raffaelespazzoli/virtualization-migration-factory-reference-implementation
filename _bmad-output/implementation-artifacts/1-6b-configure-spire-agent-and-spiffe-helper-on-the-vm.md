# Story 1.6b: Configure SPIRE Agent and SPIFFE Helper on the VM

Status: ready-for-dev

## Story

As a platform engineer,
I want the SPIRE agent on the VM to attest to the cluster's SPIRE Server and the SPIFFE helper to extract both X.509 certificates and JWT-SVIDs,
so that the VM has a continuously refreshed SPIFFE identity and JWT token for Vault authentication.

## Acceptance Criteria

1. SPIRE agent configuration file (`/etc/spire/agent.conf`) finalized with correct trust domain, server address, x509pop attestor, workload API socket, and log level
2. SPIFFE helper configuration file (`/etc/spiffe-helper/helper.conf`) finalized with correct agent socket, X.509-SVID output, JWT-SVID output (audience `vault`), and file permissions (0640)
3. cert-manager `Issuer` CR (self-signed CA) and `Certificate` CR (1-year bootstrap leaf with `digitalSignature` key usage) created in the demo overlay
4. The bootstrap leaf cert + key are stored in a Kubernetes Secret (`spire-bootstrap-cert`) for cloud-init injection by Story 6d
5. SPIRE Server passthrough Route created so the VM agent can reach the server's gRPC endpoint
6. x509pop server-side patching procedure documented: Secret with CA cert, StatefulSet volume mount, ConfigMap plugin addition, and create-only annotation
7. Image rebuild required after config file updates (documented in story)

## Tasks / Subtasks

- [ ] Task 1: Finalize `agent.conf` (AC: #1)
  - [ ] 1.1: Replace PLACEHOLDER values with correct trust_domain, server_address, server_port
  - [ ] 1.2: Set `insecure_bootstrap = true` (experiment — trust bundle not pre-provisioned to VM)
  - [ ] 1.3: Verify x509pop plugin paths match Quadlet bind-mount paths from Story 6a
  - [ ] 1.4: Add `data_dir` matching the agent container's writable directory
- [ ] Task 2: Finalize `helper.conf` (AC: #2)
  - [ ] 2.1: Set `agent_address` to the Workload API socket path
  - [ ] 2.2: Configure X.509-SVID output (cert, key, bundle) in `cert_dir`
  - [ ] 2.3: Configure JWT-SVID output with `jwt_audience = "vault"`
  - [ ] 2.4: Set all file modes to `0640`
  - [ ] 2.5: Enable `daemon_mode = true` for continuous renewal
- [ ] Task 3: Create cert-manager Issuer CR (AC: #3)
  - [ ] 3.1: Self-signed root `Issuer` in the demo namespace
  - [ ] 3.2: CA `Issuer` backed by a self-signed CA Certificate
- [ ] Task 4: Create cert-manager Certificate CR (AC: #3, #4)
  - [ ] 4.1: 1-year duration, `digitalSignature` + `keyEncipherment` key usages
  - [ ] 4.2: Unique common name for the VM
  - [ ] 4.3: Secret name `spire-bootstrap-cert` — stores `tls.crt`, `tls.key`, `ca.crt`
- [ ] Task 5: Create SPIRE Server passthrough Route (AC: #5)
  - [ ] 5.1: Route in `zero-trust-workload-identity-manager` namespace
  - [ ] 5.2: TLS termination: passthrough (gRPC mTLS between agent and server)
  - [ ] 5.3: Target: `spire-server` service, port `grpc`
- [ ] Task 6: Document x509pop server-side patching (AC: #6)
  - [ ] 6.1: Script/procedure to create Secret with CA cert, mount into StatefulSet, patch ConfigMap
  - [ ] 6.2: Create-only annotation on SpireServer CR
- [ ] Task 7: Document image rebuild requirement (AC: #7)

## Dev Notes

### ⚠️ CRITICAL: This Story Updates Placeholder Files from Story 6a

Story 6a created placeholder config files with `PLACEHOLDER_*` values. This story **replaces** those placeholder files with production configuration. After implementing this story, the bootc image **must be rebuilt and re-pushed** before the VM can work.

Files to **UPDATE** (not create):
- `clusters/etl7/overlays/spire-vault-demo/image/files/etc/spire/agent.conf`
- `clusters/etl7/overlays/spire-vault-demo/image/files/etc/spiffe-helper/helper.conf`

Files to **CREATE** (new K8s manifests in the overlay):
- `clusters/etl7/overlays/spire-vault-demo/cert-issuer.yaml`
- `clusters/etl7/overlays/spire-vault-demo/cert-bootstrap.yaml`
- `clusters/etl7/overlays/spire-vault-demo/spire-server-route.yaml`

**If Story 6a has NOT been implemented yet**, create the directory structure and files as specified in Story 6a's file tree before placing these configs. The files live at the exact paths from Story 6a's Containerfile `COPY` directives.

### ⚠️ CRITICAL: insecure_bootstrap for the Experiment

The SPIRE agent needs to verify the SPIRE server's identity when connecting. In production, this requires a `trust_bundle_path` containing the server's CA certificate. For this experiment, we use `insecure_bootstrap = true` because:

1. The trust bundle is only available at runtime (after the SPIRE server is deployed)
2. Fetching the trust bundle requires `oc exec` into the server pod (as shown in the [Sky Computing guide](https://developers.redhat.com/blog/2026/04/23/sky-computing-openshift-service-mesh-spire-multicloud-integration))
3. Injecting it into the VM adds another cloud-init dependency for marginal security benefit in an experiment
4. The agent still authenticates itself to the server via x509pop — the risk is only MITM on initial bootstrap

**Trade-off documented.** For production: fetch the trust bundle and inject via cloud-init alongside the bootstrap cert, or use `trust_bundle_url` with an HTTPS endpoint serving the bundle.

### ⚠️ CRITICAL: SPIRE Server Must Be Reachable from the VM

The VM's spire-agent connects to the SPIRE server via gRPC. The server must be exposed via a **passthrough** Route (gRPC uses mTLS internally, so TLS termination would break it). The Route hostname follows the pattern `spire-server.apps.${CLUSTER_BASE_DOMAIN}`.

This Route is NOT created by Story 1.2 (which only creates the OIDC discovery Route via `managedRoute: "true"`). **This story must create the Route.**

### ⚠️ CRITICAL: x509pop Server-Side Patching Is a Manual Procedure

The SpireServer CRD does **NOT** expose fields for configuring additional NodeAttestor plugins like x509pop (confirmed in Story 1.2 dev notes). Server-side x509pop requires:

1. **Create-only mode**: Add annotation `ztwim.openshift.io/create-only=true` to the `SpireServer` CR to prevent the ZTWIM operator from overwriting manual changes
2. **CA Secret**: Create a Secret containing the cert-manager CA certificate in the `zero-trust-workload-identity-manager` namespace
3. **Volume mount**: Patch the `spire-server` StatefulSet to mount the CA Secret
4. **ConfigMap patch**: Add the x509pop NodeAttestor plugin to the `spire-server` ConfigMap
5. **Restart**: Roll the StatefulSet to pick up changes

This procedure is documented in [Sky Computing Part 2](https://developers.redhat.com/blog/2026/04/23/sky-computing-openshift-service-mesh-spire-multicloud-integration). The script should be included as a documented manual step in the readme, NOT as a GitOps manifest (because the CA cert is dynamic — it's generated by cert-manager at deploy time).

**Timing**: Execute after Story 1.2 deploys the SPIRE server AND after cert-manager generates the CA cert from this story's Issuer/Certificate CRs.

### ⚠️ CRITICAL: Certificate Key Usage for x509pop

The x509pop agent plugin requires the bootstrap certificate to have `digitalSignature` in the X.509v3 KeyUsage extension ([SPIRE docs](https://github.com/spiffe/spire/blob/main/doc/plugin_agent_nodeattestor_x509pop.md)). The cert-manager Certificate CR must explicitly specify:

```yaml
usages:
  - digital signature
  - key encipherment
```

Without `digitalSignature`, the SPIRE server will reject the agent's attestation attempt.

### ⚠️ CRITICAL: Agent SPIFFE ID Format Determines Vault bound_subject

When x509pop attestation succeeds, the server assigns the agent a SPIFFE ID based on the certificate fingerprint:

```
spiffe://<trust-domain>/spire/agent/x509pop/<sha1-fingerprint>
```

The SHA1 fingerprint is computed from the bootstrap certificate's DER encoding. This value is **not known until the cert-manager Certificate is issued**. Story 1.5's `JWTOIDCAuthEngineRole` must set `bound_subject` to match this exact SPIFFE ID.

**Cross-story coordination required**: After the cert-manager Certificate is issued, extract the fingerprint:
```bash
oc get secret spire-bootstrap-cert -n spire-vault-demo -o jsonpath='{.data.tls\.crt}' | \
  base64 -d | openssl x509 -fingerprint -sha1 -noout | tr -d ':' | awk -F= '{print tolower($2)}'
```
Then update Story 1.5's `bound_subject` with the full SPIFFE ID.

### Exact agent.conf (Final Configuration)

Replace the placeholder at `clusters/etl7/overlays/spire-vault-demo/image/files/etc/spire/agent.conf`:

```hcl
agent {
    data_dir = "/opt/spire/data"
    log_level = "DEBUG"
    trust_domain = "etl7.ocp.rht-labs.com"
    server_address = "spire-server.apps.${CLUSTER_BASE_DOMAIN}"
    server_port = "443"
    socket_path = "/run/spire/sockets/agent.sock"
    insecure_bootstrap = true
}

plugins {
    NodeAttestor "x509pop" {
        plugin_data {
            private_key_path = "/etc/spire/bootstrap/agent.key.pem"
            certificate_path = "/etc/spire/bootstrap/agent.crt.pem"
        }
    }
    KeyManager "disk" {
        plugin_data {
            directory = "/opt/spire/data"
        }
    }
    WorkloadAttestor "unix" {
        plugin_data {}
    }
}
```

**Key decisions:**
- `server_address`: Uses the Route hostname (passthrough). The VM runs on OpenShift Virtualization but connects via the Route, not the internal service, because the VM's network namespace is separate from the pod network.
- `server_port = "443"`: Standard HTTPS port for OpenShift Routes.
- `socket_path = "/run/spire/sockets/agent.sock"`: Matches the Quadlet bind-mount from Story 6a's `spire-agent.container` (`Volume=/run/spire/sockets:/run/spire/sockets:z`).
- `data_dir = "/opt/spire/data"`: The spire-agent container image (`ghcr.io/spiffe/spire-agent:1.14.7`) has this directory writable. The KeyManager "disk" stores agent keys here.
- `private_key_path` / `certificate_path`: Match the paths set by cloud-init (Story 6d injects certs to `/etc/spire/bootstrap/`). The Quadlet mounts `/etc/spire/bootstrap/:ro` into the container.
- `insecure_bootstrap = true`: Experiment trade-off — avoids pre-provisioning the SPIRE trust bundle (see CRITICAL note above).
- `WorkloadAttestor "unix"`: Required for spiffe-helper to receive SVIDs. The helper connects to the agent's Workload API and is attested by its Unix UID.

**IMPORTANT**: `server_address` contains `${CLUSTER_BASE_DOMAIN}` which is an envsubst variable resolved by the ArgoCD CMP sidecar. However, this file is embedded in the bootc image, NOT rendered by ArgoCD. **Replace `${CLUSTER_BASE_DOMAIN}` with the literal cluster domain** (e.g., `etl7.ocp.rht-labs.com`) in the file. The envsubst mechanism does not apply to files inside container images.

### Exact helper.conf (Final Configuration)

Replace the placeholder at `clusters/etl7/overlays/spire-vault-demo/image/files/etc/spiffe-helper/helper.conf`:

```hcl
agent_address = "/run/spire/sockets/agent.sock"
daemon_mode = true

cert_dir = "/var/run/secrets/spiffe"
svid_file_name = "svid.crt.pem"
svid_key_file_name = "svid.key.pem"
svid_bundle_file_name = "bundle.crt.pem"

jwt_svids = [
  {
    jwt_audience      = "vault"
    jwt_svid_file_name = "jwt-svid.token"
  }
]

cert_file_mode = 0640
key_file_mode = 0640
jwt_svid_file_mode = 0640
```

**Key decisions:**
- `agent_address`: Matches the spire-agent socket path. The Quadlet mounts `/run/spire/sockets/:ro,z` into the spiffe-helper container.
- `daemon_mode = true`: Continuously fetches and renews SVIDs. Without this, spiffe-helper would fetch once and exit.
- `cert_dir = "/var/run/secrets/spiffe"`: The Quadlet mounts `/var/run/secrets/spiffe:/var/run/secrets/spiffe:z` for output.
- `jwt_audience = "vault"`: **Must match** the `bound_audiences` in Story 1.5's `JWTOIDCAuthEngineRole` (`["vault"]`). If these don't match, Vault will reject the JWT-SVID.
- File modes `0640`: Files owned by `spiffe-helper:spiffe-consumers` (UID 10002:GID 10003). `vault-agent-user` (UID 10004, supplementary GID 10003) can read via group permission.
- No `cmd` or `renew_signal`: Not needed — we're not running a child process from spiffe-helper. vault-agent reads the files independently.

**NOTE on spiffe-helper v0.11.0 file ownership**: spiffe-helper writes files as the process UID/GID. With `User=10002:10003` in the Quadlet, output files will be `10002:10003`. The `cert_file_mode`/`key_file_mode`/`jwt_svid_file_mode` control permissions on the written files. Verify during testing that vault-agent (UID 10004, supplementary GID 10003) can actually read these files.

### Exact cert-manager Issuer CR

Create `clusters/etl7/overlays/spire-vault-demo/cert-issuer.yaml`:

```yaml
# Self-signed root issuer — bootstraps the CA
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: spire-bootstrap-selfsigned
  namespace: spire-vault-demo
spec:
  selfSigned: {}
---
# CA Certificate — signed by the self-signed issuer above
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: spire-bootstrap-ca
  namespace: spire-vault-demo
spec:
  isCA: true
  duration: 87600h  # 10 years
  commonName: "SPIRE Bootstrap CA - etl7"
  secretName: spire-bootstrap-ca-keypair
  issuerRef:
    name: spire-bootstrap-selfsigned
    kind: Issuer
---
# CA Issuer — uses the CA cert to sign leaf certificates
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: spire-bootstrap-ca-issuer
  namespace: spire-vault-demo
spec:
  ca:
    secretName: spire-bootstrap-ca-keypair
```

**Why a two-tier CA instead of a single self-signed cert?**
- The SPIRE Server x509pop plugin needs a `ca_bundle_path` containing the **CA certificate** (not the leaf cert)
- With a proper CA, we can issue multiple VM bootstrap certs from the same CA without re-patching the SPIRE Server
- The CA cert in `spire-bootstrap-ca-keypair` Secret (`ca.crt` key) is what gets added to the SPIRE Server's x509pop trusted bundle
- A single self-signed leaf cert would require adding each individual cert to the server's trust bundle

### Exact cert-manager Certificate CR (Bootstrap Leaf)

Create `clusters/etl7/overlays/spire-vault-demo/cert-bootstrap.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: spire-bootstrap-cert
  namespace: spire-vault-demo
spec:
  secretName: spire-bootstrap-cert
  duration: 8760h  # 1 year
  renewBefore: 720h  # 30 days
  commonName: "spire-vault-demo-vm.etl7.ocp.rht-labs.com"
  usages:
    - digital signature
    - key encipherment
  issuerRef:
    name: spire-bootstrap-ca-issuer
    kind: Issuer
```

**Key decisions:**
- `duration: 8760h` (1 year): As specified in the epic. Long duration because x509pop attestation only happens at agent startup, not continuously.
- `usages: [digital signature, key encipherment]`: **Mandatory** — x509pop requires `digitalSignature` ([SPIRE docs](https://github.com/spiffe/spire/blob/main/doc/plugin_agent_nodeattestor_x509pop.md)). `key encipherment` is standard for TLS client certs.
- `commonName`: Unique per VM. Used in the SPIRE agent path template if `agent_path_template` uses `{{ .Subject.CommonName }}`.
- `secretName: spire-bootstrap-cert`: Story 6d's VirtualMachine CR references this Secret in cloud-init to inject `tls.crt` and `tls.key` as `/etc/spire/bootstrap/agent.crt.pem` and `/etc/spire/bootstrap/agent.key.pem`.

**Secret contents after cert-manager issues:**
| Key | Description | Used by |
|---|---|---|
| `tls.crt` | Leaf certificate (PEM) | cloud-init → `/etc/spire/bootstrap/agent.crt.pem` |
| `tls.key` | Private key (PEM) | cloud-init → `/etc/spire/bootstrap/agent.key.pem` |
| `ca.crt` | CA certificate (PEM) | x509pop server-side patching (CA bundle) |

### Exact SPIRE Server Route

Create `clusters/etl7/overlays/spire-vault-demo/spire-server-route.yaml`:

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: spire-server
  namespace: zero-trust-workload-identity-manager
spec:
  host: spire-server.apps.${CLUSTER_BASE_DOMAIN}
  port:
    targetPort: grpc
  tls:
    termination: passthrough
  to:
    kind: Service
    name: spire-server
    weight: 100
```

**Key decisions:**
- `termination: passthrough`: **Mandatory** — SPIRE agent ↔ server use gRPC with their own mTLS. TLS termination at the Route would break the connection.
- `host: spire-server.apps.${CLUSTER_BASE_DOMAIN}`: This IS an ArgoCD-rendered manifest (unlike the bootc image files), so `${CLUSTER_BASE_DOMAIN}` envsubst works here.
- `targetPort: grpc`: The SPIRE server service exposes a port named `grpc` (port 8081).
- `namespace: zero-trust-workload-identity-manager`: The Route lives in the ZTWIM namespace alongside the SPIRE server.

**NOTE**: This Route is separate from the OIDC Discovery Provider Route (created by Story 1.2's `managedRoute: "true"`). That Route serves OIDC metadata over HTTPS; this Route serves the SPIRE Server's gRPC API for agent attestation.

### x509pop Server-Side Patching Procedure

This procedure must be executed **manually** after:
1. Story 1.2 has deployed the SPIRE Server
2. This story's cert-manager resources have been deployed and the CA cert is available

Include this as a section in the overlay's `readme.md`:

```bash
#!/bin/bash
# x509pop server-side patching for SPIRE Server on etl7
# Run after: SPIRE Server deployed (Story 1.2) AND cert-manager certs issued (Story 6b)

ZTWIM_NS="zero-trust-workload-identity-manager"
DEMO_NS="spire-vault-demo"

# Step 1: Enable create-only mode on SpireServer CR
oc annotate spireserver cluster -n "${ZTWIM_NS}" \
  ztwim.openshift.io/create-only=true --overwrite

# Step 2: Extract CA cert from cert-manager and create Secret in ZTWIM namespace
CA_CRT=$(oc get secret spire-bootstrap-ca-keypair -n "${DEMO_NS}" \
  -o jsonpath='{.data.ca\.crt}' | base64 -d)

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: x509pop-ca
  namespace: ${ZTWIM_NS}
stringData:
  ca.crt.pem: |
$(echo "${CA_CRT}" | sed 's/^/    /')
EOF

# Step 3: Mount the CA Secret into the spire-server StatefulSet
oc patch statefulset spire-server -n "${ZTWIM_NS}" --type=strategic --patch '
spec:
  template:
    spec:
      volumes:
      - name: x509pop-ca
        secret:
          secretName: x509pop-ca
      containers:
      - name: spire-server
        volumeMounts:
        - name: x509pop-ca
          mountPath: /tmp/x509pop-ca
          readOnly: true
'

# Step 4: Add x509pop NodeAttestor plugin to spire-server ConfigMap
NEW_ATTESTOR='{"x509pop": {"plugin_data": {"ca_bundle_path": "/tmp/x509pop-ca/ca.crt.pem"}}}'

oc get configmap spire-server -n "${ZTWIM_NS}" -o json | \
jq --argjson new "${NEW_ATTESTOR}" \
   '.data["server.conf"] |= (fromjson |
    if (.plugins.NodeAttestor | any(has("x509pop")))
    then .
    else .plugins.NodeAttestor += [$new]
    end | tojson)' | \
oc apply -f -

# Step 5: Restart SPIRE Server to pick up changes
oc rollout restart statefulset spire-server -n "${ZTWIM_NS}"
oc rollout status statefulset/spire-server -n "${ZTWIM_NS}" --timeout=300s

echo "x509pop server-side patching complete"

# Step 6: Verify x509pop is configured
oc exec spire-server-0 -c spire-server -n "${ZTWIM_NS}" -- \
  cat /opt/spire/conf/server/server.conf | jq '.plugins.NodeAttestor'

# Step 7: Extract the bootstrap cert fingerprint for Story 1.5 bound_subject
FINGERPRINT=$(oc get secret spire-bootstrap-cert -n "${DEMO_NS}" \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  openssl x509 -fingerprint -sha1 -noout | tr -d ':' | awk -F= '{print tolower($2)}')
echo "Agent SPIFFE ID: spiffe://etl7.ocp.rht-labs.com/spire/agent/x509pop/${FINGERPRINT}"
echo "Use this as bound_subject in Story 1.5 JWTOIDCAuthEngineRole"
```

**Source**: Adapted from [Sky Computing Part 2](https://developers.redhat.com/blog/2026/04/23/sky-computing-openshift-service-mesh-spire-multicloud-integration) x509pop setup procedure.

### Namespace for cert-manager Resources

The cert-manager Issuer and Certificate CRs use `namespace: spire-vault-demo`. This namespace **does not exist yet** — Story 6d creates it as part of the VirtualMachine deployment. Options:

1. **Add a namespace manifest to this story** — create `spire-vault-demo` namespace in the overlay
2. **Rely on Story 6d to create it** — but then cert-manager resources can't be applied until Story 6d

**Recommendation**: Create a `namespace.yaml` in the overlay. The cert-manager resources need the namespace before the VM is deployed (the certs must exist for cloud-init to reference them). Add:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: spire-vault-demo
  labels:
    argocd.argoproj.io/managed-by: openshift-gitops
  annotations:
    argocd.argoproj.io/sync-options: Delete=false
```

Create this at `clusters/etl7/overlays/spire-vault-demo/namespace.yaml`.

### SPIRE Registration Entry (Story 6d Responsibility)

After the VM boots and the agent attests, a **registration entry** must exist on the SPIRE Server for the VM's workloads to receive SVIDs. This is **NOT** this story's responsibility — it's Story 6d. But document it here for continuity:

```bash
# Create workload registration entry (Story 6d executes this)
AGENT_SPIFFE_ID="spiffe://etl7.ocp.rht-labs.com/spire/agent/x509pop/<fingerprint>"
WORKLOAD_SPIFFE_ID="spiffe://etl7.ocp.rht-labs.com/spire-vault-demo/workload"

oc exec spire-server-0 -c spire-server -n zero-trust-workload-identity-manager -- \
  /spire-server entry create \
    -parentID "${AGENT_SPIFFE_ID}" \
    -spiffeID "${WORKLOAD_SPIFFE_ID}" \
    -selector "unix:uid:10002"
```

The `unix:uid:10002` selector matches spiffe-helper's UID (set by `User=10002:10003` in the Quadlet).

### spire-agent.container Quadlet Verification

From Story 6a, the `spire-agent.container` Quadlet:
```ini
Volume=/etc/spire/bootstrap:/etc/spire/bootstrap:ro,z
Volume=/run/spire/sockets:/run/spire/sockets:z
Volume=/etc/spire/agent.conf:/etc/spire/agent.conf:ro,z
Exec=/opt/spire/bin/spire-agent run -config /etc/spire/agent.conf
```

Our `agent.conf` paths are consistent:
- `private_key_path = "/etc/spire/bootstrap/agent.key.pem"` → inside the `:ro` bind-mount ✅
- `certificate_path = "/etc/spire/bootstrap/agent.crt.pem"` → inside the `:ro` bind-mount ✅
- `socket_path = "/run/spire/sockets/agent.sock"` → inside the writable bind-mount ✅

### spiffe-helper.container Quadlet Verification

From Story 6a, the `spiffe-helper.container` Quadlet:
```ini
Volume=/run/spire/sockets:/run/spire/sockets:ro,z
Volume=/var/run/secrets/spiffe:/var/run/secrets/spiffe:z
Volume=/etc/spiffe-helper/helper.conf:/etc/spiffe-helper/helper.conf:ro,z
Exec=/spiffe-helper -config /etc/spiffe-helper/helper.conf
```

Our `helper.conf` paths are consistent:
- `agent_address = "/run/spire/sockets/agent.sock"` → inside the `:ro` bind-mount ✅
- `cert_dir = "/var/run/secrets/spiffe"` → inside the writable bind-mount ✅

### Container Image References (from Story 6a, unchanged)

| Service | OCI Image | Binary Path |
|---|---|---|
| spire-agent | `ghcr.io/spiffe/spire-agent:1.14.7` | `/opt/spire/bin/spire-agent` |
| spiffe-helper | `ghcr.io/spiffe/spiffe-helper:0.11.0` | `/spiffe-helper` |

### Files Created/Modified by This Story

| File | Action | Notes |
|---|---|---|
| `clusters/etl7/overlays/spire-vault-demo/image/files/etc/spire/agent.conf` | UPDATE | Replace placeholder with final x509pop config |
| `clusters/etl7/overlays/spire-vault-demo/image/files/etc/spiffe-helper/helper.conf` | UPDATE | Replace placeholder with final JWT-SVID config |
| `clusters/etl7/overlays/spire-vault-demo/namespace.yaml` | NEW | Namespace for cert-manager resources |
| `clusters/etl7/overlays/spire-vault-demo/cert-issuer.yaml` | NEW | Self-signed CA Issuer (two-tier: root + CA) |
| `clusters/etl7/overlays/spire-vault-demo/cert-bootstrap.yaml` | NEW | 1-year leaf Certificate for VM bootstrap |
| `clusters/etl7/overlays/spire-vault-demo/spire-server-route.yaml` | NEW | Passthrough Route for SPIRE Server gRPC |

### What NOT to Do

- **Do NOT use `trust_bundle_path`** in agent.conf — the trust bundle isn't available at image build time. Use `insecure_bootstrap = true` for this experiment.
- **Do NOT use `${CLUSTER_BASE_DOMAIN}` envsubst in agent.conf or helper.conf** — these files are baked into the bootc image, not rendered by ArgoCD. Use literal values.
- **Do NOT attempt to configure x509pop via the SpireServer CRD** — the CRD does not support it. Use the manual patching procedure documented above.
- **Do NOT modify files under `components/`** — all new manifests go in `clusters/etl7/overlays/spire-vault-demo/`
- **Do NOT modify `clusters/etl4/` or any other cluster** — etl7 experiment only
- **Do NOT add ArgoCD Application entries to `clusters/etl7/values.yaml`** — Story 6d handles the single `spire-vault-demo` application entry for the entire overlay
- **Do NOT create the VirtualMachine CR, cloud-init, or SPIRE registration entry** — those are Story 6d
- **Do NOT modify vault-agent config (`agent.hcl`)** — that's Story 6c
- **Do NOT skip the SPIRE Server Route** — without it, the VM agent cannot reach the server's gRPC API
- **Do NOT use a Cluster-scoped `ClusterIssuer`** — use namespace-scoped `Issuer` in `spire-vault-demo` for isolation
- **Do NOT use `cert_file_mode = 0444`** — the epic specifies `0640` for SVID files, restricting read access to the `spiffe-consumers` group only

### Cross-Story Dependencies and Impact

| Story | Relationship | Impact on This Story |
|---|---|---|
| **Story 1.2** (ZTWIM Instance) | Prerequisite — SPIRE Server must be running | x509pop patching happens on the running SPIRE Server; the Route targets the SPIRE Server service |
| **Story 1.5** (SPIRE↔Vault Trust) | Consumer — needs the cert fingerprint | The `bound_subject` in the Vault JWT role must match the agent's SPIFFE ID (derived from the bootstrap cert fingerprint). Extract fingerprint after cert issuance and pass to Story 1.5 |
| **Story 1.6a** (Bootc Image) | Prerequisite — directory structure and placeholders | This story updates placeholder files. If 6a isn't done, create the directory tree first |
| **Story 1.6c** (Vault Agent + httpd) | Parallel — independent configs | 6c finalizes `agent.hcl`; no interaction with this story |
| **Story 1.6d** (Deploy VM) | Consumer — uses cert Secret and configs | 6d references `spire-bootstrap-cert` Secret in cloud-init and creates the ArgoCD Application entry |

### Previous Story Intelligence (from Story 6a)

- **Quadlet container patterns**: spire-agent runs as UID 10001:10001, spiffe-helper as UID 10002:GID 10003. Volume mounts use `:z` for SELinux shared access and `:ro` for read-only restrictions.
- **Directory structure**: `/etc/spire/bootstrap/` is mode 0500 owned by spire:spire. Cloud-init must set correct ownership when writing certs.
- **Config file paths**: Quadlet files mount host configs as single-file bind mounts (e.g., `Volume=/etc/spire/agent.conf:/etc/spire/agent.conf:ro,z`).
- **Image rebuild**: Any config change requires rebuilding and re-pushing the bootc image. Document the rebuild command in the readme update.

### Project Structure Notes

- All new K8s manifests live under `clusters/etl7/overlays/spire-vault-demo/` — the same overlay that Story 6a created for the image build context
- The config files are at exact paths matching the Containerfile `COPY` directives from Story 6a
- The SPIRE Server Route is in the ZTWIM namespace (not spire-vault-demo) because it targets the SPIRE Server service
- The cert-manager resources are namespace-scoped to `spire-vault-demo`

### References

- [SPIRE agent x509pop plugin](https://github.com/spiffe/spire/blob/main/doc/plugin_agent_nodeattestor_x509pop.md) — agent-side config, `digitalSignature` requirement
- [SPIRE server x509pop plugin](https://github.com/spiffe/spire/blob/main/doc/plugin_server_nodeattestor_x509pop.md) — server-side config, `ca_bundle_path`, agent path template
- [SPIRE Agent Configuration Reference](https://spiffe.io/docs/latest/deploying/spire_agent/) — all agent.conf fields, bootstrap options
- [spiffe-helper configuration (v0.11.0)](https://pkg.go.dev/github.com/spiffe/spiffe-helper/cmd/spiffe-helper/config) — HCL config format, `jwt_svids`, file modes
- [Sky Computing Part 2 — x509pop on ZTWIM](https://developers.redhat.com/blog/2026/04/23/sky-computing-openshift-service-mesh-spire-multicloud-integration) — x509pop server-side patching procedure, Route creation, agent config
- [Yulia Paterson — SPIRE X.509 Node Attestation](https://medium.com/@yulia.paterson/spire-x-509-node-attestation-033bd157ce0d) — step-by-step x509pop walkthrough, registration entry creation
- [cert-manager Certificate resource](https://cert-manager.io/docs/usage/certificate/) — Certificate CR fields, key usages, secret output
- [KubeVirt cloud-init](https://github.com/kubevirt/kubevirt/blob/main/docs/cloud-init.md) — cloud-init Secret injection into VMs
- [Source: epic-zero-trust-secret-delivery-etl7.md — Story 1.6b]
- [Pattern reference: Story 1.6a — bootc image] — Quadlet files, directory structure, config paths

## Dev Agent Record

### Agent Model Used



### Debug Log References

### Completion Notes List

### File List
