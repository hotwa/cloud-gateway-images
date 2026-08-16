#!/usr/bin/env bash
set -euo pipefail

source pipeline.env

[[ "$PIPELINE_EPOCH" =~ ^v[0-9]+$ ]]
[[ "$CADDY_MIN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$TAILSCALE_MIN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
grep -q 'github.com/mholt/caddy-l4@${CADDY_L4_VERSION}' Dockerfile.caddy
grep -Fq 'ENTRYPOINT ["/usr/bin/caddy"]' Dockerfile.caddy
grep -q 'tailscale.com/cmd/derper@${TAILSCALE_VERSION}' Dockerfile.derper
grep -q 'environment: production-promotion' .github/workflows/promote-stable.yml
grep -q 'docker compose config' scripts/deploy-digest.sh
grep -q 'rollback' scripts/deploy-digest.sh
