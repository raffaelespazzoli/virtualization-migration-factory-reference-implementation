# Story 1.6c: Configure Vault Agent and httpd on the VM

Status: ready-for-dev

## Story

As a platform engineer,
I want vault-agent on the VM to automatically authenticate to Vault using the SPIRE-issued JWT-SVID and serve the retrieved secret via httpd,
so that the end-to-end zero-trust secret delivery is demonstrated.

## Acceptance Criteria

1. Vault Agent configuration (`/etc/vault-agent/agent.hcl`) finalized with JWT auto-auth pointing to the SPIRE-issued JWT-SVID
2. JWT auto-auth uses mount path `auth/spire-jwt`, role `spire-vm-role`, and reads JWT from `/var/run/secrets/spiffe/jwt-svid.token`
3. Template stanza reads KV2 secret at `secret/data/experiment/demo` and writes `message` value to `/var/www/html/secret.txt`
4. `enable_reauth_on_new_credentials = true` for automatic re-auth on JWT-SVID rotation
5. TLS trust for the Vault server's Route CA is handled (either CA bundle injection or documented `VAULT_SKIP_VERIFY=true` trade-off)
6. vault-agent runs as `vault-agent-user` (UID 10004, member of `spiffe-consumers` GID 10003) — already configured by Story 6a's Quadlet
7. Written files at `/var/www/html/` are mode `0644` (world-readable) so the httpd container can serve them
8. httpd Quadlet container serves `/secret.txt` at port 8080 — already configured by Story 6a, verify no additional httpd configuration is needed
9. Image must be rebuilt after config file changes (`podman build` + `podman push`)

## Tasks / Subtasks

