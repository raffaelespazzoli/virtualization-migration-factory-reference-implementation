---
baseline_commit: 8b1a6155b759f424a2d92f6cbab64ef1e31c6576
review_loop_iteration: 1
---

# Story 1.7: Add tpm_devid VM to the SPIRE/Vault Demo

Status: done

## Story

As a platform engineer evaluating zero-trust workload identity,
I want a second VM in the `spire-vault-demo` overlay using `tpm_devid` attestation alongside the existing `x509pop` VM,
so that I can compare attestation methods side-by-side and demonstrate hardware-bound identity with vTPM.

## Acceptance Criteria

1. Shared bootc image updated: includes `tpm2-tools` and `tpm2-tss` RPMs, ships dual SPIRE agent configs (`agent-x509pop.conf`, `agent-tpm-devid.conf`) and dual Quadlet units; existing x509pop VM continues to work
2. New cert-manager `Certificate` CR (`tpm-devid-bootstrap-cert`) issued by the existing `spire-root-ca-issuer` ClusterIssuer, with `client auth` EKU
3. New `VirtualMachine` CR (`spire-vault-demo-tpm-vm`) with persistent vTPM, bootstrap cert disk, and cloud-init that provisions LDevID in vTPM
4. New `Service` and `Route` for the tpm VM's httpd endpoint
5. `x509pop-setup` Job updated to also register `tpm_devid` NodeAttestor in SPIRE Server ConfigMap
6. Separate registration Job (`tpm-spire-registration-job.yaml`) creates workload entry for the tpm_devid VM
7. ArgoCD `ignoreDifferences` on the tpm VM's volumes/disks (allows manual cert disk removal without drift)
8. `readme.md` updated with tpm_devid VM architecture, manual demo steps, debug-via-SSH workflow, and comparison with x509pop
9. Manual demo steps documented (not automated): remove bootstrap cert disk + restart VM after cloud-init completes

## Tasks / Subtasks

