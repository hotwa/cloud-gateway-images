#!/usr/bin/env bash
set -euo pipefail

STACK_DIR=${STACK_DIR:-/opt/cloud-gateway}
STATE_DIR=${STATE_DIR:-/var/lib/cloud-gateway-image-update}
CADDY_IMAGE=${CADDY_IMAGE:-ghcr.io/hotwa/cloud-gateway-caddy}
DERPER_IMAGE=${DERPER_IMAGE:-ghcr.io/hotwa/cloud-gateway-derper}
OVERRIDE_FILE=${OVERRIDE_FILE:-$STACK_DIR/docker-compose.override.yml}

component=${1:-}
new_digest=${2:-}
case "$component" in caddy|derper) ;; *) echo 'component must be caddy or derper' >&2; exit 2 ;; esac
[[ "$new_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'invalid digest' >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo 'run as root' >&2; exit 1; }

install -d -o root -g root -m 0700 "$STATE_DIR"
exec 9>"$STATE_DIR/deploy.lock"
flock -n 9 || { echo 'another deployment is running' >&2; exit 1; }

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
backup_dir="$STACK_DIR/backups/registry-image-$timestamp-$component"
install -d -o root -g root -m 0700 "$backup_dir"
cp -a "$STACK_DIR/docker-compose.yml" "$backup_dir/"
[ ! -f "$OVERRIDE_FILE" ] || cp -a "$OVERRIDE_FILE" "$backup_dir/"
[ ! -f "$STATE_DIR/caddy.digest" ] || cp -a "$STATE_DIR/caddy.digest" "$backup_dir/"
[ ! -f "$STATE_DIR/derper.digest" ] || cp -a "$STATE_DIR/derper.digest" "$backup_dir/"
cp -a "$STACK_DIR/caddy-l7/Caddyfile" "$STACK_DIR/caddy/config/l4.json" "$backup_dir/"

old_caddy=$(cat "$STATE_DIR/caddy.digest" 2>/dev/null || true)
old_derper=$(cat "$STATE_DIR/derper.digest" 2>/dev/null || true)
caddy_digest=$old_caddy
derper_digest=$old_derper
if [ "$component" = caddy ]; then caddy_digest=$new_digest; else derper_digest=$new_digest; fi
[[ "$caddy_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'caddy state is not initialized' >&2; exit 1; }
if [ "$component" = derper ]; then
  [[ "$derper_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'derper state is not initialized' >&2; exit 1; }
fi

rollback() {
  rc=$?
  trap - ERR
  echo "deployment failed; rollback from $backup_dir" >&2
  if [ -f "$backup_dir/docker-compose.override.yml" ]; then
    cp -a "$backup_dir/docker-compose.override.yml" "$OVERRIDE_FILE"
  else
    mv "$OVERRIDE_FILE" "$backup_dir/failed-docker-compose.override.yml" 2>/dev/null || true
  fi
  [ ! -f "$backup_dir/caddy.digest" ] || cp -a "$backup_dir/caddy.digest" "$STATE_DIR/caddy.digest"
  [ ! -f "$backup_dir/derper.digest" ] || cp -a "$backup_dir/derper.digest" "$STATE_DIR/derper.digest"
  cd "$STACK_DIR"
  docker compose config >/dev/null
  if [ "$component" = caddy ]; then
    docker compose up -d --no-deps caddy-l7 caddy-l4
  else
    docker compose up -d --no-deps derper
  fi
  exit "$rc"
}
trap rollback ERR

if [ "$component" = caddy ]; then
  image="$CADDY_IMAGE@$new_digest"
else
  image="$DERPER_IMAGE@$new_digest"
fi
docker pull "$image"

if [ "$component" = caddy ]; then
  docker run --rm --env-file "$STACK_DIR/.env" \
    -v "$STACK_DIR/caddy-l7/Caddyfile:/etc/caddy/Caddyfile:ro" \
    --entrypoint caddy "$image" validate --config /etc/caddy/Caddyfile
  docker run --rm \
    -v "$STACK_DIR/caddy/config/l4.json:/etc/caddy/l4.json:ro" \
    --entrypoint caddy "$image" validate --config /etc/caddy/l4.json
fi

candidate="$OVERRIDE_FILE.candidate"
umask 077
cat >"$candidate" <<EOF
services:
  caddy-l4:
    image: $CADDY_IMAGE@$caddy_digest
  caddy-l7:
    image: $CADDY_IMAGE@$caddy_digest
EOF
if [[ "$derper_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  cat >>"$candidate" <<EOF
  derper:
    image: $DERPER_IMAGE@$derper_digest
EOF
fi
cd "$STACK_DIR"
docker compose -f docker-compose.yml -f "$candidate" config >/dev/null
mv "$candidate" "$OVERRIDE_FILE"

if [ "$component" = caddy ]; then
  docker compose up -d --no-deps caddy-l7 caddy-l4
  targets='caddy-l7 caddy-l4'
else
  docker compose up -d --no-deps derper
  targets='derper'
fi

for attempt in $(seq 1 30); do
  all_running=1
  for target in $targets; do
    [ "$(docker inspect -f '{{.State.Status}}' "$target")" = running ] || all_running=0
  done
  [ "$all_running" -eq 1 ] && break
  [ "$attempt" -lt 30 ] || false
  sleep 2
done

for target in $targets; do
  if docker logs --tail 80 "$target" 2>&1 | grep -Eiq 'panic|fatal|error: loading|adapt.*error'; then
    echo "fatal startup log detected in ${target}" >&2
    false
  fi
done

probe_non_5xx() {
  local url=$1 code
  code=$(curl --silent --show-error --output /dev/null --connect-timeout 8 \
    --max-time 15 --write-out '%{http_code}' "$url")
  [[ "$code" =~ ^[1-4][0-9][0-9]$ ]]
}

wait_probe_non_5xx() {
  local url=$1 attempt
  for attempt in $(seq 1 120); do
    if probe_non_5xx "$url"; then
      return 0
    fi
    [ "$attempt" -lt 120 ] || return 1
    sleep 2
  done
}

if [ "$component" = caddy ]; then
  wait_probe_non_5xx https://ci.jmsu.top/
  wait_probe_non_5xx https://wg.jmsu.top/
else
  wait_probe_non_5xx https://derper.jmsu.top/derp/probe
fi

printf '%s\n' "$caddy_digest" >"$STATE_DIR/caddy.digest"
printf '%s\n' "$derper_digest" >"$STATE_DIR/derper.digest"
chmod 0600 "$STATE_DIR/caddy.digest" "$STATE_DIR/derper.digest"
trap - ERR
printf 'deployed %s at %s; rollback=%s\n' "$component" "$new_digest" "$backup_dir"
