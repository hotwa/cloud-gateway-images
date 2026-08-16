#!/usr/bin/env bash
set -euo pipefail

STACK_DIR=${STACK_DIR:-/opt/cloud-gateway}
STATE_DIR=${STATE_DIR:-/var/lib/cloud-gateway-image-update}
CADDY_IMAGE=${CADDY_IMAGE:-ghcr.io/hotwa/cloud-gateway-caddy}
DERPER_IMAGE=${DERPER_IMAGE:-ghcr.io/hotwa/cloud-gateway-derper}
DEPLOY_SCRIPT=${DEPLOY_SCRIPT:-/usr/local/libexec/cloud-gateway-images/deploy-digest.sh}

install -d -o root -g root -m 0700 "$STATE_DIR"

resolve_digest() {
  local image=$1 digest
  digest=$(docker buildx imagetools inspect "$image:stable" |
    awk '/^Digest:/ {print $2; exit}')
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo "unable to resolve stable digest for $image" >&2
    return 1
  }
  printf '%s\n' "$digest"
}

check_component() {
  local component=$1 image=$2 state_file current='' remote
  state_file="$STATE_DIR/$component.digest"
  [ ! -f "$state_file" ] || current=$(cat "$state_file")
  remote=$(resolve_digest "$image")
  if [ "$remote" = "$current" ]; then
    printf '%s is current at %s\n' "$component" "$remote"
    return
  fi
  "$DEPLOY_SCRIPT" "$component" "$remote"
}

cd "$STACK_DIR"
docker compose config >/dev/null
check_component caddy "$CADDY_IMAGE"
check_component derper "$DERPER_IMAGE"
