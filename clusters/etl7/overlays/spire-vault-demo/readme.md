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

- **Bootc OCI image:** `quay.io/<org>/rhel10-spire-vault-demo:latest`
- **containerDisk QCOW2 image:** `quay.io/<org>/rhel10-spire-vault-demo-disk:latest`

## QCOW2 Conversion and containerDisk Packaging

A bootc OCI image contains a filesystem tree, NOT a disk image. KubeVirt requires a QCOW2 or RAW disk image at `/disk/` inside the container image. The conversion pipeline is:

### Step 1: Convert bootc image to QCOW2

Use `bootc-image-builder` (requires privileged execution on an entitled RHEL host):

```bash
# Copy the bootc image from rootless (user) storage to root storage —
# bootc-image-builder runs as root and cannot see rootless images
podman save quay.io/<org>/rhel10-spire-vault-demo:latest | sudo podman load

# Create the output directory (bootc-image-builder bind-mounts it)
mkdir -p output

sudo podman run --rm -it --privileged \
  --pull=newer \
  --security-opt label=type:unconfined_t \
  -v $(pwd)/output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  registry.redhat.io/rhel10/bootc-image-builder:latest \
  --type qcow2 \
  quay.io/<org>/rhel10-spire-vault-demo:latest
```

The output QCOW2 is written to `output/qcow2/disk.qcow2`.

### Step 2: Package QCOW2 as containerDisk OCI image

Create `Containerfile.disk`:

```dockerfile
FROM scratch
ADD --chown=107:107 output/qcow2/disk.qcow2 /disk/
```

UID 107 and mode 0440 are required by KubeVirt's containerDisk convention (the `qemu` user inside the virt-launcher pod needs read access).

### Step 3: Build and push the containerDisk image

```bash
podman build -t quay.io/<org>/rhel10-spire-vault-demo-disk:latest -f Containerfile.disk .
podman push quay.io/<org>/rhel10-spire-vault-demo-disk:latest
```

The `VirtualMachine` CR's `dataVolumeTemplates.source.registry.url` references this containerDisk image. CDI (Containerized Data Importer) automatically pulls it, extracts the QCOW2, converts to raw, and creates the PVC.