- [x] Task 1: Update shared bootc image (AC: #1)
  - [x] 1.1: Add `tpm2-tools tpm2-tss` to `dnf install` in Containerfile
  - [x] 1.2: Create `/etc/spire/tpm-devid/` directory (0700 spire:spire) for DevID cert and blobs
  - [x] 1.3: Keep `agent.conf` as-is (no rename per Dev Notes), create `agent-tpm-devid.conf`
  - [x] 1.4: Keep `spire-agent.container` as-is (no rename per Dev Notes)
  - [x] 1.5: Create `spire-agent-tpm-devid.container` (masked by default)
  - [x] 1.6: Update Containerfile COPY commands for new files
  - [x] 1.7: x509pop VM cloud-init unchanged (no rename = no breaking change)
- [x] Task 2: Create tpm-devid bootstrap Certificate CR (AC: #2)
  - [x] 2.1: `tpm-cert-bootstrap.yaml` in `spire-vault-demo` overlay
- [x] Task 3: Create tpm VirtualMachine CR (AC: #3)
  - [x] 3.1: `tpm-virtual-machine.yaml` with persistent vTPM, cert disk, cloud-init provisioning
- [x] Task 4: Create networking resources (AC: #4)
  - [x] 4.1: `tpm-service.yaml`
  - [x] 4.2: `tpm-route.yaml`
- [x] Task 5: Update x509pop-setup Job for tpm_devid attestor (AC: #5)
  - [x] 5.1: Add `tpm_devid` entry to awk script in `x509pop-setup-job.yaml`
  - [x] 5.2: Add `endorsement_ca_path` handling (optional Secret mount)
- [x] Task 6: Create tpm registration Job (AC: #6)
  - [x] 6.1: `tpm-spire-registration-job.yaml` with RBAC
  - [x] 6.2: Cross-namespace RBAC in `clusters/etl7/overlays/ztwim-instance/tpm-registration-rbac.yaml`
- [x] Task 7: Update ArgoCD Application for ignoreDifferences (AC: #7)
  - [x] 7.1: Add `ignoreDifferences` to `spire-vault-demo` app in `clusters/etl7/values.yaml`
- [x] Task 8: Update kustomization.yaml (AC: #1, #2, #3, #4, #6)
  - [x] 8.1: Add new resources to `clusters/etl7/overlays/spire-vault-demo/kustomization.yaml`
- [x] Task 9: Update readme.md (AC: #8, #9)
- [ ] Task 10: Rebuild and push shared bootc image (AC: #1) — manual operator step

## Dev Notes

### ⚠️ CRITICAL CORRECTION: tpm_devid Plugin Uses Blob Files, NOT Persistent Handles

The SPIRE `tpm_devid` agent plugin does **NOT** support a `devid_key_handle` parameter. It requires:
- `devid_cert_path` — PEM certificate file
- `devid_priv_path` — TPM private key **blob** (encrypted to the TPM, output of `tpm2_create -r`)
- `devid_pub_path` — TPM public key **blob** (output of `tpm2_create -u`)
- `tpm_device_path` — defaults to auto-detect (`/dev/tpmrm0`)

The blobs are NOT usable without the specific TPM that created them — the private key is still TPM-bound. But they must be stored as files on disk, not as persistent TPM handles.

**Reference:** [SPIRE tpm_devid agent plugin](https://github.com/spiffe/spire/blob/main/doc/plugin_agent_nodeattestor_tpm_devid.md)

### ⚠️ CRITICAL: tpm_devid Server Plugin Requires Endorsement CA

The SPIRE server-side `tpm_devid` plugin requires TWO CA certificates:

```hcl
NodeAttestor "tpm_devid" {
    plugin_data {
        devid_ca_path       = "/tmp/x509pop-ca/ca.crt.pem"
        endorsement_ca_path = "/tmp/x509pop-ca/endorsement-ca.pem"
    }
}
```

- `devid_ca_path` — the CA that signed the DevID cert (our cert-manager root CA — same as x509pop)
- `endorsement_ca_path` — the manufacturer CA that signed the TPM's EK cert (swtpm's local CA for vTPM)

**The endorsement CA is the swtpm manufacturer CA.** KubeVirt uses swtpm which generates an EK cert signed by a local CA, typically at `/var/lib/swtpm-localca/issuercert.pem` on the worker node. Options:
1. **Extract from the node** and create a Secret (requires node access — not GitOps friendly)
2. **Configure swtpm CA at the KubeVirt/HyperConverged level** if exposed
3. **Skip EK verification** by making `endorsement_ca_path` point to a permissive/wildcard CA (security trade-off for demo)

For the experiment, **Option 1** is recommended: SSH to a worker node, extract the swtpm CA cert, create a Secret, and mount it alongside the root CA. Document this as a one-time setup step.

**Reference:** [SPIRE tpm_devid server plugin](https://github.com/spiffe/spire/blob/main/doc/plugin_server_nodeattestor_tpm_devid.md)

### ⚠️ CRITICAL: KubeVirt Persistent vTPM Requirements

Setting `tpm: { persistent: true }` in the VM spec requires:

1. **Feature gate `VMPersistentState`** must be enabled in the KubeVirt CR (or HyperConverged CR on OCP)
2. **`vmStateStorageClass`** must be set in the KubeVirt CR — otherwise uses default StorageClass
3. The StorageClass must support `Filesystem` volumeMode (NOT Block)
4. For live migration, must be RWX; RWO works without migration

**Verify on etl7:** Check if `VMPersistentState` feature gate is already enabled:
```bash
oc get kubevirt kubevirt -n openshift-cnv -o jsonpath='{.spec.configuration.developerConfiguration.featureGates}'
```

If not enabled, a patch is needed on the HyperConverged CR. This may need to be a separate component or added to the existing virtualization instance overlay.

**TPM device path:** KubeVirt exposes the vTPM as `/dev/tpmrm0` inside the VM when `tpm:` is set. The `tpm-crb` model is used for persistent vTPMs (vs `tpm-tis` for non-persistent).

**Reference:** [KubeVirt persistent TPM docs](https://kubevirt.io/user-guide/compute/persistent_tpm_and_uefi_state/)

### ⚠️ CRITICAL: Quadlet Unit Renaming is a Breaking Change

Renaming `spire-agent.container` → `spire-agent-x509pop.container` changes the systemd service name from `spire-agent.service` to `spire-agent-x509pop.service`. This breaks:

1. **Existing x509pop VM cloud-init** — references `spire-agent.service` in `systemctl restart`
2. **spiffe-helper.container** — has `After=spire-agent.container` / `Requires=spire-agent.container`
3. **ConditionPathExists** — currently on `spire-agent.container`

**Solution:** Keep both Quadlet units referencing the same container name convention:

```
spire-agent-x509pop.container → generates spire-agent-x509pop.service
spire-agent-tpm-devid.container → generates spire-agent-tpm-devid.service
```

The spiffe-helper.container dependency must be updated. Since only ONE agent runs per VM, the dependency should be on whichever is active. Options:
- **Option A (recommended):** Create a systemd drop-in or a `spire-agent.target` that both Quadlet units satisfy. spiffe-helper depends on the target.
- **Option B:** Create TWO spiffe-helper variants (one per attestor) — too much duplication.
- **Option C:** Remove the hard dependency from spiffe-helper and rely on `Restart=on-failure` to retry until the agent is up.

**Option C is simplest for the demo.** Remove `After=spire-agent.container` / `Requires=spire-agent.container` from spiffe-helper.container and add `Restart=on-failure` with `RestartSec=5s`. spiffe-helper will fail until the agent socket exists, then succeed.

Actually, a simpler approach: **keep `spire-agent.container` for x509pop (no rename)** and add `spire-agent-tpm-devid.container` as the new unit. The tpm_devid VM cloud-init:
1. Masks `spire-agent.service` (stops the x509pop agent from starting)
2. Unmasks `spire-agent-tpm-devid.service`

spiffe-helper's dependency on `spire-agent.container` stays valid for x509pop VMs. For tpm_devid VMs, spiffe-helper starts after cloud-init unmasks the tpm agent, and the `Restart=on-failure` handles the timing.

**This avoids renaming any existing files** — no breaking change to the x509pop VM.

### Exact Agent Configuration: `agent-tpm-devid.conf`

```hcl
agent {
    data_dir = "/opt/spire/data"
    log_level = "DEBUG"
    trust_domain = "etl7.ocp.rht-labs.com"
    server_address = "spire-server.apps.etl7.ocp.rht-labs.com"
    server_port = "443"
    socket_path = "/run/spire/sockets/agent.sock"
    insecure_bootstrap = true
}

plugins {
    NodeAttestor "tpm_devid" {
        plugin_data {
            devid_cert_path = "/etc/spire/tpm-devid/devid.crt.pem"
            devid_priv_path = "/etc/spire/tpm-devid/devid.priv.blob"
            devid_pub_path  = "/etc/spire/tpm-devid/devid.pub.blob"
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

### Exact Quadlet: `spire-agent-tpm-devid.container`

```ini
[Unit]
Description=SPIRE Agent (tpm_devid attestation)
Wants=network-online.target
After=network-online.target
ConditionPathExists=/etc/spire/tpm-devid/devid.crt.pem
ConditionPathExists=/etc/spire/tpm-devid/devid.priv.blob
ConditionPathExists=/etc/spire/tpm-devid/devid.pub.blob
ConditionPathExists=/dev/tpmrm0

[Container]
Image=ghcr.io/spiffe/spire-agent:1.14.7
ContainerName=spire-agent-tpm
PodmanArgs=--pid=host --device /dev/tpmrm0
User=10001:10001
Volume=/etc/spire/tpm-devid:/etc/spire/tpm-devid:ro,z
Volume=/run/spire/sockets:/run/spire/sockets:z
Volume=/etc/spire/agent-tpm-devid.conf:/etc/spire/agent.conf:ro,z
Volume=/var/lib/spire/data:/opt/spire/data:z
Exec=-config /etc/spire/agent.conf

[Service]
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target default.target
```

**Key differences from `spire-agent.container`:**
- `PodmanArgs=--pid=host --device /dev/tpmrm0` — passes the TPM device into the container
- `Volume=/etc/spire/tpm-devid:...` — mounts DevID cert + blobs instead of bootstrap cert
- `Volume=/etc/spire/agent-tpm-devid.conf:/etc/spire/agent.conf:ro,z` — maps tpm_devid config to the standard path inside the container
- `ConditionPathExists=/etc/spire/tpm-devid/devid.crt.pem` — only starts if DevID was provisioned by cloud-init
- **Masked by default** — cloud-init unmasks on the tpm VM

### Exact Cloud-Init TPM Provisioning Script

**⚠️ CRITICAL: The cert-manager private key must be IMPORTED into the TPM using `tpm2_import`, NOT generated fresh with `tpm2_create`.** The DevID certificate's public key must match the TPM-held private key, so we wrap the cert-manager private key into TPM-encrypted blobs. This ensures the SPIRE `tpm_devid` plugin's proof-of-possession succeeds.

The cloud-init `runcmd` for the tpm VM must:

```yaml
runcmd:
  # ── 1. Mask x509pop agent, unmask tpm_devid agent ──
  - systemctl mask spire-agent.service
  # spire-agent-tpm-devid.service is masked by default at image build time;
  # unmask it so it can be started
  - systemctl unmask spire-agent-tpm-devid.service

  # ── 2. Wait for and mount bootstrap cert disk ──
  - bash -c 'for i in $(seq 30); do [ -e /dev/disk/by-id/virtio-TPMBOOTCERT ] && break; sleep 2; done'
  - mkdir -p /mnt/bootstrap-cert
  - mount /dev/disk/by-id/virtio-TPMBOOTCERT /mnt/bootstrap-cert

  # ── 3. Import cert-manager private key into vTPM ──
  # Create storage root key under owner hierarchy
  - tpm2_createprimary -C o -c /tmp/srk.ctx
  # Convert PEM private key to DER for tpm2_import
  - openssl rsa -in /mnt/bootstrap-cert/tls.key -outform DER -out /tmp/devid.key.der 2>/dev/null
  # Import the external private key into the TPM (wraps it as TPM-encrypted blobs)
  - tpm2_import -C /tmp/srk.ctx -G rsa -i /tmp/devid.key.der -u /tmp/devid.pub.blob -r /tmp/devid.priv.blob

  # ── 4. Store DevID artifacts for SPIRE agent ──
  - cp /mnt/bootstrap-cert/tls.crt /etc/spire/tpm-devid/devid.crt.pem
  - cp /tmp/devid.pub.blob /etc/spire/tpm-devid/devid.pub.blob
  - cp /tmp/devid.priv.blob /etc/spire/tpm-devid/devid.priv.blob
  - chown -R spire:spire /etc/spire/tpm-devid/
  - chmod 0400 /etc/spire/tpm-devid/*
  - chmod 0700 /etc/spire/tpm-devid/

  # ── 5. Clean up temp files and unmount ──
  - rm -f /tmp/srk.ctx /tmp/devid.key.der /tmp/devid.pub.blob /tmp/devid.priv.blob
  - umount /mnt/bootstrap-cert

  # ── 6. Update Vault agent config ──
  - sed -i 's/PLACEHOLDER_CLUSTER_BASE_DOMAIN/${CLUSTER_BASE_DOMAIN}/' /etc/vault-agent/agent.hcl

  # ── 7. Create data directory and start services ──
  - mkdir -p /var/lib/spire/data
  - chown spire:spire /var/lib/spire/data
  - podman pull ghcr.io/spiffe/spire-agent:1.14.7
  - podman pull ghcr.io/spiffe/spiffe-helper:0.11.0
  - podman pull docker.io/hashicorp/vault:1.20.4
  - podman pull registry.access.redhat.com/ubi10/httpd-24:latest
  - systemctl daemon-reload
  - systemctl reset-failed spire-agent-tpm-devid.service spiffe-helper.service vault-agent.service httpd.service
  - systemctl restart spire-agent-tpm-devid.service spiffe-helper.service vault-agent.service httpd.service
```

**Note:** The cert-manager Secret contains both `tls.crt` (the DevID certificate) and `tls.key` (the corresponding private key). The `tpm2_import` command wraps the private key into TPM-encrypted blobs (`devid.pub.blob`, `devid.priv.blob`) — these blobs are usable only by this specific vTPM instance. The cert's public key matches the TPM-held private key, so SPIRE's proof-of-possession succeeds.

### tpm_devid SPIFFE ID Format

The agent SPIFFE ID for `tpm_devid` is:
```
spiffe://<trust-domain>/spire/agent/tpm_devid/<sha1-fingerprint>
```

The fingerprint is the SHA1 hash of the DER encoding of the DevID certificate — same computation as x509pop. Since the DevID cert is the same cert-manager leaf cert (`tpm-devid-bootstrap-cert`), the registration Job can extract the fingerprint the same way as the existing x509pop registration Job.

### Server-Side Plugin Entry for x509pop-setup Job

The existing awk script in `x509pop-setup-job.yaml` inserts a single x509pop entry. For tpm_devid, insert a second entry:

```json
{"tpm_devid":{"plugin_data":{"devid_ca_path":"/tmp/x509pop-ca/ca.crt.pem","endorsement_ca_path":"/tmp/x509pop-ca/endorsement-ca.pem"}}}
```

**Endorsement CA handling:** The endorsement CA needs to be mounted alongside the root CA. Approaches:
1. **Add a second volume mount** with the swtpm CA cert
2. **Combine both CAs into one ConfigMap** and mount at a known path
3. **For the demo**, the swtpm CA cert can be extracted once and stored as a Secret, then mounted by the x509pop-setup Job

The x509pop-setup Job already mounts `spire-root-ca-secret` at `/tmp/x509pop-ca/`. Add the endorsement CA Secret mount at the same path or a parallel one.

### Vault JWT Role Must Accept Both Workload SPIFFE IDs

The tpm_devid VM uses a different workload SPIFFE ID: `spiffe://etl7.ocp.rht-labs.com/spire-vault-demo/tpm-workload`.

Options for the Vault JWT role:
1. **Glob pattern** — `bound_claims_type = "glob"` with `bound_subject = "spiffe://etl7.ocp.rht-labs.com/spire-vault-demo/*"`
2. **Second role** — `spire-tpm-vm-role` with the tpm-specific `bound_subject`
3. **Remove `bound_subject`** — rely only on `bound_audiences` for the demo

**Option 2** is cleanest for the demo — keeps the existing x509pop role untouched and adds a parallel role. The Vault `vault-spire-trust` overlay needs a new `JWTOIDCAuthEngineRole` CR for the tpm VM.

### Exact File Modifications and New Files

| File | Action | Notes |
|---|---|---|
| `clusters/etl7/overlays/spire-vault-demo/image/Containerfile` | UPDATE | Add `tpm2-tools tpm2-tss` to `dnf install`, create `/etc/spire/tpm-devid/`, COPY new config/Quadlet files |
| `clusters/etl7/overlays/spire-vault-demo/image/files/etc/spire/agent.conf` | KEEP | Stays as `agent.conf` (x509pop config, no rename) |
| `clusters/etl7/overlays/spire-vault-demo/image/files/etc/spire/agent-tpm-devid.conf` | NEW | tpm_devid agent config |
| `clusters/etl7/overlays/spire-vault-demo/image/files/etc/containers/systemd/spire-agent.container` | KEEP | Stays as-is (x509pop Quadlet, no rename) |
| `clusters/etl7/overlays/spire-vault-demo/image/files/etc/containers/systemd/spire-agent-tpm-devid.container` | NEW | tpm_devid Quadlet (masked by default) |
| `clusters/etl7/overlays/spire-vault-demo/tpm-cert-bootstrap.yaml` | NEW | cert-manager Certificate for tpm VM |
| `clusters/etl7/overlays/spire-vault-demo/tpm-virtual-machine.yaml` | NEW | VirtualMachine CR with vTPM + cloud-init |
| `clusters/etl7/overlays/spire-vault-demo/tpm-service.yaml` | NEW | Service targeting tpm VM |
| `clusters/etl7/overlays/spire-vault-demo/tpm-route.yaml` | NEW | Route for tpm VM httpd |
| `clusters/etl7/overlays/spire-vault-demo/tpm-spire-registration-job.yaml` | NEW | Registration Job + RBAC for tpm VM |
| `clusters/etl7/overlays/spire-vault-demo/kustomization.yaml` | UPDATE | Add new resources |
| `clusters/etl7/overlays/spire-vault-demo/virtual-machine.yaml` | UPDATE | Update cloud-init service names if needed |
| `clusters/etl7/overlays/ztwim-instance/x509pop-setup-job.yaml` | UPDATE | Add `tpm_devid` attestor entry |
| `clusters/etl7/overlays/ztwim-instance/tpm-registration-rbac.yaml` | NEW | Cross-namespace RBAC for tpm registration Job |
| `clusters/etl7/values.yaml` | UPDATE | Add `ignoreDifferences` to `spire-vault-demo` app |
| `clusters/etl7/overlays/spire-vault-demo/readme.md` | UPDATE | tpm_devid docs, manual demo steps |

### What NOT to Do

- **Do NOT use `devid_key_handle`** — this parameter does not exist in the SPIRE tpm_devid plugin. Use blob files (`devid_priv_path`, `devid_pub_path`) instead.
- **Do NOT rename `spire-agent.container`** to `spire-agent-x509pop.container` — this breaks the existing x509pop VM. Keep the original and add a new `spire-agent-tpm-devid.container` alongside it.
- **Do NOT forget `endorsement_ca_path`** on the server side — the tpm_devid server plugin requires it for EK verification. Skipping it will cause attestation failures.
- **Do NOT modify the existing x509pop VM cloud-init** unless absolutely necessary — the whole point is that the x509pop VM continues working unchanged with the updated shared image.
- **Do NOT use `tpm: {}` (non-persistent)** — the vTPM state must survive reboots. Use `tpm: { persistent: true }` and verify `VMPersistentState` feature gate is enabled.
- **Do NOT modify `clusters/etl4/` or any other cluster** — etl7 only.
- **Do NOT automate the cert disk removal** (AC #9 explicitly says manual demo step).
- **Do NOT create a second bootc image** — both VMs share a single image.
- **Do NOT modify the existing `spire-registration-job.yaml`** — create a separate `tpm-spire-registration-job.yaml`.

### Debug Workflow (AC #8)

The cloud-init TPM provisioning script is **novel integration work**. Debug iteratively:

1. Deploy the VM with SSH access (the `raffa-key` Secret is already in the namespace)
2. SSH in: `virtctl ssh cloud-user@spire-vault-demo-tpm-vm -n spire-vault-demo`
3. Verify vTPM is accessible: `ls -la /dev/tpmrm0`
4. Run `tpm2-tools` commands by hand:
   ```bash
   tpm2_createprimary -C o -c /tmp/srk.ctx
   tpm2_create -C /tmp/srk.ctx -G rsa2048 -u /tmp/devid.pub.blob -r /tmp/devid.priv.blob
   tpm2_load -C /tmp/srk.ctx -u /tmp/devid.pub.blob -r /tmp/devid.priv.blob -c /tmp/devid.ctx
   tpm2_getcap handles-persistent  # should be empty
   ```
5. Verify the SPIRE agent can use the blobs:
   ```bash
   sudo podman run --rm --device /dev/tpmrm0 \
     -v /etc/spire/tpm-devid:/etc/spire/tpm-devid:ro \
     ghcr.io/spiffe/spire-agent:1.14.7 \
     -config /etc/spire/agent.conf -logLevel DEBUG
   ```
6. Once working, copy the validated commands into the cloud-init `runcmd`.

### Codebase Patterns to Follow

| Pattern | Source | How This Story Uses It |
|---|---|---|
| Secret-backed disk for cert injection | `virtual-machine.yaml` (x509pop VM) | Same pattern, serial `TPMBOOTCERT` |
| Service + Route for VM httpd | `service.yaml` + `route.yaml` | Same `kubevirt.io/domain` selector, different VM name |
| Registration Job with RBAC | `spire-registration-job.yaml` | Same structure, different parentID attestor prefix |
| Cross-namespace RBAC | `spire-registration-rbac.yaml` | Same pattern, new SA name |
| ArgoCD `ignoreDifferences` | `vault` app in `values.yaml` | Same `extraFields` approach |
| cloud-init with runcmd | `virtual-machine.yaml` | Extended with tpm2-tools provisioning |
| Quadlet masked by default | Standard systemd pattern | `systemctl mask` in Containerfile, `unmask` in cloud-init |

### Cross-Story Dependencies and Impact

| Story | Dependency | Impact |
|---|---|---|
| **Story 1.6d** (x509pop VM) | Prerequisite | Proves shared infrastructure works; template for tpm VM |
| **Story 1.2** (ZTWIM Instance) | Prerequisite | SPIRE Server must be running; x509pop-setup Job adds tpm_devid attestor |
| **Story 1.5** (Vault Trust) | Impact | May need a second JWT role for the tpm workload SPIFFE ID, or existing role updated to accept both |
| **Story 1.6a** (Bootc Image) | Impact | Containerfile is modified — image must be rebuilt |

### Known Risks and Open Questions

1. **swtpm endorsement CA cert extraction** — Getting the swtpm manufacturer CA cert from the KubeVirt worker node is a one-time manual step. If the nodes are rebuilt, the CA changes. Investigate if OCP Virtualization exposes this cert.

2. **VMPersistentState feature gate** — May not be enabled on etl7. If it's missing, the vTPM state won't persist across reboots, which defeats the purpose. Check before implementation.

3. **tpm2-tools package availability in RHEL 10 bootc** — Verify `tpm2-tools` and `tpm2-tss` are available in the RHEL 10 bootc repos. If not, the packages may need to be sourced differently.

4. **SPIRE agent version compatibility** — Verify that `ghcr.io/spiffe/spire-agent:1.14.7` includes the `tpm_devid` NodeAttestor plugin. It's a built-in plugin, but confirm.

5. **Cloud-init script complexity** — The `tpm2-tools` commands are untested on a KubeVirt vTPM. The debug-via-SSH workflow is critical — budget 1-2 days for this.

6. **Vault role for tpm workload** — If Story 1.5's existing JWT role uses `bound_subject` with the x509pop SPIFFE ID, the tpm VM won't be able to authenticate until a second role is created or the existing role is updated. Coordinate with the vault-spire-trust overlay.

### References

- [SPIRE tpm_devid agent plugin](https://github.com/spiffe/spire/blob/main/doc/plugin_agent_nodeattestor_tpm_devid.md) — plugin config, blob file requirements
- [SPIRE tpm_devid server plugin](https://github.com/spiffe/spire/blob/main/doc/plugin_server_nodeattestor_tpm_devid.md) — server-side config, endorsement CA
- [KubeVirt persistent TPM docs](https://kubevirt.io/user-guide/compute/persistent_tpm_and_uefi_state/) — feature gate, storage class, VM spec
- [tpm2-tools — tpm2_createprimary](https://github.com/tpm2-software/tpm2-tools/blob/master/man/tpm2_createprimary.1.md) — create storage root key
- [tpm2-tools — tpm2_create](https://github.com/tpm2-software/tpm2-tools/blob/master/man/tpm2_create.1.md) — create LDevID key pair
- [TCG TPM 2.0 Keys for Device Identity and Attestation](https://trustedcomputinggroup.org/resource/tpm-2-0-keys-for-device-identity-and-attestation/) — LDevID spec
- [Source: epic-zero-trust-secret-delivery-etl7.md — Story 1.7]
- [Pattern: clusters/etl7/overlays/spire-vault-demo/virtual-machine.yaml] — x509pop VM template
- [Pattern: clusters/etl7/overlays/spire-vault-demo/spire-registration-job.yaml] — registration Job template
- [Pattern: clusters/etl7/overlays/ztwim-instance/x509pop-setup-job.yaml] — setup Job template

## Spec Change Log

### Change 1 (review loop 1)
- **Triggering finding:** DevID certificate and TPM key pair were generated independently — `tpm2_create` generates a NEW key pair unrelated to the cert-manager cert. SPIRE's proof-of-possession fails because the cert's public key doesn't match the TPM key.
- **What was amended:** Cloud-init provisioning script changed from `tpm2_create` (new key) to `tpm2_import` (wraps cert-manager's private key into TPM-encrypted blobs). Added `openssl rsa -outform DER` step to convert PEM to DER for import. Added wait loop for virtio disk. Added SPIRE agent image pre-pull. Added additional ConditionPathExists checks for blobs and `/dev/tpmrm0`. Added `client auth` EKU to Certificate CR. Cleaned up `/tmp` blob files in rm.
- **Known-bad state avoided:** Attestation failure — SPIRE agent presents cert with public key A but proves possession of TPM key B.
- **KEEP instructions:** All non-cloud-init files are correct and must be preserved exactly: Containerfile, agent-tpm-devid.conf, kustomization.yaml, x509pop-setup-job.yaml, values.yaml, tpm-cert-bootstrap.yaml (except add `client auth` EKU), tpm-service.yaml, tpm-route.yaml, tpm-spire-registration-job.yaml, tpm-registration-rbac.yaml. The readme.md structure is correct but the cloud-init documentation section must be updated to match.

## Dev Agent Record

### Agent Model Used

### Debug Log References

### Completion Notes List

### File List

## Suggested Review Order

**tpm_devid VM — Core Architecture**

- Cloud-init `tpm2_import` flow: wraps cert-manager key into TPM blobs; spiffe-helper drop-in override
  [`tpm-virtual-machine.yaml:100`](../../clusters/etl7/overlays/spire-vault-demo/tpm-virtual-machine.yaml#L100)

- SPIRE agent config: tpm_devid NodeAttestor with blob file paths
  [`agent-tpm-devid.conf:12`](../../clusters/etl7/overlays/spire-vault-demo/image/files/etc/spire/agent-tpm-devid.conf#L12)

- Quadlet with 4 ConditionPathExists guards (cert, blobs, /dev/tpmrm0), masked by default
  [`spire-agent-tpm-devid.container:5`](../../clusters/etl7/overlays/spire-vault-demo/image/files/etc/containers/systemd/spire-agent-tpm-devid.container#L5)

- Bootstrap cert with explicit RSA algorithm and client auth EKU
  [`tpm-cert-bootstrap.yaml:1`](../../clusters/etl7/overlays/spire-vault-demo/tpm-cert-bootstrap.yaml#L1)

**SPIRE Server Patching — Dual Attestor Support**

- Setup Job: idempotent x509pop + tpm_devid ConfigMap patching; endorsement CA volume mount
  [`x509pop-setup-job.yaml:180`](../../clusters/etl7/overlays/ztwim-instance/x509pop-setup-job.yaml#L180)

**Workload Registration**

- Registration Job: SHA1 fingerprint extraction, cross-namespace exec into SPIRE server
  [`tpm-spire-registration-job.yaml:60`](../../clusters/etl7/overlays/spire-vault-demo/tpm-spire-registration-job.yaml#L60)

- Cross-namespace RBAC for registration Job to exec into ZTWIM namespace
  [`tpm-registration-rbac.yaml:1`](../../clusters/etl7/overlays/ztwim-instance/tpm-registration-rbac.yaml#L1)

**Shared Image Updates**

- Containerfile: tpm2-tools RPMs, tpm-devid dir, dual COPY/mask
  [`Containerfile:12`](../../clusters/etl7/overlays/spire-vault-demo/image/Containerfile#L12)

**Networking & GitOps**

- Service + Route for tpm VM httpd
  [`tpm-service.yaml:1`](../../clusters/etl7/overlays/spire-vault-demo/tpm-service.yaml#L1)
  [`tpm-route.yaml:1`](../../clusters/etl7/overlays/spire-vault-demo/tpm-route.yaml#L1)

- ArgoCD ignoreDifferences for manual cert disk removal
  [`values.yaml:111`](../../clusters/etl7/values.yaml#L111)

- Kustomization resources list updated
  [`kustomization.yaml:9`](../../clusters/etl7/overlays/spire-vault-demo/kustomization.yaml#L9)

**Documentation**

- Full tpm_devid architecture, comparison table, manual demo steps, debug-via-SSH workflow
  [`readme.md:419`](../../clusters/etl7/overlays/spire-vault-demo/readme.md#L419)
