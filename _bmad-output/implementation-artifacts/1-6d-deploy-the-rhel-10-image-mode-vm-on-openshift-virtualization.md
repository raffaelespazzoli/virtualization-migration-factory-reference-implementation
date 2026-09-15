# Story 1.6d: Deploy the RHEL 10 Image-Mode VM on OpenShift Virtualization

Status: ready-for-dev

## Story

As a platform engineer,
I want the demo VM deployed on etl7 via a VirtualMachine CR managed by ArgoCD,
so that the complete zero-trust secret delivery pipeline is running end-to-end.

## Acceptance Criteria

1. Bootc image converted to QCOW2 and packaged as a containerDisk-compatible OCI image, with build/push documented
2. cert-manager `Issuer` and `Certificate` CRs in the demo overlay issuing a 1-year bootstrap leaf certificate for the VM
3. The cert-manager CA certificate added to the SPIRE Server's x509pop trusted CA bundle (via create-only mode annotation and ConfigMap/Secret patching)
4. `VirtualMachine` CR in `clusters/etl7/overlays/spire-vault-demo/` deploying the VM with:
   - DataVolume importing the QCOW2 containerDisk image from quay.io registry
   - cloud-init injecting bootstrap cert + key, SPIRE Server address, and Vault address
   - Adequate resources (2 vCPUs, 4Gi memory) for running all four Quadlet services
5. `Service` targeting the VM's httpd endpoint (port 8080) using `kubevirt.io/domain` label selector
6. `Route` exposing the httpd Service externally
7. SPIRE registration entries documented (manual `spire-server entry create` commands for both agent node and workload)
8. Application entry in `clusters/etl7/values.yaml` at sync-wave `25`
9. End-to-end verification procedure documented (boot → attest → JWT → Vault auth → secret → httpd)
10. SSH access procedure documented in `readme.md` (`virtctl ssh cloud-user@spire-vault-demo-vm -n spire-vault-demo`)

## Tasks / Subtasks

