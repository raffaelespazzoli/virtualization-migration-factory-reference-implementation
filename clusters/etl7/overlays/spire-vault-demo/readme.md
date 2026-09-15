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

The following config files are **placeholders** embedded in the image:

| File | Finalized By |
|---|---|
| `/etc/spire/agent.conf` | Story 1.6b |
| `/etc/spiffe-helper/helper.conf` | Story 1.6b |
| `/etc/vault-agent/agent.hcl` | Story 1.6c |

After updating configuration files, rebuild and push the image.

## File Layout

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
