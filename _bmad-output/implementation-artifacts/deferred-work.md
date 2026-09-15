## Deferred from: code review of 1-3-deploy-vault-on-etl7-with-latest-images.md (2026-09-15)

- Helm `server.route.host` is `vault.apps.${BASE_DOMAIN}` (`clusters/etl7/overlays/vault/values.yaml:35`). Envsubst only defines `CLUSTER_BASE_DOMAIN` / `PLATFORM_BASE_DOMAIN` / `HUB_BASE_DOMAIN`. The overlay JSON patch currently rewrites Route/ConsoleLink to `${CLUSTER_BASE_DOMAIN}`. Copied from etl4 and the story template; latent if the Route patch stops matching.
- Auto-initializer prints unseal key and root token (`clusters/etl7/overlays/vault/values.yaml:116-120`). Demo sidecar copied from etl4; secrets land in container logs.
- `utility-downloader` curls kubectl from `dl.k8s.io` (`stable.txt`, linux/amd64) and jq 1.6 from GitHub with no checksums (`clusters/etl7/overlays/vault/values.yaml:79-89`). Copied from etl4; fails closed only if the init container itself errors.
- Init/unseal/admin sidecar bash has no `set -e`, no persist-success check, unquoted key expansion, and `grep etl7 | awk` accessor parsing (`clusters/etl7/overlays/vault/values.yaml:112-206`). Copied from etl4; a failed kubectl create after `vault operator init` can lose the root token.
- `vault-admin-initializer` uses `VAULT_ADDR=https://vault.vault.svc:8200` (`clusters/etl7/overlays/vault/values.yaml:167-168`) while init/unseal use localhost. Copied from etl4; Service has no endpoints until the pod is Ready.
- vault-helm 0.31.0 still emits Pod `vault-server-test` (`helm.sh/hook: test`) that greps `sealed: (true|false)` and exits 0. Overlay does not set `skipTests` (`clusters/etl7/overlays/vault/kustomization.yaml:30-36`). Same chart-test behavior as etl4.
- Init/unseal sidecars set `VAULT_SKIP_VERIFY=true` and `VAULT_CACERT` together (`clusters/etl7/overlays/vault/values.yaml:102-107`). Copied from etl4; TLS verify is skipped.

## Deferred from: code review of 1-4-deploy-vault-config-operator-on-etl7.md (2026-09-15)

- etl7 `soteria` Application still sources `clusters/etl6/overlays/soteria-instance` rather than an etl7 overlay. Pre-existing leftover; not introduced by story 1.4 (the 1.4 diff only normalized the trailing newline on that line).
