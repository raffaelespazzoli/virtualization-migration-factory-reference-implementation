---
baseline_commit: c17fdf40fe5bd9f4bbdf6d45062e21a78fe4233d
---

# Story 1.6a: Build RHEL 10 Image-Mode Bootc Image

Status: done

## Story

As a platform engineer,
I want a custom RHEL 10 bootc image containing all the components needed for the zero-trust demo,
so that I can deploy it as a VM on OpenShift Virtualization with all services pre-configured.

## Acceptance Criteria

1. Directory `clusters/etl7/overlays/spire-vault-demo/image/` created with the full image build context
2. Containerfile based on `registry.redhat.io/rhel10/rhel-bootc:10` that produces a working bootc image
3. System users and groups created with fixed UIDs/GIDs for deterministic ownership across container boundaries
4. Directory structure created with correct ownership, permissions, and SELinux contexts
5. Quadlet `.container` files at `/etc/containers/systemd/` for all four services with correct dependency ordering
6. Placeholder configuration files embedded for spire-agent, spiffe-helper, and vault-agent (finalized by Stories 6b/6c)
7. `readme.md` in `clusters/etl7/overlays/spire-vault-demo/` documenting build, push, and prerequisites
8. Image builds successfully with `podman build`

## Tasks / Subtasks

