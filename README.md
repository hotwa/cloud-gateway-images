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
`caddy.digest` and `derper.digest` state files from approved stable manifests,
and create `/opt/cloud-gateway/docker-compose.override.yml` with the same exact
digests. Validate before enabling the timer:

```bash
docker compose -C /opt/cloud-gateway config
systemctl start cloud-gateway-image-update.service
systemctl enable --now cloud-gateway-image-update.timer
```

Do not put GHCR tokens in the timer: the packages are public. Production `.env`,
certificates, Tailnet state and cloud credentials stay only on the host.
