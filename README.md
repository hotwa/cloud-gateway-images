# Cloud Gateway Images

Secret-free CI and deployment contracts for the custom images used by the
Alibaba Cloud lightweight gateway.

## Images

| Image | Upstream | Purpose |
|---|---|---|
| `ghcr.io/hotwa/cloud-gateway-caddy` | latest stable Caddy plus pinned alidns, Cloudflare and caddy-l4 plugins | L4/L7 ingress |
| `ghcr.io/hotwa/cloud-gateway-derper` | latest stable Tailscale `derper` | private DERP/STUN relay |

The servers never build these images. GitHub Actions resolves releases and the
caddy-l4 commit, builds test/runtime targets, publishes SBOM/provenance and an
immutable `candidate-v1-<sha256>` tag. The mutable `stable` tag can only be
advanced by the manual promotion workflow protected by the
`production-promotion` GitHub Environment.

The DERP builder enables Go automatic toolchain selection so the pinned Tailscale
release can select its required compiler even when the Alpine base bundles an older Go.

Go module downloads in both builders use HTTPS over HTTP/1 to avoid the HTTP/2
stream errors observed on GitHub runners. TLS and module checksum verification remain
enabled, and this build-only setting is not copied into the runtime images.

## Update flow

1. `Build candidate images` runs daily and on repository changes.
2. Review upstream release notes and the build attestation. Test a candidate
   against the current Caddyfile/L4 JSON or DERP endpoint.
3. Run `Promote candidate to stable`; Environment approval is required.
4. The lightweight host timer resolves `stable` to an immutable digest.
5. `deploy-digest.sh` backs up Compose/config/state, pulls the digest, validates
   Caddy configs in an isolated container, recreates only affected services and
   probes public data paths.
6. Any failed validation, startup or probe restores the old override and digest.

Official stateful/control-plane images such as PostgreSQL, Prometheus, CoreDNS,
Tailscale, Woodpecker and WG-Easy are intentionally not mirrored or blindly
auto-promoted here. They remain pinned by version and digest in the operations
repository and require migration-note review plus component-specific backups.

## Host installation

Install the scripts and units from this repository as root, create initial
`caddy.digest` and, once DERPER's new `-c` configuration contract is validated,
`derper.digest` state files from approved stable manifests,
and create `/opt/cloud-gateway/docker-compose.override.yml` with the same exact
digests. Validate before enabling the timer:

```bash
docker compose -C /opt/cloud-gateway config
systemctl start cloud-gateway-image-update.service
systemctl enable --now cloud-gateway-image-update.timer
```

`MANAGE_DERPER=0` is the safe default. Tailscale 1.102.2's DERPER requires a
new `-c <config path>` contract, while the current production Compose uses the
legacy flags. The workflow may build DERPER candidates, but the host must not
deploy them automatically until a reviewed config and rollback test pass; set
`MANAGE_DERPER=1` only after that migration.

Do not put GHCR tokens in the timer: the packages are public. Production `.env`,
certificates, Tailnet state and cloud credentials stay only on the host.
