# RHEL 10 Image-Mode Bootc Image — Zero-Trust SPIFFE/Vault Demo VM

Custom RHEL 10 bootc image containing all components for the zero-trust secret delivery demo. Deploys as a VM on OpenShift Virtualization with four Quadlet-managed containers providing the full SPIFFE-to-Vault secret delivery chain.

## Prerequisites

### Build host

- `podman` installed
- Red Hat registry access — run `podman login registry.redhat.io` before building
- RHEL entitlement or subscription — the base image (`registry.redhat.io/rhel10/rhel-bootc:10`) requires an entitled host or subscription-manager credentials for `dnf install` during the build
- SELinux-aware build environment — the Containerfile runs `semanage fcontext` which requires the SELinux policy store. Build with `podman build` on a host that has SELinux enabled (enforcing or permissive). If building on a non-SELinux host, pass `--security-opt label=disable`.

### Image registries

- `registry.redhat.io` — authenticated pull for the base image
- `registry.access.redhat.com` — unauthenticated pull for UBI httpd image
- `ghcr.io`, `docker.io` — unauthenticated pulls (Docker Hub rate limits may apply to `hashicorp/vault`)
- quay.io credentials with push access to the target repository

## Build and Push

The image build is executed by the operator on an entitled host (AC #8).

```bash
cd clusters/etl7/overlays/spire-vault-demo/image

# Authenticate to the Red Hat registry
podman login registry.redhat.io

# Build the image
podman build -t quay.io/<org>/rhel10-spire-vault-demo:latest -f Containerfile .

# Push to quay.io
podman push quay.io/<org>/rhel10-spire-vault-demo:latest
```

Replace `<org>` with the actual quay.io organization.

## Image Reference

`quay.io/<org>/rhel10-spire-vault-demo:latest`

## Service Architecture

The image runs four Quadlet containers as systemd-managed Podman containers, chained by dependency ordering:

| Service | Image | Role | Depends On |
|---|---|---|---|
| **spire-agent** | `ghcr.io/spiffe/spire-agent:1.14.7` | Obtains SPIFFE identity via x509pop attestation | network-online.target |
| **spiffe-helper** | `ghcr.io/spiffe/spiffe-helper:0.11.0` | Extracts SVIDs and JWT tokens from SPIRE agent | spire-agent |
| **vault-agent** | `docker.io/hashicorp/vault:1.20.4` | Authenticates to Vault with JWT-SVID, templates secrets | spiffe-helper |
| **httpd** | `registry.access.redhat.com/ubi10/httpd-24:latest` | Serves templated secrets on port 8080 | vault-agent |

Startup order: `spire-agent → spiffe-helper → vault-agent → httpd`

All four services have `Restart=on-failure`. spire-agent and spiffe-helper share the host PID namespace (`PidHost=true`) for SPIRE unix workload attestation.

### UID/GID Mapping

| User | UID | Primary GID | Supplementary Groups |
|---|---|---|---|
| spire | 10001 | 10001 (spire) | — |
| spiffe-helper | 10002 | 10003 (spiffe-consumers) via Quadlet `User=10002:10003` | — |
| vault-agent-user | 10004 | (private) | 10003 (spiffe-consumers) via Quadlet `GroupAdd=10003` |

The `spiffe-consumers` group (GID 10003) enables vault-agent to read SVID files written by spiffe-helper (mode 0640).

### Runtime directories (tmpfs)

`/run` is tmpfs — directories under it are lost on reboot. A `tmpfiles.d` rule (`/etc/tmpfiles.d/spire-vault-demo.conf`) recreates them at boot with correct ownership:

| Path | Mode | Owner | Purpose |
|---|---|---|---|
| `/run/spire/sockets` | 0755 | 10001:10001 | SPIRE agent socket |
| `/run/secrets/spiffe` | 0750 | 10002:10003 | SVID and JWT output |
| `/run/vault` | 0750 | 10004:10004 | Vault agent token sink |

### Vault TLS trust

The vault-agent placeholder config connects to Vault over HTTPS. For this experiment, the recommended approach is `tls_skip_verify = true` in `agent.hcl` (Story 1.6c finalizes this). For production, inject the OpenShift router CA bundle via a Quadlet volume mount and set `ca_cert` in the Vault agent config.

## Configuration

The following config files are embedded in the image:

| File | Status |
|---|---|
| `/etc/spire/agent.conf` | ✅ Finalized (Story 1.6b) |
| `/etc/spiffe-helper/helper.conf` | ✅ Finalized (Story 1.6b) |
| `/etc/vault-agent/agent.hcl` | Placeholder — Story 1.6c finalizes |

After updating configuration files, rebuild and push the image.

### SPIRE Agent Configuration (`agent.conf`)

- **trust_domain**: `etl7.ocp.rht-labs.com`
- **server_address**: `spire-server.apps.etl7.ocp.rht-labs.com` (literal — not envsubst; baked into the bootc image)
- **server_port**: `443` (OpenShift Route)
- **insecure_bootstrap**: `true` — experiment trade-off to avoid pre-provisioning the SPIRE trust bundle. For production, fetch the trust bundle and inject via cloud-init.
- **NodeAttestor**: `x509pop` — uses bootstrap cert/key from `/etc/spire/bootstrap/` (injected by cloud-init in Story 6d)
- **WorkloadAttestor**: `unix` — attests spiffe-helper by UID

### SPIFFE Helper Configuration (`helper.conf`)

- **daemon_mode**: `true` — continuously fetches and renews SVIDs
- **cert_dir**: `/var/run/secrets/spiffe` — SVID output directory
- **jwt_audience**: `vault` — must match `bound_audiences` in Story 1.5's Vault JWT role
- **File modes**: `0640` — owner (spiffe-helper, UID 10002) + group (spiffe-consumers, GID 10003) read access

## Kubernetes Manifests (Story 1.6b)

The following manifests are deployed by ArgoCD (Story 6d creates the ArgoCD Application entry):

| File | Kind | Namespace | Purpose |
|---|---|---|---|
| `namespace.yaml` | Namespace | — | Creates `spire-vault-demo` namespace |
| `cert-issuer.yaml` | Issuer, Certificate, Issuer | spire-vault-demo | Two-tier CA: self-signed root → CA cert → CA issuer |
| `cert-bootstrap.yaml` | Certificate | spire-vault-demo | 1-year leaf cert for x509pop attestation (`spire-bootstrap-cert` Secret) |
| `spire-server-route.yaml` | Route | zero-trust-workload-identity-manager | Passthrough Route exposing SPIRE Server gRPC for VM agent |

### cert-manager Certificate Chain

```
spire-bootstrap-selfsigned (self-signed Issuer)
  └── spire-bootstrap-ca (CA Certificate, 10-year, Secret: spire-bootstrap-ca-keypair)
        └── spire-bootstrap-ca-issuer (CA Issuer)
              └── spire-bootstrap-cert (Leaf Certificate, 1-year, Secret: spire-bootstrap-cert)
```

The leaf cert Secret (`spire-bootstrap-cert`) provides:
- `tls.crt` → cloud-init injects as `/etc/spire/bootstrap/agent.crt.pem`
- `tls.key` → cloud-init injects as `/etc/spire/bootstrap/agent.key.pem`
- `ca.crt` → used for x509pop server-side patching

### SPIRE Server Route

The passthrough Route exposes the SPIRE Server's gRPC API at `spire-server.apps.${CLUSTER_BASE_DOMAIN}`. This is separate from the OIDC Discovery Provider Route created by Story 1.2. TLS termination is `passthrough` because SPIRE agent ↔ server use their own mTLS. The Route has `haproxy.router.openshift.io/timeout: 3600s` to prevent the router from dropping long-lived gRPC streams at the default 30s idle timeout.

> **⚠️ Kustomize namespace trap:** This Route lives in `zero-trust-workload-identity-manager`, not `spire-vault-demo`. If the overlay `kustomization.yaml` sets a global `namespace: spire-vault-demo`, this Route **must** be excluded from namespace transformation (e.g., via `configurations:` or by moving it to the `ztwim-instance` overlay).

## x509pop Server-Side Patching (Manual Procedure)

The SpireServer CRD does **not** support configuring additional NodeAttestor plugins like x509pop. Server-side configuration requires manual patching after:

1. Story 1.2 has deployed the SPIRE Server
2. This story's cert-manager resources have been deployed and the CA cert is available

```bash
#!/bin/bash
set -euo pipefail
# x509pop server-side patching for SPIRE Server on etl7
# Run after: SPIRE Server deployed (Story 1.2) AND cert-manager certs issued (Story 6b)

ZTWIM_NS="zero-trust-workload-identity-manager"
DEMO_NS="spire-vault-demo"

# Step 1: Enable create-only mode on SpireServer CR
# WARNING: create-only freezes ALL SpireServer-managed resources (ConfigMap,
# StatefulSet, etc.), not just the x509pop-related ones. While this annotation
# is active, ZTWIM operator upgrades will NOT reconcile server-side changes.
# Remove the annotation when manual patching is no longer needed.
oc annotate spireserver cluster -n "${ZTWIM_NS}" \
  ztwim.openshift.io/create-only=true --overwrite

# Step 2: Extract CA cert from cert-manager and create Secret in ZTWIM namespace
# Prefer ca.crt from the CA keypair secret (cert-manager populates this key)
CA_CRT=$(oc get secret spire-bootstrap-ca-keypair -n "${DEMO_NS}" \
  -o jsonpath='{.data.ca\.crt}' | base64 -d)
if [[ -z "${CA_CRT}" ]]; then
  echo "ERROR: ca.crt is empty in spire-bootstrap-ca-keypair — is the Certificate issued?" >&2
  exit 1
fi

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

# Step 5: Restart SPIRE Server and wait for readiness
oc rollout restart statefulset spire-server -n "${ZTWIM_NS}"
oc rollout status statefulset/spire-server -n "${ZTWIM_NS}" --timeout=300s
oc wait --for=condition=Ready pod/spire-server-0 -n "${ZTWIM_NS}" --timeout=120s

echo "x509pop server-side patching complete"

# Step 6: Verify x509pop is configured
oc exec spire-server-0 -c spire-server -n "${ZTWIM_NS}" -- \
  cat /opt/spire/conf/server/server.conf | jq '.plugins.NodeAttestor'

# Step 7: Extract the bootstrap cert fingerprint (needed as parentID for workload registration)
FINGERPRINT=$(oc get secret spire-bootstrap-cert -n "${DEMO_NS}" \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  openssl x509 -fingerprint -sha1 -noout | tr -d ':' | awk -F= '{print tolower($2)}')
if [[ -z "${FINGERPRINT}" ]]; then
  echo "ERROR: Failed to extract fingerprint — is the bootstrap cert issued?" >&2
  exit 1
fi
echo "Agent SPIFFE ID (parentID): spiffe://etl7.ocp.rht-labs.com/spire/agent/x509pop/${FINGERPRINT}"
echo "NOTE: Vault bound_subject must be the WORKLOAD SPIFFE ID (from the registration entry), NOT the agent ID."
echo "See Story 1.5 and Story 6d for the workload registration entry that sets -spiffeID."
```

**Source**: Adapted from [Sky Computing Part 2](https://developers.redhat.com/blog/2026/04/23/sky-computing-openshift-service-mesh-spire-multicloud-integration).

### Cross-Story Fingerprint Coordination

After the cert-manager Certificate is issued, the bootstrap cert's SHA1 fingerprint determines the **agent's** SPIFFE ID:

```
spiffe://etl7.ocp.rht-labs.com/spire/agent/x509pop/<sha1-fingerprint>
```

Extract the fingerprint:
```bash
oc get secret spire-bootstrap-cert -n spire-vault-demo -o jsonpath='{.data.tls\.crt}' | \
  base64 -d | openssl x509 -fingerprint -sha1 -noout | tr -d ':' | awk -F= '{print tolower($2)}'
```

> **⚠️ This is the agent SPIFFE ID (used as `parentID` in the workload registration entry), NOT the Vault `bound_subject`.** The Vault JWT `sub` claim contains the **workload** SPIFFE ID from the registration entry's `-spiffeID` parameter, not the agent's identity. See Story 1.5 for the correct `bound_subject` value.

> **⚠️ Leaf renewal changes the fingerprint.** cert-manager renews the bootstrap cert 30 days before expiry (`renewBefore: 720h`). A renewed cert has a new SHA1 fingerprint, which changes the agent's SPIFFE ID and breaks x509pop attestation until the operator:
> 1. Re-extracts the new fingerprint from the renewed `spire-bootstrap-cert` Secret
> 2. Re-injects it into the VM via cloud-init (reboot or re-provision)
> 3. Updates the x509pop CA bundle in the SPIRE server if the CA was also rotated
>
> For this experiment the 1-year leaf duration is sufficient; production deployments should automate this rotation.

## Image Rebuild Required

After Story 1.6b finalized `agent.conf` and `helper.conf`, the bootc image **must be rebuilt and re-pushed** before the VM can work:

```bash
cd clusters/etl7/overlays/spire-vault-demo/image
podman build -t quay.io/<org>/rhel10-spire-vault-demo:latest -f Containerfile .
podman push quay.io/<org>/rhel10-spire-vault-demo:latest
```

## File Layout

```
clusters/etl7/overlays/spire-vault-demo/
├── cert-bootstrap.yaml          # Story 6b — leaf Certificate for x509pop
├── cert-issuer.yaml             # Story 6b — self-signed CA chain (Issuer + CA Cert + CA Issuer)
├── namespace.yaml               # Story 6b — spire-vault-demo namespace
├── spire-server-route.yaml      # Story 6b — passthrough Route for SPIRE Server gRPC
├── image/
│   ├── Containerfile
│   └── files/
│       └── etc/
│           ├── containers/
│           │   └── systemd/
│           │       ├── spire-agent.container
│           │       ├── spiffe-helper.container
│           │       ├── vault-agent.container
│           │       └── httpd.container
│           ├── spire/
│           │   └── agent.conf             # Finalized by Story 6b
│           ├── spiffe-helper/
│           │   └── helper.conf            # Finalized by Story 6b
│           ├── tmpfiles.d/
│           │   └── spire-vault-demo.conf
│           └── vault-agent/
│               └── agent.hcl
└── readme.md
```

## Related Stories

- **Story 1.6b** — Finalizes SPIRE agent and spiffe-helper configuration
- **Story 1.6c** — Finalizes Vault agent configuration
- **Story 1.6d** — Deploys the VM on OpenShift Virtualization using this image
