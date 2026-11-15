#!/usr/bin/env bash
set -euo pipefail

source pipeline.env

[[ "$PIPELINE_EPOCH" =~ ^v[0-9]+$ ]]
[[ "$CADDY_MIN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$TAILSCALE_MIN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
grep -q 'github.com/mholt/caddy-l4@${CADDY_L4_VERSION}' Dockerfile.caddy
grep -Fq 'ENTRYPOINT ["/usr/bin/caddy"]' Dockerfile.caddy
grep -q 'tailscale.com/cmd/derper@${TAILSCALE_VERSION}' Dockerfile.derper
grep -q '^ENV GOTOOLCHAIN=auto$' Dockerfile.derper
grep -q 'environment: production-promotion' .github/workflows/promote-stable.yml

# Read the complete inspect output: an early awk exit can SIGPIPE buildx under pipefail.
awk_program=$(sed -n "s/.*awk '\([^']*\)'.*/\1/p" .github/workflows/promote-stable.yml)
[[ -n "$awk_program" ]]
digest=$(python3 -c 'import sys; sys.stdout.write("Digest: sha256:" + "a" * 64 + "\n"); sys.stdout.flush(); sys.stdout.write("x" * 1048576 + "\n")' | awk "$awk_program")
[[ "$digest" == "sha256:$(printf 'a%.0s' {1..64})" ]]
grep -q 'docker compose config' scripts/deploy-digest.sh
grep -q 'rollback' scripts/deploy-digest.sh

# Transport workaround belongs only to build stages, never to runtime images.
for dockerfile in Dockerfile.caddy Dockerfile.derper; do
  sed -n '1,/^FROM .* AS runtime$/p' "$dockerfile" | grep -q '^ENV GODEBUG=http2client=0$'
  if sed -n '/^FROM .* AS runtime$/,$p' "$dockerfile" | grep -q '^ENV GODEBUG='; then
    echo "build transport setting leaked into runtime: $dockerfile" >&2
    exit 1
  fi
done