- [ ] Task 1: Create QCOW2 conversion and containerDisk packaging documentation (AC: #1)
  - [ ] 1.1: Document `bootc-image-builder` conversion from bootc OCI image to QCOW2
  - [ ] 1.2: Document Containerfile that packages QCOW2 as `/disk/disk.qcow2` (UID 107, mode 0440)
  - [ ] 1.3: Document push to quay.io as `quay.io/<org>/rhel10-spire-vault-demo-disk:latest`
- [ ] Task 2: Create cert-manager resources (AC: #2)
  - [ ] 2.1: `self-signed-issuer.yaml` — SelfSigned Issuer
  - [ ] 2.2: `spire-bootstrap-ca.yaml` — CA Certificate signed by SelfSigned Issuer (isCA: true, 10yr)
  - [ ] 2.3: `spire-bootstrap-ca-issuer.yaml` — Issuer referencing the CA secret
  - [ ] 2.4: `spire-bootstrap-cert.yaml` — 1-year leaf Certificate for the VM (digitalSignature usage)
- [ ] Task 3: Create SPIRE Server x509pop trust configuration (AC: #3)
  - [ ] 3.1: Document `ztwim.openshift.io/create-only=true` annotation on SpireServer CR
  - [ ] 3.2: Create `spire-x509pop-ca-secret.yaml` — Secret containing the CA cert for x509pop
  - [ ] 3.3: Document manual steps to patch the spire-server ConfigMap and mount the CA bundle
- [ ] Task 4: Create VirtualMachine CR (AC: #4)
  - [ ] 4.1: `virtual-machine.yaml` with DataVolumeTemplate importing from registry
  - [ ] 4.2: cloud-init `write_files` for bootstrap cert + key + config overrides
  - [ ] 4.3: Secret-backed disk for injecting cert-manager certificate into the VM
  - [ ] 4.4: SSH access credential for debugging
- [ ] Task 5: Create networking resources (AC: #5, #6)
  - [ ] 5.1: `service.yaml` — Service with `kubevirt.io/domain` selector on port 8080
  - [ ] 5.2: `route.yaml` — Route exposing the httpd endpoint
- [ ] Task 6: Document SPIRE registration entries (AC: #7)
  - [ ] 6.1: Node registration for x509pop agent
  - [ ] 6.2: Workload registration for spiffe-helper (unix:uid:10002)
- [ ] Task 7: Create kustomization.yaml for the overlay (AC: #8)
  - [ ] 7.1: Reference all new resources
  - [ ] 7.2: Set namespace `spire-vault-demo`
- [ ] Task 8: Add application entry to clusters/etl7/values.yaml (AC: #8)
- [ ] Task 9: Document end-to-end verification (AC: #9)
- [ ] Task 10: Document SSH access procedure in readme.md (AC: #10)
  - [ ] 10.1: `virtctl ssh cloud-user@spire-vault-demo-vm -n spire-vault-demo`
  - [ ] 10.2: `virtctl console spire-vault-demo-vm -n spire-vault-demo` (serial console fallback)
  - [ ] 10.3: Note that `raffa-key` Secret must exist in the `spire-vault-demo` namespace

## Dev Notes

### ⚠️ CRITICAL: Bootc Image Cannot Be Used Directly as containerDisk

A bootc OCI image contains a filesystem tree, NOT a disk image. KubeVirt requires a QCOW2 or RAW disk image at `/disk/` inside the container image. The conversion pipeline is:

1. **Build bootc image** (Story 6a) → push to `quay.io/<org>/rhel10-spire-vault-demo:latest`
2. **Convert to QCOW2** using `bootc-image-builder`:
   ```bash
   sudo podman run --rm -it --privileged \
     --pull=newer \
     --security-opt label=type:unconfined_t \
     -v $(pwd)/output:/output \
     -v /var/lib/containers/storage:/var/lib/containers/storage \
     registry.redhat.io/rhel10/bootc-image-builder:latest \
     --type qcow2 \
     quay.io/<org>/rhel10-spire-vault-demo:latest
   ```
3. **Package as containerDisk** — create `Containerfile.disk`:
   ```dockerfile
   FROM scratch
   ADD --chown=107:107 output/qcow2/disk.qcow2 /disk/
   ```
   Build and push:
   ```bash
   podman build -t quay.io/<org>/rhel10-spire-vault-demo-disk:latest -f Containerfile.disk .
   podman push quay.io/<org>/rhel10-spire-vault-demo-disk:latest
   ```

The resulting `quay.io/<org>/rhel10-spire-vault-demo-disk:latest` is what the VirtualMachine CR references.

**Source:** [Build and deploy image mode for RHEL on OpenShift Virtualization](https://developers.redhat.com/articles/2024/11/11/deploy-image-mode-rhel-openshift-virtualization)

### ⚠️ CRITICAL: DataVolume vs containerDisk Decision — Use DataVolume

**Decision: Use DataVolume with registry source**, not containerDisk.

Reasons:
- The RHEL 10 bootc image with SPIRE, Vault, httpd, and Quadlet containers will produce a QCOW2 of ~3-5 GB
- containerDisk is ephemeral — the entire image is loaded into the virt-launcher pod's memory, which is impractical for large images
- DataVolume with registry source imports the QCOW2 container image once, creates a persistent PVC, and boots from it
- Restarts don't re-download the image
- For this experiment, persistence is acceptable (we're not testing scale, we're validating the trust chain)

**DataVolumeTemplate in VirtualMachine:**
```yaml
dataVolumeTemplates:
  - metadata:
      name: spire-vault-demo-vm-rootdisk
    spec:
      source:
        registry:
          url: docker://quay.io/<org>/rhel10-spire-vault-demo-disk:latest
      storage:
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: 20Gi
        storageClassName: ontap-san
```

The CDI (Containerized Data Importer) automatically pulls the container image, extracts the QCOW2, converts to raw, and creates the PVC.

### ⚠️ CRITICAL: Bootstrap Certificate Injection Strategy

KubeVirt does NOT support `contentFrom: secret` in cloud-init `write_files`. The cert-manager-generated certificate must be injected via a **Secret-backed disk volume**.

**Approach:**
1. cert-manager creates a Secret `spire-bootstrap-cert` with keys `tls.crt` and `tls.key`
2. Mount this Secret as a disk in the VirtualMachine spec (KubeVirt Secret disk)
3. cloud-init `runcmd` copies the cert files from the mounted disk to `/etc/spire/bootstrap/` with correct ownership and permissions

```yaml
# In VirtualMachine spec:
volumes:
  - name: bootstrap-cert-disk
    secret:
      secretName: spire-bootstrap-cert
# In domain.devices.disks:
  - name: bootstrap-cert-disk
    disk:
      bus: virtio
    serial: SPIREBOOTCERT
```

KubeVirt mounts Secret-backed disks as ISO9660 filesystems. Inside the VM, the disk appears at a device path. cloud-init `runcmd` handles the copy:

```yaml
runcmd:
  - mkdir -p /mnt/bootstrap-cert
  - mount /dev/disk/by-id/virtio-SPIREBOOTCERT /mnt/bootstrap-cert
  - cp /mnt/bootstrap-cert/tls.crt /etc/spire/bootstrap/agent.crt.pem
  - cp /mnt/bootstrap-cert/tls.key /etc/spire/bootstrap/agent.key.pem
  - chown spire:spire /etc/spire/bootstrap/agent.crt.pem /etc/spire/bootstrap/agent.key.pem
  - chmod 0400 /etc/spire/bootstrap/agent.crt.pem /etc/spire/bootstrap/agent.key.pem
  - umount /mnt/bootstrap-cert
```

### ⚠️ CRITICAL: SPIRE Registration Entries — Manual Step Required

The SPIRE Controller Manager's `ClusterSPIFFEID` CRD only targets **pods** — it uses `podSelector` and `namespaceSelector`. The VM's spire-agent is NOT a pod workload; it's an external agent using x509pop attestation.

**The x509pop agent auto-attests** — when the spire-agent inside the VM connects to the SPIRE Server and presents the bootstrap certificate, the server validates it against the trusted CA bundle and assigns a node SPIFFE ID of the form:
```
spiffe://etl7.ocp.rht-labs.com/spire/agent/x509pop/<sha1-fingerprint>
```

**But workloads still need registration entries.** After the agent attests, the spiffe-helper process needs a workload entry to receive SVIDs. Since the WorkloadAttestor inside the agent is `unix`, the selector matches on the UID of the connecting process.

**Manual commands to run after the VM boots and agent attests:**

```bash
# 1. Get the spire-server pod name
SPIRE_POD=$(oc get pods -n zero-trust-workload-identity-manager -l app=spire-server -o jsonpath='{.items[0].metadata.name}')

# 2. List attested agents to find the VM agent's SPIFFE ID
oc exec -n zero-trust-workload-identity-manager $SPIRE_POD -c spire-server -- \
  /opt/spire/bin/spire-server agent list

# 3. Copy the agent's SPIFFE ID (contains the x509pop fingerprint)
# Example: spiffe://etl7.ocp.rht-labs.com/spire/agent/x509pop/abc123...

# 4. Create workload registration entry for spiffe-helper
oc exec -n zero-trust-workload-identity-manager $SPIRE_POD -c spire-server -- \
  /opt/spire/bin/spire-server entry create \
  -parentID "spiffe://etl7.ocp.rht-labs.com/spire/agent/x509pop/<FINGERPRINT>" \
  -spiffeID "spiffe://etl7.ocp.rht-labs.com/spire-vault-demo/workload" \
  -selector "unix:uid:10002" \
  -jwt-svid-ttl 3600
```

The `-jwt-svid-ttl 3600` sets the JWT-SVID TTL to 1 hour (matching the Vault role's `token_ttl` from Story 5).

**The SPIFFE ID `spiffe://etl7.ocp.rht-labs.com/spire-vault-demo/workload` must match the `bound_subject` in the Vault JWT role (Story 5).** If Story 5 was implemented with a different `bound_subject`, update either the registration entry or the Vault role to match.

### ⚠️ CRITICAL: SPIRE Server x509pop CA Trust — Create-Only Mode Patching

The SpireServer CRD does NOT expose a field for x509pop NodeAttestor configuration (confirmed in Story 1.2). Enabling x509pop requires:

1. **Annotate SpireServer CR** to enable create-only mode:
   ```bash
   oc annotate spireserver cluster -n zero-trust-workload-identity-manager \
     ztwim.openshift.io/create-only=true
   ```

2. **Create a Secret** with the cert-manager CA certificate:
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: spire-x509pop-ca
     namespace: zero-trust-workload-identity-manager
   type: Opaque
   data:
     ca-bundle.crt: <base64 of cert-manager CA cert>
   ```
   The CA cert content comes from the `spire-bootstrap-ca` Secret created by cert-manager (key: `ca.crt`).

3. **Patch the spire-server StatefulSet** to mount the CA Secret:
   ```bash
   oc patch statefulset spire-server -n zero-trust-workload-identity-manager --type='json' -p='[
     {"op": "add", "path": "/spec/template/spec/volumes/-", "value": {"name": "x509pop-ca", "secret": {"secretName": "spire-x509pop-ca"}}},
     {"op": "add", "path": "/spec/template/spec/containers/0/volumeMounts/-", "value": {"name": "x509pop-ca", "mountPath": "/run/spire/x509pop", "readOnly": true}}
   ]'
   ```

4. **Patch the spire-server ConfigMap** to add the x509pop NodeAttestor plugin:
   ```bash
   # Get the current config
   oc get configmap spire-server -n zero-trust-workload-identity-manager -o jsonpath='{.data.server\.conf}' > /tmp/server.conf
   
   # Add the x509pop plugin to the plugins section:
   # NodeAttestor "x509pop" {
   #     plugin_data {
   #         ca_bundle_path = "/run/spire/x509pop/ca-bundle.crt"
   #     }
   # }
   
   # Update the ConfigMap
   oc create configmap spire-server -n zero-trust-workload-identity-manager \
     --from-file=server.conf=/tmp/server.conf --dry-run=client -o yaml | oc apply -f -
   ```

5. **Restart the SPIRE Server** to pick up the new config:
   ```bash
   oc rollout restart statefulset spire-server -n zero-trust-workload-identity-manager
   ```

**Source:** [Sky Computing Part 2 — x509pop on ZTWIM](https://developers.redhat.com/blog/2026/04/23/sky-computing-openshift-service-mesh-spire-multicloud-integration)

**These manual steps should be documented in the overlay's `readme.md` as a post-deployment procedure.** They cannot be fully GitOps-managed because the SpireServer CRD doesn't support x509pop natively. Include them as a script (`configure-x509pop.sh`) in the overlay directory for reproducibility.

### Exact File Templates

#### `clusters/etl7/overlays/spire-vault-demo/namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: spire-vault-demo
  annotations:
    argocd.argoproj.io/sync-options: Delete=false
  labels:
    argocd.argoproj.io/managed-by: openshift-gitops
```

#### `clusters/etl7/overlays/spire-vault-demo/self-signed-issuer.yaml`

```yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
```

#### `clusters/etl7/overlays/spire-vault-demo/spire-bootstrap-ca.yaml`

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: spire-bootstrap-ca
spec:
  isCA: true
  commonName: SPIRE Bootstrap CA
  secretName: spire-bootstrap-ca
  duration: 87600h  # 10 years
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-issuer
    kind: Issuer
    group: cert-manager.io
  subject:
    organizations:
      - Red Hat Labs
    organizationalUnits:
      - SPIRE Bootstrap
  usages:
    - cert sign
    - crl sign
    - digital signature
```

#### `clusters/etl7/overlays/spire-vault-demo/spire-bootstrap-ca-issuer.yaml`

```yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: spire-bootstrap-ca-issuer
spec:
  ca:
    secretName: spire-bootstrap-ca
```

#### `clusters/etl7/overlays/spire-vault-demo/spire-bootstrap-cert.yaml`

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: spire-bootstrap-cert
spec:
  secretName: spire-bootstrap-cert
  duration: 8760h  # 1 year
  commonName: spire-vault-demo-vm.etl7.ocp.rht-labs.com
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: spire-bootstrap-ca-issuer
    kind: Issuer
    group: cert-manager.io
  usages:
    - digital signature
    - client auth
```

**Critical:** The `digital signature` usage is REQUIRED by the x509pop NodeAttestor — without it, attestation fails.

#### `clusters/etl7/overlays/spire-vault-demo/virtual-machine.yaml`

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: spire-vault-demo-vm
  labels:
    app: spire-vault-demo
spec:
  dataVolumeTemplates:
    - apiVersion: cdi.kubevirt.io/v1beta1
      kind: DataVolume
      metadata:
        name: spire-vault-demo-vm-rootdisk
      spec:
        source:
          registry:
            url: docker://quay.io/<org>/rhel10-spire-vault-demo-disk:latest
        storage:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 20Gi
          storageClassName: ontap-san
  running: true
  template:
    metadata:
      annotations:
        vm.kubevirt.io/os: rhel10
        vm.kubevirt.io/workload: server
      labels:
        kubevirt.io/domain: spire-vault-demo-vm
        app: spire-vault-demo
    spec:
      architecture: amd64
      domain:
        cpu:
          cores: 2
          sockets: 1
          threads: 1
        devices:
          disks:
            - disk:
                bus: virtio
              name: rootdisk
            - disk:
                bus: virtio
              name: cloudinitdisk
            - disk:
                bus: virtio
              name: bootstrap-cert-disk
              serial: SPIREBOOTCERT
          interfaces:
            - masquerade: {}
              name: default
              ports:
                - port: 8080
          rng: {}
        features:
          acpi: {}
          smm:
            enabled: true
        firmware:
          bootloader:
            efi: {}
        machine:
          type: pc-q35-rhel9.6.0
        memory:
          guest: 4Gi
        resources: {}
      networks:
        - name: default
          pod: {}
      terminationGracePeriodSeconds: 180
      accessCredentials:
        - sshPublicKey:
            source:
              secret:
                secretName: raffa-key
            propagationMethod:
              noCloud: {}
      volumes:
        - dataVolume:
            name: spire-vault-demo-vm-rootdisk
          name: rootdisk
        - secret:
            secretName: spire-bootstrap-cert
          name: bootstrap-cert-disk
        - cloudInitNoCloud:
            userData: |-
              #cloud-config
              user: cloud-user
              password: spire-vault-demo
              chpasswd: { expire: False }
              runcmd:
                # Mount the bootstrap cert disk and copy certs
                - mkdir -p /mnt/bootstrap-cert
                - mount /dev/disk/by-id/virtio-SPIREBOOTCERT /mnt/bootstrap-cert
                - cp /mnt/bootstrap-cert/tls.crt /etc/spire/bootstrap/agent.crt.pem
                - cp /mnt/bootstrap-cert/tls.key /etc/spire/bootstrap/agent.key.pem
                - chown spire:spire /etc/spire/bootstrap/agent.crt.pem /etc/spire/bootstrap/agent.key.pem
                - chmod 0400 /etc/spire/bootstrap/agent.crt.pem /etc/spire/bootstrap/agent.key.pem
                - umount /mnt/bootstrap-cert
                # Update SPIRE agent config with actual server address
                - sed -i 's/PLACEHOLDER_SPIRE_SERVER_ADDRESS/spire-server.zero-trust-workload-identity-manager.svc/' /etc/spire/agent.conf
                # Update Vault agent config with actual cluster domain
                - sed -i 's/PLACEHOLDER_CLUSTER_BASE_DOMAIN/${CLUSTER_BASE_DOMAIN}/' /etc/vault-agent/agent.hcl
                # Create spire-agent data directory (needed for KeyManager "disk")
                - mkdir -p /opt/spire/data
                - chown spire:spire /opt/spire/data
                # Enable and start Quadlet services (systemd auto-generates from .container files)
                - systemctl daemon-reload
                - systemctl enable --now spire-agent.service
          name: cloudinitdisk
```

**Notes on the VirtualMachine CR:**
- `interfaces[].masquerade` with `ports: [{port: 8080}]` is **required** for the Service to route traffic to the VM — without the port declaration, masquerade networking won't forward traffic on that port
- `dataVolumeTemplates` with `source.registry.url` uses CDI to import the QCOW2 from the container image
- `storageClassName: ontap-san` matches the etl7 cluster's available storage (same as SpireServer persistence in Story 1.2)
- `accessCredentials` with `raffa-key` matches the existing SSH key pattern from other VMs in the repo (e.g., `fedora-vm1` in `clusters/etl6/`)
- 4Gi memory is adequate for SPIRE agent + spiffe-helper + vault-agent + httpd running as Quadlet containers
- 2 vCPUs provide headroom for the four concurrent services
- `serial: SPIREBOOTCERT` on the bootstrap cert disk enables the VM to locate it via `/dev/disk/by-id/virtio-SPIREBOOTCERT`
- The `sed` commands update placeholder values in config files created by Story 6a — note that `${CLUSTER_BASE_DOMAIN}` will be resolved by ArgoCD's envsubst CMP sidecar before the manifest reaches the cluster, so it appears as the actual domain in the VM's cloud-init
- Quadlet `.container` files are built into the bootc image (Story 6a) at `/etc/containers/systemd/` — systemd auto-generates `.service` units from them on `daemon-reload`
- The dependency chain in Quadlet files (`After=`, `Requires=`) handles startup ordering: spire-agent → spiffe-helper → vault-agent → httpd

#### `clusters/etl7/overlays/spire-vault-demo/service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: spire-vault-demo-httpd
  labels:
    app: spire-vault-demo
spec:
  selector:
    kubevirt.io/domain: spire-vault-demo-vm
  ports:
    - name: http
      protocol: TCP
      port: 8080
      targetPort: 8080
```

**Note:** The `kubevirt.io/domain` label selector targets the VM's virt-launcher pod, which proxies traffic to the VM. The httpd container inside the VM publishes port 8080 via the Quadlet `PublishPort=8080:8080` directive. Since the VM uses `masquerade` networking (default pod network), traffic from the Service reaches the VM's pod network interface, where Podman's port publishing forwards it to the httpd container.

#### `clusters/etl7/overlays/spire-vault-demo/route.yaml`

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: spire-vault-demo-httpd
  labels:
    app: spire-vault-demo
spec:
  host: spire-vault-demo.apps.${CLUSTER_BASE_DOMAIN}
  to:
    kind: Service
    name: spire-vault-demo-httpd
  port:
    targetPort: http
```

The `${CLUSTER_BASE_DOMAIN}` is resolved by the envsubst CMP sidecar (standard repo convention).

#### `clusters/etl7/overlays/spire-vault-demo/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: spire-vault-demo

resources:
  - namespace.yaml
  - self-signed-issuer.yaml
  - spire-bootstrap-ca.yaml
  - spire-bootstrap-ca-issuer.yaml
  - spire-bootstrap-cert.yaml
  - virtual-machine.yaml
  - service.yaml
  - route.yaml
```

**Note:** The cert-manager resources (Issuer, Certificate) must be in the same namespace as the VirtualMachine to keep the Secret accessible. All resources deploy into the `spire-vault-demo` namespace.

#### `clusters/etl7/values.yaml` — add this block

Insert under the `# Zero Trust` section (after `vault-spire-trust` if it exists, otherwise after the last zero-trust entry):

```yaml
  spire-vault-demo:
    annotations:
      argocd.argoproj.io/sync-wave: '25'
    source:
      path: clusters/etl7/overlays/spire-vault-demo
```

Wave `25` is correct — this depends on ZTWIM instance (wave 15), Vault (wave 15), and vault-spire-trust (wave 25, but will complete before this deploys since ArgoCD handles ordering within the same wave by resource kind and name).

### ⚠️ CRITICAL: cloud-init and envsubst Interaction

The cloud-init `userData` contains `${CLUSTER_BASE_DOMAIN}` — this is resolved by ArgoCD's envsubst CMP sidecar BEFORE the manifest reaches the cluster. So the actual cloud-init userdata in the VirtualMachine CR will contain the resolved domain (e.g., `etl7.ocp.rht-labs.com`). The `sed` command in `runcmd` replaces `PLACEHOLDER_CLUSTER_BASE_DOMAIN` with the actual resolved domain. However, because envsubst runs on the entire manifest, the `sed` command itself must use a different placeholder name that envsubst won't try to resolve.

**Resolution:** The `sed` command uses `PLACEHOLDER_CLUSTER_BASE_DOMAIN` (a literal string in the config files from Story 6a). The `sed` replacement value is the resolved `${CLUSTER_BASE_DOMAIN}` which envsubst will have already replaced. So the cloud-init `runcmd` line:

```yaml
- sed -i 's/PLACEHOLDER_CLUSTER_BASE_DOMAIN/etl7.ocp.rht-labs.com/' /etc/vault-agent/agent.hcl
```

will be the actual manifest content after envsubst processes it. This works correctly.

### ⚠️ CRITICAL: SPIRE Server Address for VM Agent

The VM's spire-agent config needs to reach the SPIRE Server. Options:
1. **Cluster-internal service** (`spire-server.zero-trust-workload-identity-manager.svc`) — only works if the VM is on the pod network (masquerade mode)
2. **External Route** — works regardless, but requires TLS configuration

**Use the internal service URL** since the VM uses masquerade networking (default pod network). The VM has direct access to cluster services via the pod network. The `runcmd` sed command replaces `PLACEHOLDER_SPIRE_SERVER_ADDRESS` in the agent config.

The SPIRE Server port is `8081` (gRPC API) — already set in Story 6a's placeholder config.

### Networking Architecture

```
                     ┌─────────── OpenShift Cluster (etl7) ───────────┐
                     │                                                 │
  External User ──── Route ──── Service ──── virt-launcher pod         │
  (browser)          │          (8080)       │                         │
                     │                       ├─ VM (masquerade net)    │
                     │                       │  ├─ httpd (:8080)       │
                     │                       │  ├─ vault-agent         │
                     │                       │  ├─ spiffe-helper       │
                     │                       │  └─ spire-agent ──────── SPIRE Server
                     │                       │                    (8081) (pod svc)
                     │                       │                         │
                     │                       └─ vault-agent ──────── Vault
                     │                                          (8200) (route)
                     └─────────────────────────────────────────────────┘
```

The VM accesses:
- **SPIRE Server** via pod network (`spire-server.zero-trust-workload-identity-manager.svc:8081`)
- **Vault** via the Vault Route (`vault.apps.${CLUSTER_BASE_DOMAIN}`) — using the Route ensures TLS with the service-serving cert. vault-agent needs `VAULT_SKIP_VERIFY=true` or the cluster CA bundle.

### Vault TLS for vault-agent Inside the VM

The vault-agent inside the VM connects to Vault via the Route (`https://vault.apps.etl7.ocp.rht-labs.com`). The Route uses `reencrypt` TLS termination with an OCP-signed certificate.

**For the experiment, set `VAULT_SKIP_VERIFY=true`** in the vault-agent Quadlet environment (Story 6c should have set this in `vault-agent.container`). The alternative — injecting the OCP ingress CA into the VM — adds complexity without value for this experiment.

If Story 6c's `vault-agent.container` doesn't include `Environment=VAULT_SKIP_VERIFY=true`, add it:
```ini
[Container]
...
Environment=VAULT_SKIP_VERIFY=true
```

This requires rebuilding the bootc image after the change.

### End-to-End Verification Procedure

After deployment, verify the complete trust chain:

```bash
# 1. Verify VM is running
oc get vm spire-vault-demo-vm -n spire-vault-demo

# 2. SSH into the VM (or use virtctl console)
virtctl ssh cloud-user@spire-vault-demo-vm -n spire-vault-demo
# Or:
virtctl console spire-vault-demo-vm -n spire-vault-demo

# 3. Inside the VM — check bootstrap cert was injected
ls -la /etc/spire/bootstrap/

# 4. Check spire-agent is running and attested
sudo podman logs spire-agent
# Look for: "Successfully attested" and "Node attestation was successful"

# 5. Check spiffe-helper is extracting SVIDs
ls -la /var/run/secrets/spiffe/
# Should contain: svid.crt.pem, svid.key.pem, bundle.crt.pem, jwt-svid.token
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
curl https://spire-vault-demo.apps.${CLUSTER_BASE_DOMAIN}/secret.txt
# Should return: "Hello from Vault via SPIFFE zero-trust!"
```

### Files Created/Modified by This Story

| File | Action | Notes |
|---|---|---|
| `clusters/etl7/overlays/spire-vault-demo/namespace.yaml` | NEW | Demo namespace |
| `clusters/etl7/overlays/spire-vault-demo/self-signed-issuer.yaml` | NEW | cert-manager SelfSigned Issuer |
| `clusters/etl7/overlays/spire-vault-demo/spire-bootstrap-ca.yaml` | NEW | CA Certificate for SPIRE bootstrap |
| `clusters/etl7/overlays/spire-vault-demo/spire-bootstrap-ca-issuer.yaml` | NEW | CA Issuer for leaf cert |
| `clusters/etl7/overlays/spire-vault-demo/spire-bootstrap-cert.yaml` | NEW | 1-year leaf cert for VM |
| `clusters/etl7/overlays/spire-vault-demo/virtual-machine.yaml` | NEW | VirtualMachine CR with DataVolume |
| `clusters/etl7/overlays/spire-vault-demo/service.yaml` | NEW | Service for httpd endpoint |
| `clusters/etl7/overlays/spire-vault-demo/route.yaml` | NEW | Route for external access |
| `clusters/etl7/overlays/spire-vault-demo/kustomization.yaml` | NEW or UPDATE | Add new resources to existing kustomization (Story 6a may have created this) |
| `clusters/etl7/values.yaml` | UPDATE | Add `spire-vault-demo` app entry |

**Note:** Story 6a already creates the `clusters/etl7/overlays/spire-vault-demo/` directory with `image/` subdirectory and `readme.md`. This story adds Kubernetes manifests alongside it. If a `kustomization.yaml` already exists from Story 6a, update it to include the new resources. If not, create it.

### What NOT to Do

- **Do NOT use the bootc OCI image directly as a containerDisk** — it contains a filesystem tree, not a QCOW2 disk image. Convert with bootc-image-builder first.
- **Do NOT use containerDisk volume type** — the RHEL 10 QCOW2 is too large for ephemeral containerDisk (loaded into virt-launcher memory). Use DataVolume with registry source.
- **Do NOT use `contentFrom: secret` in cloud-init `write_files`** — KubeVirt does not support this. Use Secret-backed disk volumes instead.
- **Do NOT try to create SPIRE registration entries via ClusterSPIFFEID CRD** — that CRD only targets pods, not VMs with x509pop attestation. Use manual `spire-server entry create` commands.
- **Do NOT hardcode the x509pop certificate fingerprint in a manifest** — the fingerprint is derived from the cert-manager-generated certificate at deploy time. It's dynamic and must be discovered after deployment.
- **Do NOT skip the SPIRE Server x509pop patching** — without adding the x509pop NodeAttestor plugin and CA bundle to the SPIRE Server, the VM's agent cannot attest. This is a manual post-deployment step.
- **Do NOT modify any existing Story 6a files** — the `image/` directory and `readme.md` belong to Story 6a. This story adds new files alongside them.
- **Do NOT modify `clusters/etl4/` or any other cluster** — etl7 only
- **Do NOT add this to `groups/prod/values.yaml`** — this is an etl7-only experiment
- **Do NOT use `runStrategy: Always`** without understanding that DataVolume imports happen once — `running: true` is simpler for this experiment
- **Do NOT forget the `raffa-key` SSH access credential** — it's used by all VMs in this repo for SSH debugging access
- **Do NOT use a fixed MAC address** — the `masquerade` interface doesn't require one (unlike `bridge` interfaces in other VMs)

### Codebase Patterns to Follow

This story follows patterns established by existing VMs and overlays in the repo:

| Pattern | Source | How This Story Uses It |
|---|---|---|
| VirtualMachine CR with DataVolume | `clusters/etl6/overlays/vm-tests/fedora-vms.yaml` | Same structure, but with `source.registry` instead of `sourceRef.DataSource` |
| SSH access credentials | `clusters/etl6/overlays/vm-tests/fedora-vms.yaml` | Same `raffa-key` secret reference and `noCloud` propagation |
| cloud-init with runcmd | `clusters/etl6/overlays/sm-on-udn/vms.yaml` | Same pattern for post-boot configuration |
| cert-manager self-signed CA | `clusters/hub/overlays/soteria-root-cert/` | Same self-signed issuer → CA cert → CA issuer chain |
| Overlay with kustomization | `clusters/etl7/overlays/vault/` | Same `clusters/<cluster>/overlays/<name>/` pattern |
| Service for VM | `clusters/etl6/overlays/sm-on-udn/vms.yaml` | Same `kubevirt.io/domain` label selector |
| Route with envsubst | `components/vault/` (via overlay patches) | Same `${CLUSTER_BASE_DOMAIN}` pattern |

### Cross-Story Dependencies and Impact

| Story | Dependency | Impact |
|---|---|---|
| **Story 1.1** (ZTWIM Operator) | Prerequisite — operator must be installed | SPIRE Server CRDs must exist |
| **Story 1.2** (ZTWIM Instance) | Prerequisite — SpireServer must be running | x509pop patching targets the running SpireServer |
| **Story 1.3** (Vault on etl7) | Prerequisite — Vault must be deployed and initialized | vault-agent authenticates to this Vault instance |
| **Story 1.4** (vault-config-operator) | Prerequisite — VCO must be running | VCO reconciles the trust config CRDs |
| **Story 1.5** (SPIRE↔Vault Trust) | Prerequisite — JWT auth and KV2 secret must be configured | vault-agent uses `auth/spire-jwt` path and reads `secret/data/experiment/demo` |
| **Story 1.6a** (Bootc image) | Prerequisite — bootc image must be built | This story converts it to QCOW2 and deploys it |
| **Story 1.6b** (SPIRE Agent + Helper config) | Prerequisite — configs must be finalized in bootc image | `agent.conf` and `helper.conf` must have correct placeholder patterns for sed replacement |
| **Story 1.6c** (Vault Agent + httpd config) | Prerequisite — configs must be finalized in bootc image | `agent.hcl` must have `PLACEHOLDER_CLUSTER_BASE_DOMAIN` for sed replacement |

**This is the final story in the epic — all previous stories must be complete before end-to-end verification can succeed.**

### Post-Deployment Manual Steps Summary

After ArgoCD syncs the manifests, the following manual steps are required:

1. **Wait for DataVolume import** — CDI imports the QCOW2 from quay.io (may take 5-10 minutes)
2. **Wait for VM boot** — check `oc get vmi -n spire-vault-demo`
3. **Enable SPIRE Server x509pop** — run the create-only mode patching procedure (documented above)
4. **Create SPIRE registration entries** — run the `spire-server entry create` commands (documented above)
5. **Verify end-to-end** — follow the verification procedure

These manual steps are acceptable for an experiment. A production implementation would automate them via Jobs or Operators.

### Known Risks and Open Questions

1. **bootc-image-builder requires privileged execution** — the QCOW2 conversion step needs `--privileged` and `--security-opt label=type:unconfined_t`. This cannot run in a standard CI pipeline without elevated privileges. Document this as a manual build step.

2. **SPIRE Server ConfigMap structure may differ** — the exact ConfigMap key and config format depends on ZTWIM v1.1.0's implementation. The patching procedure may need adjustment based on the actual ConfigMap structure. Verify by inspecting `oc get configmap spire-server -n zero-trust-workload-identity-manager -o yaml` after Story 1.2 deploys.

3. **Vault TLS verification** — using `VAULT_SKIP_VERIFY=true` is a security trade-off acceptable for the experiment. Document this as a known limitation.

4. **DataVolume import from quay.io** — requires the cluster to have network access to quay.io and valid pull credentials. If the image is in a private quay.io repository, a pull secret must be configured in the `spire-vault-demo` namespace.

5. **QCOW2 size and storage** — the 20Gi PVC request should be sufficient for the RHEL 10 bootc image. If the QCOW2 is larger, increase the storage request.

6. **Quadlet container image pulls at first boot** — the four Quadlet containers (`spire-agent`, `spiffe-helper`, `vault-agent`, `httpd`) pull OCI images from `ghcr.io`, `docker.io`, and `registry.access.redhat.com` at first boot. The VM must have network access to these registries. If any pull fails, check `podman logs <container>` and `journalctl -u <container>.service`.

7. **bound_subject alignment** — the SPIFFE ID used in the registration entry (`spiffe://etl7.ocp.rht-labs.com/spire-vault-demo/workload`) must exactly match the `bound_subject` in Story 5's Vault JWT role. If Story 5 used a different value, update either the registration entry or the Vault role.

### Project Structure After This Story

```
clusters/etl7/overlays/spire-vault-demo/
├── image/                          ← Story 6a (bootc image build context)
│   ├── Containerfile
│   └── files/
│       └── etc/
│           ├── containers/systemd/
│           │   ├── spire-agent.container
│           │   ├── spiffe-helper.container
│           │   ├── vault-agent.container
│           │   └── httpd.container
│           ├── spire/agent.conf
│           ├── spiffe-helper/helper.conf
│           └── vault-agent/agent.hcl
├── namespace.yaml                  ← This story
├── self-signed-issuer.yaml         ← This story
├── spire-bootstrap-ca.yaml         ← This story
├── spire-bootstrap-ca-issuer.yaml  ← This story
├── spire-bootstrap-cert.yaml       ← This story
├── virtual-machine.yaml            ← This story
├── service.yaml                    ← This story
├── route.yaml                      ← This story
├── kustomization.yaml              ← This story (or updated from Story 6a)
└── readme.md                       ← Story 6a (update with deployment steps)
```

### References

- [Build and deploy image mode for RHEL on OpenShift Virtualization](https://developers.redhat.com/articles/2024/11/11/deploy-image-mode-rhel-openshift-virtualization) — bootc → QCOW2 → containerDisk pipeline
- [RHEL 10 bootc-image-builder docs](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems/creating-bootc-compatible-base-disk-images-by-using-bootc-image-builder) — QCOW2 conversion
- [KubeVirt container disks](https://docs.okd.io/latest/virt/creating_vms_advanced/virt-creating-vms-from-container-disks.html) — containerDisk and DataVolume with registry source
- [KubeVirt cloud-init with secrets](https://github.com/kubevirt/kubevirt/blob/main/docs/cloud-init.md) — Secret-backed disks and cloud-init patterns
- [OCP 4.22 ZTWIM docs](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/security_and_compliance/zero-trust-workload-identity-manager) — SpireServer x509pop limitations
- [Sky Computing Part 2 — x509pop on ZTWIM](https://developers.redhat.com/blog/2026/04/23/sky-computing-openshift-service-mesh-spire-multicloud-integration) — create-only mode and x509pop patching procedure
- [SPIRE Controller Manager — ClusterStaticEntry](https://github.com/openshift/spiffe-spire-controller-manager/blob/main/docs/clusterstaticentry-crd.md) — static registration entries for non-pod workloads
- [SPIRE x509pop agent plugin](https://github.com/spiffe/spire/blob/main/doc/plugin_agent_nodeattestor_x509pop.md) — attestation requirements
- [SPIRE x509pop server plugin](https://github.com/spiffe/spire/blob/main/doc/plugin_server_nodeattestor_x509pop.md) — server-side CA bundle configuration
- [Vault Agent JWT auto-auth](https://developer.hashicorp.com/vault/docs/agent-and-proxy/autoauth/methods/jwt) — JWT method config reference
- [Source: epic-zero-trust-secret-delivery-etl7.md — Story 1.6d]
- [Pattern reference: clusters/etl6/overlays/vm-tests/fedora-vms.yaml] — VirtualMachine CR patterns in this repo
- [Pattern reference: clusters/etl6/overlays/sm-on-udn/vms.yaml] — VM with cloud-init runcmd and Service
- [Pattern reference: clusters/hub/overlays/soteria-root-cert/] — cert-manager self-signed CA chain pattern

## Dev Agent Record

### Agent Model Used



### Debug Log References

### Completion Notes List

### File List