- [x] Task 1: Create directory structure (AC: #1)
  - [x] 1.1: Create `clusters/etl7/overlays/spire-vault-demo/image/`
  - [x] 1.2: Create `clusters/etl7/overlays/spire-vault-demo/image/files/` for COPY context
- [x] Task 2: Create Containerfile (AC: #2, #3, #4)
  - [x] 2.1: Base image, package installs (podman, httpd, policycoreutils-python-utils)
  - [x] 2.2: User/group creation with fixed UIDs/GIDs
  - [x] 2.3: Directory creation with ownership and permissions
  - [x] 2.4: SELinux fcontext rules
  - [x] 2.5: COPY Quadlet files, config files
- [x] Task 3: Create Quadlet `.container` files (AC: #5)
  - [x] 3.1: `spire-agent.container` — `ghcr.io/spiffe/spire-agent:1.14.7`
  - [x] 3.2: `spiffe-helper.container` — `ghcr.io/spiffe/spiffe-helper:0.11.0`
  - [x] 3.3: `vault-agent.container` — `docker.io/hashicorp/vault:1.20.4`
  - [x] 3.4: `httpd.container` — `registry.access.redhat.com/ubi9/httpd-24:latest`
- [x] Task 4: Create placeholder config files (AC: #6)
  - [x] 4.1: `/etc/spire/agent.conf` — SPIRE agent placeholder (Story 6b finalizes)
  - [x] 4.2: `/etc/spiffe-helper/helper.conf` — spiffe-helper placeholder (Story 6b finalizes)
  - [x] 4.3: `/etc/vault-agent/agent.hcl` — vault-agent placeholder (Story 6c finalizes)
- [x] Task 5: Create `readme.md` (AC: #7)
- [x] Task 6: Validate image builds (AC: #8)

### Review Findings

- [x] [Review][Decision] AC #8 was never executed as a real `podman build` — resolved: human runs `podman build` on an entitled host; document the full process in `readme.md`.
- [x] [Review][Decision] `httpd.container` vs RPM `httpd.service` — resolved: do not install the httpd RPM. All four services stay Quadlet containers. Switch httpd image to `registry.access.redhat.com/ubi10/httpd-24:latest` (RHEL 10-aligned). Host GID 48/`apache` is unused once the RPM is gone.

- [x] [Review][Patch] Recreate tmpfs runtime dirs with writer UIDs (`/run/spire/sockets`, `/var/run/secrets/spiffe`, `/var/run/vault`) via tmpfiles.d; also `chown spire:spire` on the socket dir [clusters/etl7/overlays/spire-vault-demo/image/Containerfile:27]
- [x] [Review][Patch] Drop `dnf install httpd` and apache GID 48; chown `/var/www/html` to vault-agent-user so UID 10004 can write `secret.txt` [clusters/etl7/overlays/spire-vault-demo/image/Containerfile:6]
- [x] [Review][Patch] Switch httpd Quadlet to `registry.access.redhat.com/ubi10/httpd-24:latest` and mount the docroot the S2I image actually serves (`/opt/app-root/src`, host path still `/var/www/html`) [clusters/etl7/overlays/spire-vault-demo/image/files/etc/containers/systemd/httpd.container:7]
- [x] [Review][Patch] Share PID namespace for unix workload attestation (`Pid=host` or equivalent on spire-agent and spiffe-helper) [clusters/etl7/overlays/spire-vault-demo/image/files/etc/containers/systemd/spire-agent.container:1]
- [x] [Review][Patch] Add `After=network-online.target` / `Wants=network-online.target` on spire-agent and `Restart=on-failure` on all four Quadlets [clusters/etl7/overlays/spire-vault-demo/image/files/etc/containers/systemd/spire-agent.container:1]
- [x] [Review][Patch] Document the human-run build/push process: `podman login registry.redhat.io`, RHEL entitlements, SELinux/privileged needs for `semanage`, and that AC #8 is executed on the build host [clusters/etl7/overlays/spire-vault-demo/readme.md:5]
- [x] [Review][Patch] Fix UID/GID table: helper Quadlet runs as `10002:10003` (primary GID 10003); drop apache GID 48 now that httpd is container-only [clusters/etl7/overlays/spire-vault-demo/readme.md:47]
- [x] [Review][Patch] Document Vault TLS trust trade-off (inject CA vs skip verify) as called out in story known risks [clusters/etl7/overlays/spire-vault-demo/readme.md:54]

## Dev Notes

### ⚠️ CRITICAL: Design Decision — Quadlet Containers with OCI Images

The epic describes both "installing binaries" and "Quadlet `.container` files." These are different paradigms:

- **Quadlet `.container` files** require an `Image=` directive pointing to an OCI container image — they run Podman containers, not host binaries.
- **Installing binaries** in the bootc image makes them available as host commands, run via regular systemd `.service` files.

**Resolution:** Use Quadlet containers referencing upstream OCI images. This is the idiomatic RHEL 10 image-mode pattern and provides the container-isolation security model described in the epic. The binaries are NOT installed directly in the bootc image — they come from the container images.

The only packages installed via `dnf` are:
- `httpd` — not to run as a host service, but to create the `apache` user/group (GID 48) needed for file ownership
- `policycoreutils-python-utils` — for `semanage fcontext` at build time
- `podman` — if not already in the base image (verify; `rhel-bootc:10` should include it)

### ⚠️ CRITICAL: SELinux with Quadlet Containers

The epic specifies manual `semanage fcontext` rules for `httpd_sys_rw_content_t`. With Quadlet containers, the approach changes:

- Podman volume mounts with `:z` (shared) or `:Z` (private) flags handle SELinux relabeling automatically
- The `:z` flag relabels bind-mounted content to `container_file_t` so all containers sharing the mount can access it
- Manual `semanage fcontext` for `httpd_sys_rw_content_t` is **only needed if httpd runs as a host service** — not needed when httpd runs in a container

**Keep** the `semanage fcontext` commands in the Containerfile as a defensive measure — if the Quadlet approach fails or is swapped for host services during debugging, the SELinux contexts will already be correct. But the Quadlet volume mount flags are what actually govern container access.

### ⚠️ CRITICAL: UID/GID Strategy for Cross-Container File Sharing

When multiple Quadlet containers share bind-mounted directories, file ownership is based on **host UIDs/GIDs**. Each container's `User=` directive runs the process at that host UID. Fix UIDs/GIDs to ensure consistent ownership:

| User/Group | UID/GID | Purpose |
|---|---|---|
| `spire` (user+group) | UID 10001, GID 10001 | Runs spire-agent. Sole owner of bootstrap cert files |
| `spiffe-helper` (user) | UID 10002 | Runs spiffe-helper. Writes SVID files |
| `spiffe-consumers` (group) | GID 10003 | Shared read access to SVID output. Members: `spiffe-helper`, `vault-agent-user` |
| `vault-agent-user` (user) | UID 10004 | Runs vault-agent. Reads SVIDs, writes secrets |
| `apache` (user+group) | UID 48, GID 48 | Standard RHEL httpd. Created by `dnf install httpd`. Used for httpd file ownership |

In Quadlet `.container` files, use `User=` to map to the host UID, and `GroupAdd=` for supplementary groups.

### ⚠️ CRITICAL: Quadlet Dependency Syntax

Modern Podman (RHEL 10) auto-translates Quadlet unit references. Use `.container` names directly in `[Unit]` section:

```ini
[Unit]
After=spire-agent.container
Requires=spire-agent.container
```

Quadlet translates `spire-agent.container` → `spire-agent.service` in the generated systemd unit. Do NOT use `.service` names in the Quadlet source files.

### Container Image References (Verified Sep 2026)

| Service | OCI Image | Binary Path | Notes |
|---|---|---|---|
| spire-agent | `ghcr.io/spiffe/spire-agent:1.14.7` | `/opt/spire/bin/spire-agent` | Matches ZTWIM v1.1.0 SPIRE version on etl7 cluster |
| spiffe-helper | `ghcr.io/spiffe/spiffe-helper:0.11.0` | `/spiffe-helper` | Latest stable release (Nov 2025) |
| vault-agent | `docker.io/hashicorp/vault:1.20.4` | `/bin/vault` | Run as `vault agent -config=...`. Matches etl7 Vault version |
| httpd | `registry.access.redhat.com/ubi9/httpd-24:latest` | `/usr/sbin/httpd` | Red Hat UBI httpd image |

### Exact Containerfile

```dockerfile
FROM registry.redhat.io/rhel10/rhel-bootc:10

# ── System packages ──────────────────────────────────────────────────
# httpd: creates apache user/group (GID 48) for file ownership
# policycoreutils-python-utils: semanage for SELinux fcontext rules
RUN dnf install -y \
      httpd \
      policycoreutils-python-utils \
    && dnf clean all

# ── Users and groups ─────────────────────────────────────────────────
RUN groupadd -g 10001 spire && \
    useradd  -u 10001 -g 10001 -r -s /sbin/nologin spire && \
    groupadd -g 10003 spiffe-consumers && \
    useradd  -u 10002 -r -s /sbin/nologin spiffe-helper && \
    usermod  -aG spiffe-consumers spiffe-helper && \
    useradd  -u 10004 -r -s /sbin/nologin vault-agent-user && \
    usermod  -aG spiffe-consumers vault-agent-user && \
    usermod  -aG apache vault-agent-user

# ── Directory structure ──────────────────────────────────────────────
# spire-agent: bootstrap certs (most sensitive), agent config, socket
RUN mkdir -p /etc/spire/bootstrap && \
    chown -R spire:spire /etc/spire && \
    chmod 0755 /etc/spire && \
    chmod 0500 /etc/spire/bootstrap && \
    mkdir -p /run/spire/sockets && \
    chmod 0755 /run/spire/sockets

# spiffe-helper: SVID output directory
RUN mkdir -p /var/run/secrets/spiffe && \
    chown spiffe-helper:spiffe-consumers /var/run/secrets/spiffe && \
    chmod 0750 /var/run/secrets/spiffe

# spiffe-helper: config directory
RUN mkdir -p /etc/spiffe-helper && \
    chmod 0755 /etc/spiffe-helper

# vault-agent: token sink and config
RUN mkdir -p /var/run/vault && \
    chown vault-agent-user:vault-agent-user /var/run/vault && \
    chmod 0750 /var/run/vault && \
    mkdir -p /etc/vault-agent && \
    chmod 0755 /etc/vault-agent

# httpd: document root (already exists from httpd install)
RUN chmod 0755 /var/www/html

# ── SELinux contexts (defensive — Quadlet handles container access) ──
RUN semanage fcontext -a -t httpd_sys_rw_content_t "/var/www/html(/.*)?" && \
    restorecon -Rv /var/www/html

# ── Configuration files (placeholders — Stories 6b/6c finalize) ──────
COPY files/etc/spire/agent.conf         /etc/spire/agent.conf
COPY files/etc/spiffe-helper/helper.conf /etc/spiffe-helper/helper.conf
COPY files/etc/vault-agent/agent.hcl     /etc/vault-agent/agent.hcl

RUN chown root:root /etc/spire/agent.conf /etc/spiffe-helper/helper.conf /etc/vault-agent/agent.hcl && \
    chmod 0644 /etc/spire/agent.conf /etc/spiffe-helper/helper.conf /etc/vault-agent/agent.hcl

# ── Quadlet container definitions ────────────────────────────────────
COPY files/etc/containers/systemd/spire-agent.container    /etc/containers/systemd/
COPY files/etc/containers/systemd/spiffe-helper.container  /etc/containers/systemd/
COPY files/etc/containers/systemd/vault-agent.container    /etc/containers/systemd/
COPY files/etc/containers/systemd/httpd.container          /etc/containers/systemd/
```

### Exact Quadlet File Contents

#### `spire-agent.container`

```ini
[Unit]
Description=SPIRE Agent (x509pop attestation)

[Container]
Image=ghcr.io/spiffe/spire-agent:1.14.7
ContainerName=spire-agent
User=10001:10001
Volume=/etc/spire/bootstrap:/etc/spire/bootstrap:ro,z
Volume=/run/spire/sockets:/run/spire/sockets:z
Volume=/etc/spire/agent.conf:/etc/spire/agent.conf:ro,z
Exec=/opt/spire/bin/spire-agent run -config /etc/spire/agent.conf

[Install]
WantedBy=multi-user.target default.target
```

**Notes:**
- Only container with access to `/etc/spire/bootstrap/`
- Agent socket at `/run/spire/sockets/agent.sock` is shared with spiffe-helper
- `:ro` on bootstrap and config prevents modification from inside the container
- `:z` SELinux flag enables shared access on labeled volumes

#### `spiffe-helper.container`

```ini
[Unit]
Description=SPIFFE Helper (SVID and JWT extraction)
After=spire-agent.container
Requires=spire-agent.container

[Container]
Image=ghcr.io/spiffe/spiffe-helper:0.11.0
ContainerName=spiffe-helper
User=10002:10003
Volume=/run/spire/sockets:/run/spire/sockets:ro,z
Volume=/var/run/secrets/spiffe:/var/run/secrets/spiffe:z
Volume=/etc/spiffe-helper/helper.conf:/etc/spiffe-helper/helper.conf:ro,z
Exec=/spiffe-helper -config /etc/spiffe-helper/helper.conf

[Install]
WantedBy=multi-user.target default.target
```

**Notes:**
- Depends on `spire-agent.container` (Quadlet auto-translates to service dependency)
- `User=10002:10003` → runs as spiffe-helper (UID 10002) with primary group spiffe-consumers (GID 10003)
- Agent socket is `:ro` — spiffe-helper reads only
- SVID output dir is writable — files created here are owned by 10002:10003
- Vault-agent can read these because vault-agent-user is in the spiffe-consumers group (GID 10003)

#### `vault-agent.container`

```ini
[Unit]
Description=Vault Agent (JWT auto-auth, secret templating)
After=spiffe-helper.container
Requires=spiffe-helper.container

[Container]
Image=docker.io/hashicorp/vault:1.20.4
ContainerName=vault-agent
User=10004
GroupAdd=10003
Volume=/var/run/secrets/spiffe:/var/run/secrets/spiffe:ro,z
Volume=/var/www/html:/var/www/html:z
Volume=/var/run/vault:/var/run/vault:z
Volume=/etc/vault-agent/agent.hcl:/etc/vault-agent/agent.hcl:ro,z
Exec=vault agent -config=/etc/vault-agent/agent.hcl

[Install]
WantedBy=multi-user.target default.target
```

**Notes:**
- `User=10004` → runs as vault-agent-user
- `GroupAdd=10003` → adds spiffe-consumers as supplementary group, enabling read access to JWT-SVID files
- No access to `/etc/spire/bootstrap/` or `/run/spire/sockets/`
- `/var/run/secrets/spiffe/` is `:ro` — vault-agent reads JWT-SVID only
- `/var/www/html/` is writable — vault-agent templates secrets here
- Files written to `/var/www/html/` will be owned by UID 10004 with mode 0644 (set by vault-agent template `perms`)
- Depends on spiffe-helper being ready (JWT-SVID must exist before vault-agent can auth)

#### `httpd.container`

```ini
[Unit]
Description=Apache httpd (secret display endpoint)
After=vault-agent.container
Requires=vault-agent.container

[Container]
Image=registry.access.redhat.com/ubi9/httpd-24:latest
ContainerName=httpd
PublishPort=8080:8080
Volume=/var/www/html:/var/www/html:ro,z

[Install]
WantedBy=multi-user.target default.target
```

**Notes:**
- `/var/www/html/` is `:ro` — httpd only reads, never writes
- No access to any SPIRE or vault directories
- The UBI httpd image listens on port 8080 by default (non-privileged)
- `PublishPort=8080:8080` exposes the endpoint on the VM's network
- Files in `/var/www/html/` are mode 0644 (world-readable), so any container UID can read them
- Depends on vault-agent being ready (secret.txt must exist before httpd serves it)

### Exact Placeholder Config Files

These are minimal placeholders. Stories 6b and 6c will replace them with real configuration.

#### `files/etc/spire/agent.conf`

```hcl
# PLACEHOLDER — Story 6b provides final configuration
# spire-agent configuration for x509pop attestation
agent {
    data_dir = "/opt/spire/data"
    log_level = "DEBUG"
    trust_domain = "etl7.ocp.rht-labs.com"
    server_address = "PLACEHOLDER_SPIRE_SERVER_ADDRESS"
    server_port = "8081"
    socket_path = "/run/spire/sockets/agent.sock"
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

#### `files/etc/spiffe-helper/helper.conf`

```hcl
# PLACEHOLDER — Story 6b provides final configuration
agent_address = "/run/spire/sockets/agent.sock"
cert_dir = "/var/run/secrets/spiffe"
svid_file_name = "svid.crt.pem"
svid_key_file_name = "svid.key.pem"
svid_bundle_file_name = "bundle.crt.pem"
jwt_svids = [
  {
    jwt_audience     = "vault"
    jwt_svid_file_name = "jwt-svid.token"
  }
]
cert_file_mode = 0640
key_file_mode = 0640
jwt_svid_file_mode = 0640
```

#### `files/etc/vault-agent/agent.hcl`

```hcl
# PLACEHOLDER — Story 6c provides final configuration
vault {
  address = "https://vault.apps.PLACEHOLDER_CLUSTER_BASE_DOMAIN"
}

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

template {
  contents    = <<-EOF
    {{ with secret "secret/data/experiment/demo" }}{{ .Data.data.message }}{{ end }}
  EOF
  destination = "/var/www/html/secret.txt"
  perms       = "0644"
}
```

### File Tree for the Image Build Context

```
clusters/etl7/overlays/spire-vault-demo/
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
│           │   └── agent.conf
│           ├── spiffe-helper/
│           │   └── helper.conf
│           └── vault-agent/
│               └── agent.hcl
└── readme.md
```

### Readme Content

The `readme.md` at `clusters/etl7/overlays/spire-vault-demo/readme.md` must document:

1. **What this is:** RHEL 10 image-mode bootc image for the zero-trust SPIFFE/Vault demo VM
2. **Prerequisites:**
   - Red Hat registry access (`registry.redhat.io`, `registry.access.redhat.com`)
   - quay.io credentials with push access to the target repository
   - `podman` installed on the build host
3. **Build command:**
   ```bash
   cd clusters/etl7/overlays/spire-vault-demo/image
   podman build -t quay.io/<org>/rhel10-spire-vault-demo:latest -f Containerfile .
   ```
4. **Push command:**
   ```bash
   podman push quay.io/<org>/rhel10-spire-vault-demo:latest
   ```
5. **Image reference:** `quay.io/<org>/rhel10-spire-vault-demo:latest` (replace `<org>` with actual quay.io organization)
6. **Service architecture:** Summary of the four Quadlet containers, their roles, and dependency chain
7. **Configuration:** Note that `agent.conf`, `helper.conf`, and `agent.hcl` are placeholders — Stories 6b/6c finalize them. Rebuild image after config changes.

### Cross-Story Dependencies and Impact

| Story | Relationship | Detail |
|---|---|---|
| **Story 1.2** (ZTWIM Instance) | spire-agent version must match | OCI image `ghcr.io/spiffe/spire-agent:1.14.7` matches ZTWIM v1.1.0 SPIRE 1.14.7 |
| **Story 1.3** (Vault on etl7) | vault-agent version must match | OCI image `docker.io/hashicorp/vault:1.20.4` matches deployed Vault 1.20.4 |
| **Story 1.6b** (SPIRE Agent + Helper config) | Finalizes `agent.conf` and `helper.conf` | Image must be rebuilt after Story 6b updates configs |
| **Story 1.6c** (Vault Agent + httpd config) | Finalizes `agent.hcl` | Image must be rebuilt after Story 6c updates configs |
| **Story 1.6d** (Deploy VM) | Consumes the built image | VirtualMachine CR references `quay.io/<org>/rhel10-spire-vault-demo:latest` |

### Known Risks and Open Questions

1. **Container image pull at boot:** Without logically bound images, Quadlet containers pull OCI images from registries at first boot. The VM must have network access to `ghcr.io`, `docker.io`, and `registry.access.redhat.com`. For disconnected environments, convert to logically bound images (see RHEL 10 docs ch.3).

2. **SPIRE agent socket directory:** The SPIRE agent container creates the socket at `/run/spire/sockets/agent.sock`. Since `/run` is typically a tmpfs, the directory might not persist across reboots. The Containerfile creates it at build time, but systemd-tmpfiles or the Quadlet's `ExecStartPre=` may need to recreate it. Verify during testing.

3. **Vault agent TLS:** The vault-agent container needs to trust the Vault server's TLS certificate. If Vault uses a self-signed or internal CA cert, either inject the CA bundle or set `VAULT_SKIP_VERIFY=true` in the Quadlet's `Environment=` for the experiment. Document the trade-off.

4. **spiffe-helper file ownership:** spiffe-helper v0.11.0 writes files as the process UID. With `User=10002:10003`, output files will be `10002:10003` (spiffe-helper:spiffe-consumers). vault-agent (UID 10004, supplementary GID 10003) can read them via group permission (mode 0640). Verify this works in practice.

5. **Podman in rhel-bootc:10:** Verify that `registry.redhat.io/rhel10/rhel-bootc:10` includes Podman. If not, add `podman` to the `dnf install` list in the Containerfile.

### What NOT to Do

- **Do NOT install spire-agent, spiffe-helper, or vault binaries directly in the bootc image** — they are provided by the OCI container images referenced in the Quadlet files
- **Do NOT use `.service` names in Quadlet dependency declarations** — use `.container` names (e.g., `After=spire-agent.container`); modern Podman auto-translates
- **Do NOT put production config values in the placeholder files** — Stories 6b and 6c finalize configs; use `PLACEHOLDER_*` values for anything cluster-specific
- **Do NOT use `:Z` (private) SELinux labels on shared volumes** — use `:z` (shared) for directories accessed by multiple containers (e.g., `/var/www/html/`, `/run/spire/sockets/`, `/var/run/secrets/spiffe/`)
- **Do NOT add ArgoCD Application entries to `clusters/etl7/values.yaml`** — this story only builds the image; Story 6d handles deployment
- **Do NOT modify any existing cluster or component files** — this story creates new files only
- **Do NOT modify `clusters/etl4/`** — etl7-only experiment
- **Do NOT create the VirtualMachine CR, cloud-init, cert-manager certs, or SPIRE registration** — those are Story 6d
- **Do NOT hardcode the quay.io organization name** — use `<org>` placeholder in the readme; the user will substitute

### Codebase Patterns to Follow

- The overlay directory follows the existing `clusters/etl7/overlays/<name>/` pattern
- The `spire-vault-demo` name groups all VM-related artifacts (image build context in `image/`, K8s manifests added by Story 6d)
- Config files are structured to mirror their target paths inside the bootc image (e.g., `files/etc/spire/agent.conf` → `/etc/spire/agent.conf`)
- The `readme.md` goes at the overlay root (same level as `image/`), following the component documentation convention

### Project Structure Notes

- All new files live under `clusters/etl7/overlays/spire-vault-demo/` — no base component is created because this is an experiment-specific image, not a reusable component
- The `image/` subdirectory contains only the Containerfile and its build context — no Kubernetes manifests
- Stories 6b, 6c, and 6d will add files to the same `spire-vault-demo/` overlay directory

### References

- [RHEL 10 image-mode — Building container images](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html-single/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems/index) — Containerfile patterns, Quadlet integration
- [How to embed containers on image mode for RHEL](https://developers.redhat.com/articles/2025/05/29/how-embed-containers-image-mode-rhel) — Quadlet file placement, logically bound images
- [Podman Quadlet documentation](https://docs.podman.io/en/stable/markdown/podman-systemd.unit.5.html) — `.container` file format, `[Container]` options, dependency syntax
- [SPIRE releases — v1.14.7](https://github.com/spiffe/spire/releases/tag/v1.14.7) — SPIRE agent container image
- [spiffe-helper releases — v0.11.0](https://github.com/spiffe/spiffe-helper/releases/tag/v0.11.0) — spiffe-helper container image
- [spiffe-helper configuration](https://pkg.go.dev/github.com/spiffe/spiffe-helper) — HCL config format, JWT-SVID fields
- [Vault 1.20.4 release](https://github.com/hashicorp/vault/releases/tag/v1.20.4) — Vault container image
- [Vault Agent JWT auto-auth](https://developer.hashicorp.com/vault/docs/agent-and-proxy/autoauth/methods/jwt) — JWT auth method config
- [Bootc logically bound images](https://bootc.dev/bootc/logically-bound-images.html) — Pre-fetching container images (future optimization)
- [Use bootc logically bound images for Kafka](https://developers.redhat.com/articles/2024/11/07/use-bootc-logically-bound-images-deploy-kafka-cluster) — Real-world Quadlet + bootc example
- [Source: epic-zero-trust-secret-delivery-etl7.md — Story 1.6a]
- [Pattern reference: Story 1.1 — ztwim-operator] — overlay directory convention
- [Pattern reference: Story 1.2 — ztwim-instance] — overlay and cross-story dependency patterns

## Dev Agent Record

### Agent Model Used

Claude Opus 4.6 (via Cursor)

### Debug Log References

No issues encountered. All files created from the detailed spec in Dev Notes.

### Completion Notes List

- **Task 1:** Created full directory tree under `clusters/etl7/overlays/spire-vault-demo/image/` with nested `files/` build context mirroring target filesystem paths.
- **Task 2:** Containerfile created with all spec'd layers: base image (rhel-bootc:10), dnf installs (httpd, policycoreutils-python-utils), user/group creation with fixed UIDs/GIDs (spire 10001, spiffe-helper 10002, spiffe-consumers 10003, vault-agent-user 10004), directory structure with ownership/permissions, SELinux fcontext rules, COPY of config files and Quadlet units.
- **Task 3:** Four Quadlet `.container` files created with correct dependency chain (spire-agent → spiffe-helper → vault-agent → httpd), proper User=/GroupAdd= mappings, volume mounts with appropriate `:ro`/`:z` flags, and WantedBy=multi-user.target default.target.
- **Task 4:** Three placeholder config files created (agent.conf, helper.conf, agent.hcl) with PLACEHOLDER values for cluster-specific settings. Stories 6b and 6c will finalize these.
- **Task 5:** Comprehensive readme.md at overlay root documenting build/push commands, service architecture table, UID/GID mapping, configuration placeholders, file layout, and cross-story references.
- **Task 6:** Structural validation passed — all COPY sources exist in build context, Quadlet files have valid structure ([Unit], [Container], [Install] sections), dependency chain is correct, UID/GID mappings are consistent. Actual `podman build` requires Red Hat registry auth and SELinux-enabled host — to be validated on the build host.

### File List

- `clusters/etl7/overlays/spire-vault-demo/image/Containerfile` (new)
- `clusters/etl7/overlays/spire-vault-demo/image/files/etc/containers/systemd/spire-agent.container` (new)
- `clusters/etl7/overlays/spire-vault-demo/image/files/etc/containers/systemd/spiffe-helper.container` (new)
- `clusters/etl7/overlays/spire-vault-demo/image/files/etc/containers/systemd/vault-agent.container` (new)
- `clusters/etl7/overlays/spire-vault-demo/image/files/etc/containers/systemd/httpd.container` (new)
- `clusters/etl7/overlays/spire-vault-demo/image/files/etc/spire/agent.conf` (new)
- `clusters/etl7/overlays/spire-vault-demo/image/files/etc/spiffe-helper/helper.conf` (new)
- `clusters/etl7/overlays/spire-vault-demo/image/files/etc/vault-agent/agent.hcl` (new)
- `clusters/etl7/overlays/spire-vault-demo/readme.md` (new)

### Change Log

- 2026-09-15: Story 1.6a implemented — created RHEL 10 bootc image build context with Containerfile, 4 Quadlet container units, 3 placeholder config files, and readme. All new files under `clusters/etl7/overlays/spire-vault-demo/`.