**Reference:** [Build and deploy image mode for RHEL on OpenShift Virtualization](https://developers.redhat.com/articles/2024/11/11/deploy-image-mode-rhel-openshift-virtualization)

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
| `/etc/spiffe-helper/helper.conf` | ✅ Finalized (Story 1.6b) — extracts X.509 SVIDs, JWT-SVIDs, and JWT Bundle |
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
- **Extracts all supported identity types:**
  - **X.509 SVID**: certificate (`svid.crt.pem`), private key (`svid.key.pem`), trust bundle (`bundle.crt.pem`)
  - **JWT-SVID**: token for audience `vault` (`jwt-svid.token`) — must match `bound_audiences` in Story 1.5's Vault JWT role
  - **JWT Bundle**: JWKS verification keys (`jwt_bundle.json`) — enables local JWT-SVID validation without contacting SPIRE Server
- **File modes**: `0640` — owner (spiffe-helper, UID 10002) + group (spiffe-consumers, GID 10003) read access
- **Note**: SPIFFE also defines WIT-SVIDs (Workload Identity Tokens) but spiffe-helper does not support them

## Kubernetes Manifests (Story 1.6b)

The following manifests are deployed by ArgoCD (Story 6d creates the ArgoCD Application entry):

| File | Kind | Namespace | Purpose |
|---|---|---|---|
| `namespace.yaml` | Namespace | — | Creates `spire-vault-demo` namespace |
| `cert-bootstrap.yaml` | Certificate | spire-vault-demo | 1-year leaf cert for x509pop attestation (`spire-bootstrap-cert` Secret) |

The root CA infrastructure and x509pop automation are deployed by the `ztwim-instance` component/overlay:

| File | Kind | Scope | Purpose |
|---|---|---|---|
| `components/ztwim-instance/spire-cert-manager-ca.yaml` | ClusterIssuer × 2, Certificate | Cluster + ztwim ns | Self-signed bootstrap, root CA cert (Reflector-mirrored), CA ClusterIssuer |
| `clusters/etl7/overlays/ztwim-instance/x509pop-setup-job.yaml` | Job, SA, RBAC | ztwim ns | Patches SPIRE Server for x509pop NodeAttestor |

### cert-manager Certificate Chain

A single root CA serves SPIRE Server's UpstreamAuthority (intermediate signing CA), the x509pop CA bundle, and the VM's bootstrap cert. ClusterIssuers allow cross-namespace cert issuance:

```
selfsigned-bootstrap (ClusterIssuer, self-signed)
  └── spire-root-ca (Certificate, 10-year, ns: ztwim, Secret: spire-root-ca-secret)
        │   Reflector mirrors Secret → cert-manager ns (for ClusterIssuer)
        │   Original Secret stays in ztwim ns (for SPIRE Server direct mount)
        └── spire-root-ca-issuer (ClusterIssuer, reads mirrored secret from cert-manager ns)
              ├── SpireServer upstreamAuthority.certManager (intermediate signing cert — declarative)
              └── spire-bootstrap-cert (Leaf Certificate, 1-year, ns: spire-vault-demo, Secret: spire-bootstrap-cert)
```

The leaf cert Secret (`spire-bootstrap-cert`) provides:
- `tls.crt` → cloud-init injects as `/etc/spire/bootstrap/agent.crt.pem`
- `tls.key` → cloud-init injects as `/etc/spire/bootstrap/agent.key.pem`
- `ca.crt` → available for x509pop verification

The SPIRE Server's UpstreamAuthority is configured declaratively via the `SpireServer` CR's `spec.upstreamAuthority.certManager` field (patched in the etl7 ztwim-instance overlay). ZTWIM reconciles the SPIRE Server StatefulSet automatically — no manual intermediate cert provisioning is needed.

The `create-only=true` annotation is applied declaratively on the SpireServer CR (via overlay patch) so the ZTWIM operator does not revert the x509pop patches made by the Job.

### SPIRE Server Route

The passthrough Route exposes the SPIRE Server's gRPC API at `spire-server.apps.${CLUSTER_BASE_DOMAIN}`. This is separate from the OIDC Discovery Provider Route created by Story 1.2. TLS termination is `passthrough` because SPIRE agent ↔ server use their own mTLS. The Route has `haproxy.router.openshift.io/timeout: 3600s` to prevent the router from dropping long-lived gRPC streams at the default 30s idle timeout.

> **⚠️ Kustomize namespace trap:** This Route lives in `zero-trust-workload-identity-manager`, not `spire-vault-demo`. If the overlay `kustomization.yaml` sets a global `namespace: spire-vault-demo`, this Route **must** be excluded from namespace transformation (e.g., via `configurations:` or by moving it to the `ztwim-instance` overlay).

## x509pop Server-Side Patching (Automated via Job)

The SpireServer CRD does **not** support configuring additional NodeAttestor plugins like x509pop. The `x509pop-setup` Job (`clusters/etl7/overlays/ztwim-instance/x509pop-setup-job.yaml`) automates this patching as an ArgoCD PostSync hook at sync-wave 10 within the `ztwim-instance` Application.

The Job performs four steps:
1. **Mount** `spire-root-ca-secret` into the SPIRE Server StatefulSet (projects `tls.crt` as `ca.crt.pem`) — the Secret is in the same namespace, no cross-namespace copying needed
2. **Patch** the SPIRE Server ConfigMap to add the x509pop NodeAttestor plugin (idempotent — skips if already present)
3. **Restart** the SPIRE Server StatefulSet and wait for readiness
4. **Verify** x509pop configuration

### Prerequisites (handled by sync-wave ordering)

| Resource | Created by | Available at |
|---|---|---|
| `reflector-operator` | etl7 values.yaml (wave 5) | Before ztwim-instance (wave 15) |
| `CREATE_ONLY_MODE=true` | ztwim-operator overlay (wave 5) | Before ztwim-instance (wave 15) |
| SpireServer StatefulSet | ZTWIM operator (after SpireServer CR) | Wave 0 within ztwim-instance |
| `spire-root-ca-secret` | cert-manager (root CA Certificate in component) | Wave 0 within ztwim-instance |

> **Note:** `CREATE_ONLY_MODE=true` is set on the operator Subscription via the `ztwim-operator` overlay (see OCP 4.22 ZTWIM docs §12.12). This prevents the operator from reconciling (overwriting) the Job's patches. The Job uses `argocd.argoproj.io/hook: PostSync` and `hook-delete-policy: BeforeHookCreation` to re-run on each sync.

The bootstrap cert (`spire-bootstrap-cert`) is issued directly in the `spire-vault-demo` namespace by the ClusterIssuer — no cross-namespace copying is needed.

The SPIRE registration entry (see below) still requires manual execution since it depends on the VM being booted and attested.

**Source**: Adapted from [Sky Computing Part 2](https://developers.redhat.com/blog/2026/04/23/sky-computing-openshift-service-mesh-spire-multicloud-integration).

### Cross-Story Fingerprint Coordination

After the cert-manager Certificate is issued, the bootstrap cert's SHA1 fingerprint determines the **agent's** SPIFFE ID:

```
spiffe://etl7.ocp.rht-labs.com/spire/agent/x509pop/<sha1-fingerprint>
```

Extract the fingerprint (from the bootstrap leaf cert, NOT the root CA):
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

## SPIRE Registration Entries (Automated)

Workload registration entries are created automatically by the `spire-registration` Job, which runs as an ArgoCD **PostSync** hook within the `spire-vault-demo` Application.

The SPIRE Controller Manager's `ClusterSPIFFEID` CRD only targets **pods** — the VM's agent uses x509pop attestation, so entries must be created via the `spire-server entry create` CLI. The Job automates this by:

1. Reading the `spire-bootstrap-cert` Secret and extracting the SHA1 fingerprint
2. Computing the agent's `parentID`: `spiffe://etl7.ocp.rht-labs.com/spire/agent/x509pop/<fingerprint>`
3. Creating the workload registration entry (idempotent — skips if it already exists)
4. Listing all entries for verification

The entry is **pre-created before the VM boots** — SPIRE Server stores it and matches it once the agent attests.

**Registration entry details:**
- **parentID**: `spiffe://etl7.ocp.rht-labs.com/spire/agent/x509pop/<sha1-fingerprint>` (from bootstrap cert)
- **spiffeID**: `spiffe://etl7.ocp.rht-labs.com/spire-vault-demo/workload`
- **selector**: `unix:uid:10002` (matches spiffe-helper UID inside the VM)
- **jwt-svid-ttl**: `3600` (1-hour JWT-SVID TTL matching the Vault role's `token_ttl` from Story 1.5)

**Notes:**
- The workload SPIFFE ID must match the `bound_subject` in the Vault JWT role (Story 1.5)
- The Job checks for existing entries before creating, so ArgoCD re-syncs are safe
- Check Job status: `oc get job spire-registration -n spire-vault-demo`
- View Job logs: `oc logs job/spire-registration -n spire-vault-demo`

## End-to-End Verification

After deployment, verify the complete zero-trust secret delivery chain:

```bash
# 1. Verify VM is running
oc get vm spire-vault-demo-vm -n spire-vault-demo

# 2. SSH into the VM
virtctl ssh cloud-user@spire-vault-demo-vm -n spire-vault-demo
# Or serial console fallback:
virtctl console spire-vault-demo-vm -n spire-vault-demo

# 3. Inside the VM — check bootstrap cert was injected
ls -la /etc/spire/bootstrap/

# 4. Check spire-agent is running and attested
sudo podman logs spire-agent
# Look for: "Successfully attested" and "Node attestation was successful"

# 5. Check spiffe-helper is extracting SVIDs
ls -la /var/run/secrets/spiffe/
# Should contain: svid.crt.pem, svid.key.pem, bundle.crt.pem, jwt-svid.token, jwt_bundle.json
cat /var/run/secrets/spiffe/jwt-svid.token | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool
# Verify the 'sub' field matches the registration entry's SPIFFE ID

# 6. Check vault-agent authenticated and wrote the secret
cat /var/www/html/secret.txt
# Should contain: "Hello from Vault via SPIFFE zero-trust!"
sudo podman logs vault-agent
# Look for: "successfully authenticated" and "rendered"

# 7. Check httpd is serving the secret
curl http://localhost:8080/secret.txt
# Should return: "Hello from Vault via SPIFFE zero-trust!"

# 8. From outside the VM — verify via Route
curl https://spire-vault-demo.apps.etl7.ocp.rht-labs.com/secret.txt
# Should return: "Hello from Vault via SPIFFE zero-trust!"
```

## SSH Access

Access the VM for debugging and verification:

```bash
# Primary: SSH via virtctl (requires raffa-key Secret in spire-vault-demo namespace)
virtctl ssh cloud-user@spire-vault-demo-vm -n spire-vault-demo

# Fallback: Serial console (no SSH key needed, use cloud-user / spire-vault-demo)
virtctl console spire-vault-demo-vm -n spire-vault-demo
```

> **Note:** The `raffa-key` Secret must exist in the `spire-vault-demo` namespace. This is the same SSH key pattern used by other VMs in this repo (e.g., `fedora-vm1` in `clusters/etl6/`). If it doesn't exist, create it from the existing secret in another namespace or from the SSH public key.

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
├── kustomization.yaml           # Story 6d — Kustomize overlay root
├── namespace.yaml               # Story 6b — spire-vault-demo namespace
├── route.yaml                   # Story 6d — Route for httpd external access
├── service.yaml                 # Story 6d — Service targeting VM httpd (port 8080)
├── spire-registration-job.yaml  # Job + RBAC: creates SPIRE workload registration entry
├── virtual-machine.yaml         # Story 6d — VirtualMachine CR with DataVolume + cloud-init
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

# cert-manager + x509pop resources (deployed by ztwim-instance, not this overlay):
components/ztwim-instance/
└── spire-cert-manager-ca.yaml        # ClusterIssuers + root CA cert (Reflector-mirrored)

clusters/etl7/overlays/ztwim-operator/
└── kustomization.yaml                # Adds CREATE_ONLY_MODE=true to operator Subscription

clusters/etl7/overlays/ztwim-instance/
└── x509pop-setup-job.yaml            # Job + RBAC: patches SPIRE Server for x509pop
```

## Post-Deployment Manual Steps Summary

After ArgoCD syncs the manifests:

1. **Wait for x509pop-setup Job** — runs automatically as a PostSync hook in the `ztwim-instance` Application. Check status: `oc get job x509pop-setup -n zero-trust-workload-identity-manager`
2. **Wait for spire-registration Job** — runs automatically as a PostSync hook in the `spire-vault-demo` Application. Check status: `oc get job spire-registration -n spire-vault-demo`
3. **Wait for DataVolume import** — CDI imports the QCOW2 from quay.io (may take 5–10 minutes): `oc get dv -n spire-vault-demo`
4. **Wait for VM boot** — `oc get vmi -n spire-vault-demo`
5. **Verify end-to-end** — follow the verification procedure (see "End-to-End Verification" above)

All SPIRE configuration (x509pop patching and registration entries) is automated via Jobs. The only manual steps are waiting and verifying.

## Related Stories

- **Story 1.6b** — Finalizes SPIRE agent and spiffe-helper configuration
- **Story 1.6c** — Finalizes Vault agent configuration
- **Story 1.6d** — Deploys the VM on OpenShift Virtualization (VirtualMachine CR, Service, Route, kustomization)


Abbreviated steps:

```sh
podman build -t quay.io/raffaelespazzoli/rhel10-spire-vault-demo:latest -f Containerfile .
podman save quay.io/raffaelespazzoli/rhel10-spire-vault-demo:latest | sudo podman load

sudo podman run --rm -it --privileged \
  --pull=newer \
  --security-opt label=type:unconfined_t \
  -v $(pwd)/output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  registry.redhat.io/rhel10/bootc-image-builder:latest \
  --type qcow2 \
  quay.io/raffaelespazzoli/rhel10-spire-vault-demo:latest

podman build -t quay.io/raffaelespazzoli/rhel10-spire-vault-demo-disk:latest -f Containerfile.disk .
podman push quay.io/raffaelespazzoli/rhel10-spire-vault-demo-disk:latest
```