- [ ] Task 1: Finalize `/etc/vault-agent/agent.hcl` (AC: #1, #2, #3, #4, #5)
  - [ ] 1.1: Replace placeholder `agent.hcl` at `clusters/etl7/overlays/spire-vault-demo/image/files/etc/vault-agent/agent.hcl`
  - [ ] 1.2: Configure `vault` stanza with correct address and TLS settings
  - [ ] 1.3: Configure `auto_auth` with JWT method, sink, and `enable_reauth_on_new_credentials`
  - [ ] 1.4: Configure `template` stanza for KV2 secret rendering to `/var/www/html/secret.txt`
  - [ ] 1.5: Configure `template_config` for static secret polling interval
- [ ] Task 2: Handle Vault TLS trust (AC: #5)
  - [ ] 2.1: Determine if Vault Route uses OpenShift default ingress cert or a custom cert
  - [ ] 2.2: If ingress CA is needed, update `vault-agent.container` Quadlet to mount the CA bundle and set `VAULT_CACERT` — OR document `VAULT_SKIP_VERIFY=true` for the experiment
- [ ] Task 3: Verify httpd configuration (AC: #8)
  - [ ] 3.1: Confirm the UBI9 httpd-24 image serves files from `/var/www/html/` on port 8080 by default with no custom config needed
  - [ ] 3.2: If custom httpd.conf is needed, add it to the image build context and Quadlet
- [ ] Task 4: Update Quadlet if needed (AC: #5, #6)
  - [ ] 4.1: If TLS CA injection is chosen, add `Volume=` and `Environment=` directives to `vault-agent.container`
  - [ ] 4.2: If no changes needed, document that Story 6a's Quadlet is sufficient
- [ ] Task 5: Rebuild and push image (AC: #9)
  - [ ] 5.1: Document in readme that image rebuild is required after this story

## Dev Notes

### ⚠️ CRITICAL: This Story Only Modifies One File (Plus Possibly the Quadlet)

The primary deliverable is the finalized `/etc/vault-agent/agent.hcl` configuration file. Story 1-6a already created:
- The `vault-agent.container` Quadlet file (dependency chain, volumes, user mapping)
- The `httpd.container` Quadlet file (port 8080, read-only `/var/www/html/`)
- The placeholder `agent.hcl` with correct structure
- The Containerfile with all users, groups, directories, SELinux contexts

**Do NOT recreate or duplicate any of those files.** Only replace the placeholder content in `agent.hcl` and optionally update the `vault-agent.container` Quadlet for TLS.

### ⚠️ CRITICAL: File Location

The agent.hcl file lives at:
```
clusters/etl7/overlays/spire-vault-demo/image/files/etc/vault-agent/agent.hcl
```

This path is COPYed into the bootc image by the Containerfile at `/etc/vault-agent/agent.hcl`.

### Exact `agent.hcl` Configuration

Replace the placeholder with this finalized configuration:

```hcl
# Vault Agent — JWT auto-auth via SPIRE-issued JWT-SVID
# Authenticates to Vault using SPIFFE identity, templates KV2 secret to httpd docroot

vault {
  address = "https://vault.apps.etl7.ocp.rht-labs.com"
  # TLS: For the experiment, skip verification of Vault's Route TLS cert.
  # Production would inject the OpenShift ingress CA bundle via VAULT_CACERT.
  tls_skip_verify = true
}

auto_auth {
  # Re-authenticate immediately when spiffe-helper writes a new JWT-SVID
  enable_reauth_on_new_credentials = true

  method "jwt" {
    mount_path = "auth/spire-jwt"
    config = {
      path                     = "/var/run/secrets/spiffe/jwt-svid.token"
      role                     = "spire-vm-role"
      remove_jwt_after_reading = false
      jwt_read_period          = "5s"
    }
  }

  sink "file" {
    config = {
      path = "/var/run/vault/token"
    }
  }
}

template_config {
  # KV2 secrets are non-renewable; poll every 30s for changes
  static_secret_render_interval = "30s"
}

template {
  contents    = <<-EOF
    {{ with secret "secret/data/experiment/demo" }}{{ .Data.data.message }}{{ end }}
  EOF
  destination = "/var/www/html/secret.txt"
  perms       = "0644"
}
```

### Key Configuration Decisions Explained

**`tls_skip_verify = true`:**
The Vault Route on etl7 uses the OpenShift default ingress certificate, signed by the cluster's ingress CA. Injecting this CA into the vault-agent container would require:
1. Extracting the ingress CA from the `router-ca` Secret in `openshift-ingress-operator`
2. Making it available to the VM via cloud-init or baking it into the image
3. Mounting it in the vault-agent Quadlet container

For this experiment, `tls_skip_verify = true` is acceptable. The Story 6d implementation notes should document this trade-off and the production path (inject CA bundle).

**`remove_jwt_after_reading = false`:**
spiffe-helper continuously overwrites the JWT-SVID file as it refreshes. If vault-agent deleted it after reading, the next rotation would fail. This MUST be false.

**`jwt_read_period = "5s"`:**
Controls how often vault-agent checks the JWT file for changes. Combined with `enable_reauth_on_new_credentials = true`, vault-agent will re-authenticate within 5 seconds of spiffe-helper writing a new JWT-SVID. Default is `0.5s` when `remove_jwt_after_reading = false`, but 5s reduces unnecessary file reads.

**`static_secret_render_interval = "30s"`:**
KV2 secrets are non-renewable (no lease). Without this setting, vault-agent polls every 5 minutes by default. 30 seconds provides faster feedback during the demo without excessive Vault API calls.

**`perms = "0644"` (not `uid`/`gid`):**
Vault Agent's `template` stanza does NOT support setting file ownership — only permissions (see [hashicorp/vault#31607](https://github.com/hashicorp/vault/issues/31607)). Files will be owned by UID 10004 (vault-agent-user) with whatever primary group the container process has. Since `perms = "0644"` makes files world-readable, the httpd container (running as a different UID) can read them through the shared bind mount. No ownership workaround is needed.

**`mount_path = "auth/spire-jwt"`:**
Must match the `AuthEngineMount` path configured in Story 1.5. The vault-config-operator `AuthEngineMount` CR enables a JWT auth engine at path `spire-jwt`, so the full mount path for vault-agent is `auth/spire-jwt`.

**`role = "spire-vm-role"`:**
Must match the `JWTOIDCAuthEngineRole` name from Story 1.5. The role has `bound_audiences = ["vault"]` matching spiffe-helper's JWT audience, and `token_policies` granting KV2 read access.

### Vault Address — Environment Variable Substitution

The epic uses `${CLUSTER_BASE_DOMAIN}` for ArgoCD-rendered manifests. However, the `agent.hcl` file is baked into the bootc image at build time, NOT rendered by ArgoCD's envsub CMP. Therefore, the Vault address must be hardcoded to the actual domain:

```
https://vault.apps.etl7.ocp.rht-labs.com
```

If the Vault address needs to vary at deploy time, Story 6d could use cloud-init to overwrite the config file or set the `VAULT_ADDR` environment variable in the Quadlet. For this experiment, hardcoding is acceptable since the image is etl7-specific.

### httpd — No Additional Configuration Needed

The `registry.access.redhat.com/ubi9/httpd-24:latest` image:
- Serves files from `/var/www/html/` by default
- Listens on port 8080 (non-privileged)
- No custom `httpd.conf` is required for serving a static `secret.txt` file
- The `PublishPort=8080:8080` in the Quadlet exposes the endpoint on the VM's network

Verify that the default UBI9 httpd-24 image document root is `/var/www/html/` — this is standard for Red Hat httpd images. If the image uses `/opt/app-root/src/` or another path instead, the Quadlet volume mount in Story 6a's `httpd.container` must be updated to match.

### ⚠️ UBI9 httpd-24 Document Root Verification

The Red Hat UBI9 httpd-24 container image (`registry.access.redhat.com/ubi9/httpd-24`) may use a non-standard document root. Red Hat S2I httpd images typically use:
- `/opt/app-root/src/` as the document root (for S2I source builds)
- OR `/var/www/html/` in standard mode

**Action required during implementation:** Pull the image and inspect:
```bash
podman run --rm registry.access.redhat.com/ubi9/httpd-24:latest cat /etc/httpd/conf/httpd.conf | grep DocumentRoot
```

If the document root is NOT `/var/www/html/`, either:
1. Update the `httpd.container` Quadlet volume mount to use the correct path (update in Story 6a's file), OR
2. Add a custom `httpd.conf` that sets `DocumentRoot /var/www/html/`

### Quadlet Changes (Likely None)

If `tls_skip_verify = true` is used in `agent.hcl` (recommended for the experiment), no changes to Story 6a's `vault-agent.container` Quadlet are needed. The `tls_skip_verify` setting is inside the HCL config file, not an environment variable.

If instead you want to use a CA bundle:
```ini
# Additional lines for vault-agent.container (ONLY if using CA bundle instead of tls_skip_verify)
Volume=/etc/pki/vault-ca/ca.crt:/etc/pki/vault-ca/ca.crt:ro,z
Environment=VAULT_CACERT=/etc/pki/vault-ca/ca.crt
```
And remove `tls_skip_verify = true` from `agent.hcl`, replacing with:
```hcl
vault {
  address    = "https://vault.apps.etl7.ocp.rht-labs.com"
  ca_cert    = "/etc/pki/vault-ca/ca.crt"
}
```

### Cross-Story Dependencies and Impact

| Story | Relationship | Detail |
|---|---|---|
| **Story 1.3** (Vault on etl7) | Vault must be running | `agent.hcl` connects to `vault.apps.etl7.ocp.rht-labs.com` |
| **Story 1.5** (SPIRE-Vault Trust) | Auth engine + role must exist | `mount_path = "auth/spire-jwt"` and `role = "spire-vm-role"` must be created by Story 1.5 |
| **Story 1.5** (SPIRE-Vault Trust) | KV2 secret must exist | Template reads `secret/data/experiment/demo` — the test secret must be written |
| **Story 1.6a** (Bootc Image) | Placeholder file to replace | Replaces `files/etc/vault-agent/agent.hcl` placeholder |
| **Story 1.6a** (Bootc Image) | Quadlet already configured | `vault-agent.container` and `httpd.container` — no changes expected |
| **Story 1.6b** (SPIRE Agent + Helper) | JWT-SVID must be available | vault-agent reads `/var/run/secrets/spiffe/jwt-svid.token` written by spiffe-helper |
| **Story 1.6d** (Deploy VM) | Consumes rebuilt image | Image must be rebuilt and pushed after this story's config changes |

### Trust Chain Validation Checklist

Before vault-agent can authenticate, all links must be in place:

1. ✅ SPIRE Server running (Story 1.2)
2. ✅ SPIRE Agent attested via x509pop (Story 1.6b)
3. ✅ spiffe-helper extracting JWT-SVID with audience `vault` (Story 1.6b)
4. ✅ JWT-SVID written to `/var/run/secrets/spiffe/jwt-svid.token` (Story 1.6b)
5. ✅ Vault JWT auth engine at `auth/spire-jwt` trusts SPIRE OIDC endpoint (Story 1.5)
6. ✅ Vault role `spire-vm-role` with `bound_audiences = ["vault"]` (Story 1.5)
7. ✅ KV2 secret at `secret/data/experiment/demo` with key `message` (Story 1.5)
8. ✅ vault-agent reads JWT-SVID, authenticates, templates secret → `/var/www/html/secret.txt` (**this story**)
9. ✅ httpd serves `/secret.txt` on port 8080 (**this story**)

### Debugging — What to Check When Things Don't Work

**vault-agent won't authenticate:**
- Check JWT-SVID exists: `cat /var/run/secrets/spiffe/jwt-svid.token`
- Decode JWT and verify `aud` contains `vault`: `cut -d. -f2 /var/run/secrets/spiffe/jwt-svid.token | base64 -d | jq .`
- Verify `sub` claim matches Story 1.5's `bound_subject` in the Vault role
- Check vault-agent logs: `podman logs vault-agent` or `journalctl -u vault-agent`
- Test Vault connectivity: `curl -k https://vault.apps.etl7.ocp.rht-labs.com/v1/sys/health`
- Manual JWT login test: `vault write auth/spire-jwt/login role=spire-vm-role jwt=@/var/run/secrets/spiffe/jwt-svid.token`

**secret.txt not rendered:**
- Check vault-agent has a valid token: `cat /var/run/vault/token`
- Check template rendering: vault-agent logs will show template errors
- Manual secret read: `VAULT_TOKEN=$(cat /var/run/vault/token) vault kv get secret/experiment/demo`
- Check file permissions: `ls -la /var/www/html/secret.txt`

**httpd returns 404 or 403:**
- Verify document root mapping: `podman exec httpd cat /etc/httpd/conf/httpd.conf | grep DocumentRoot`
- Check file exists in container: `podman exec httpd ls -la /var/www/html/`
- Check SELinux (on host): `ls -Z /var/www/html/secret.txt`

### What NOT to Do

- **Do NOT recreate the Containerfile** — Story 6a owns it
- **Do NOT recreate or modify Quadlet `.container` files** unless TLS CA injection requires it (document the reason)
- **Do NOT use `${CLUSTER_BASE_DOMAIN}`** in `agent.hcl` — it is not rendered by ArgoCD envsub; hardcode `etl7.ocp.rht-labs.com`
- **Do NOT set `remove_jwt_after_reading = true`** — spiffe-helper overwrites the JWT file continuously; deleting it breaks the rotation cycle
- **Do NOT add a custom `httpd.conf`** unless the UBI9 httpd-24 default document root is not `/var/www/html/`
- **Do NOT modify any existing cluster or component files** — this story touches only `clusters/etl7/overlays/spire-vault-demo/image/files/etc/vault-agent/agent.hcl`
- **Do NOT modify `clusters/etl4/`** — etl7-only experiment
- **Do NOT create ArgoCD Application entries** — Story 6d handles deployment

### Codebase Patterns to Follow

- Config files under `clusters/etl7/overlays/spire-vault-demo/image/files/` mirror their target paths in the bootc image
- HCL configuration style follows HashiCorp conventions: 2-space indent, comments with `#`, heredoc with `<<-EOF`
- The placeholder pattern from Story 6a uses `PLACEHOLDER_*` values — replace ALL placeholders with actual values

### Project Structure Notes

- Only one file is modified: `clusters/etl7/overlays/spire-vault-demo/image/files/etc/vault-agent/agent.hcl`
- The file tree remains identical to what Story 6a created — no new files or directories
- If the Quadlet needs TLS changes, that file is at: `clusters/etl7/overlays/spire-vault-demo/image/files/etc/containers/systemd/vault-agent.container`

### Known Risks

1. **UBI9 httpd-24 document root ambiguity:** The Red Hat S2I httpd image may not use `/var/www/html/` as document root. Must verify during implementation (see verification section above).

2. **Vault Agent template file ownership:** vault-agent cannot set `uid`/`gid` on template output files. Files will be owned by UID 10004 with mode 0644. This is functionally fine (world-readable), but differs from the epic's stated `vault-agent-user:apache` ownership. Document this limitation.

3. **Hardcoded Vault address:** The `agent.hcl` bakes in `vault.apps.etl7.ocp.rht-labs.com`. If the cluster domain changes, the image must be rebuilt. For production, use cloud-init or environment variable injection (Story 6d scope).

4. **TLS skip verify:** Using `tls_skip_verify = true` is a security trade-off acceptable for the experiment. Document the production path in the readme.

### References

- [Vault Agent JWT auto-auth method](https://developer.hashicorp.com/vault/docs/agent-and-proxy/autoauth/methods/jwt) — `path`, `role`, `remove_jwt_after_reading`, `jwt_read_period`
- [Vault Agent auto-auth](https://developer.hashicorp.com/vault/docs/agent-and-proxy/autoauth) — `enable_reauth_on_new_credentials`
- [Vault Agent template configuration](https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent/template) — `template` and `template_config` stanzas, `perms`, `static_secret_render_interval`
- [Vault Agent template ownership limitation](https://github.com/hashicorp/vault/issues/31607) — open feature request for `uid`/`gid` in template stanza
- [Vault JWT auth engine](https://docs.hashicorp.com/vault/docs/auth/jwt) — `bound_audiences`, `bound_subject`, OIDC discovery
- [SPIFFE/Vault OIDC federation tutorial](https://spiffe.io/docs/latest/keyless/vault/readme/) — end-to-end trust flow
- [Source: epic-zero-trust-secret-delivery-etl7.md — Story 1.6c]
- [Pattern reference: Story 1.6a — bootc image build] — Quadlet containers, placeholder config pattern, directory structure

## Dev Agent Record

### Agent Model Used



### Debug Log References

### Completion Notes List

### File List
