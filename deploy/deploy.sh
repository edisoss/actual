#!/usr/bin/env bash
#
# Deploy the fork's sync-server image to the "finance" server.
#
# Run from your machine (Git Bash on Windows works):
#
#   deploy/deploy.sh                  # deploy ghcr.io/edisoss/actual-server:latest
#   deploy/deploy.sh deploy sha-abc1234   # deploy a specific image tag
#   deploy/deploy.sh rollback         # go back to the image that ran before the last deploy
#   deploy/deploy.sh status           # show what is running, rollback image and backups
#
# The script copies itself to the server over SSH and runs there. What a deploy does:
#
#   1. Pulls the new image first. Nothing is touched if the pull fails.
#   2. Tags the currently running image as actual-server:rollback so it is kept.
#   3. Stops the app and writes a verified backup of actual-data and config to
#      ~/finance/backups (the app is stopped so SQLite files are consistent).
#   4. Pins the new image by digest in docker-compose.override.yml and restarts
#      only the "actual" service (Caddy keeps running).
#   5. Waits for the health check. If it fails, restores the backup it just took,
#      starts the previous image again and exits non-zero.
#
# docker-compose.yml on the server is never edited. Deleting
# docker-compose.override.yml returns to whatever image docker-compose.yml names.
#
# Settings can be overridden with environment variables when running locally:
#   DEPLOY_HOST (default: finance), DEPLOY_IMAGE (default: ghcr.io/edisoss/actual-server)

set -euo pipefail

if [[ "${1:-}" != "--remote" ]]; then
  host="${DEPLOY_HOST:-finance}"
  image="${DEPLOY_IMAGE:-ghcr.io/edisoss/actual-server}"
  args=""
  for arg in "$@"; do args+=" $(printf '%q' "$arg")"; done
  exec ssh "$host" "DEPLOY_IMAGE=$(printf '%q' "$image") bash -s -- --remote$args" < "$0"
fi
shift

# ---------------------------------------------------------------------------
# Everything below runs on the server.
# ---------------------------------------------------------------------------

APP_DIR="$HOME/finance"
SERVICE="actual"
IMAGE_REPO="${DEPLOY_IMAGE:?}"
ROLLBACK_TAG="actual-server:rollback"
OVERRIDE="docker-compose.override.yml"
STATE_DIR=".deploy"
BACKUP_DIR="backups"
KEEP_BACKUPS=10
MIN_FREE_KB=$((2 * 1024 * 1024)) # 2 GB
HEALTH_TIMEOUT_S=120

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARN: %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

cd "$APP_DIR" || die "$APP_DIR not found"
[[ -f docker-compose.yml ]] || die "no docker-compose.yml in $APP_DIR"
mkdir -p "$STATE_DIR" "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# Only one deploy/rollback at a time.
exec 9> "$STATE_DIR/lock"
flock -n 9 || die "another deploy is already running"

compose() { docker compose "$@"; }

container_id() { compose ps -q "$SERVICE" 2> /dev/null || true; }

running_image_id() {
  local cid
  cid="$(container_id)"
  [[ -n "$cid" ]] && docker inspect -f '{{.Image}}' "$cid"
}

running_image_ref() {
  local cid
  cid="$(container_id)"
  [[ -n "$cid" ]] && docker inspect -f '{{.Config.Image}}' "$cid"
}

# If the script dies while the app is stopped, bring it back up with whatever
# the override currently points at (the old image, unless we got past pinning).
APP_STOPPED=0
on_exit() {
  local status=$?
  if [[ "$APP_STOPPED" == 1 ]]; then
    warn "script exited while $SERVICE was stopped; starting it again"
    compose up -d --no-deps "$SERVICE" || warn "could not restart $SERVICE, check manually"
  fi
  exit "$status"
}
trap on_exit EXIT

stop_app() {
  log "Stopping $SERVICE"
  APP_STOPPED=1
  compose stop "$SERVICE"
}

start_app() {
  log "Starting $SERVICE"
  compose up -d --no-deps "$SERVICE"
  APP_STOPPED=0
}

wait_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT_S)) cid
  log "Waiting up to ${HEALTH_TIMEOUT_S}s for the health check"
  while ((SECONDS < deadline)); do
    cid="$(container_id)"
    if [[ -n "$cid" ]] && docker exec "$cid" node scripts/health-check.js > /dev/null 2>&1; then
      log "Healthy"
      return 0
    fi
    sleep 2
  done
  return 1
}

pin_image() {
  cat > "$OVERRIDE.tmp" << EOF
# Managed by deploy.sh: pins the image of the "$SERVICE" service.
# Delete this file to fall back to the image named in docker-compose.yml.
services:
  $SERVICE:
    image: $1
EOF
  mv "$OVERRIDE.tmp" "$OVERRIDE"
  compose config -q || die "compose config is invalid after pinning $1"
}

# Stops the app and writes a verified backup to $BACKUP_FILE. Leaves the app stopped.
# Not meant to be called in a subshell: the exit trap relies on APP_STOPPED.
BACKUP_FILE=""
backup() {
  local ts file f items=(actual-data docker-compose.yml)
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  file="$BACKUP_DIR/actual-$ts.tar.gz"
  for f in Caddyfile "$OVERRIDE" "$STATE_DIR/current"; do
    if [[ -e "$f" ]]; then items+=("$f"); fi
  done

  stop_app
  log "Backing up to $file"
  tar -czf "$file.partial" "${items[@]}"
  tar -tzf "$file.partial" > /dev/null || die "backup archive failed verification"
  mv "$file.partial" "$file"
  BACKUP_FILE="$file"
}

prune_backups() {
  local old
  old="$(ls -1t "$BACKUP_DIR"/actual-*.tar.gz 2> /dev/null | tail -n +$((KEEP_BACKUPS + 1)))"
  if [[ -n "$old" ]]; then
    log "Removing backups beyond the newest $KEEP_BACKUPS"
    echo "$old" | xargs -r rm --
  fi
}

# Puts actual-data back from a backup. The current data is moved aside, not deleted.
restore_data() {
  local file="$1" aside tmp
  aside="actual-data.failed-$(date -u +%Y%m%dT%H%M%SZ)"
  tmp="$(mktemp -d "$APP_DIR/.restore.XXXXXX")"
  log "Restoring actual-data from $file (current data moved to $aside)"
  # Extract fully before touching the live directory.
  tar -xzf "$file" -C "$tmp" actual-data
  mv actual-data "$aside"
  mv "$tmp/actual-data" actual-data
  rmdir "$tmp"
}

preflight() {
  command -v docker > /dev/null || die "docker not found"
  compose config -q || die "docker compose config is invalid"
  local free_kb
  free_kb="$(df -Pk . | awk 'NR==2 {print $4}')"
  ((free_kb >= MIN_FREE_KB)) || die "less than 2 GB free on disk"
}

cmd_deploy() {
  local tag="${1:-latest}" new_ref new_id pinned old_id old_ref
  new_ref="$IMAGE_REPO:$tag"
  preflight

  log "Pulling $new_ref"
  docker pull "$new_ref" ||
    die "pull failed. If the package is private, run 'docker login ghcr.io' on the server with a token that has read:packages"
  new_id="$(docker image inspect -f '{{.Id}}' "$new_ref")"
  pinned="$(docker image inspect -f '{{index .RepoDigests 0}}' "$new_ref")"

  old_id="$(running_image_id || true)"
  old_ref="$(running_image_ref || true)"
  [[ -n "$old_id" ]] || die "$SERVICE is not running, so there is no image to roll back to. Start it first."
  if [[ "$old_id" == "$new_id" ]]; then
    log "Already running $pinned, nothing to do"
    return 0
  fi

  log "Keeping current image ($old_ref) as $ROLLBACK_TAG"
  docker tag "$old_id" "$ROLLBACK_TAG"
  printf '%s %s\n' "$old_id" "$old_ref" > "$STATE_DIR/previous"

  backup

  log "Deploying $pinned"
  pin_image "$pinned"
  start_app

  if wait_healthy; then
    printf '%s %s\n' "$new_id" "$pinned" > "$STATE_DIR/current"
    prune_backups
    log "Deployed $pinned. Backup: $BACKUP_FILE"
    return 0
  fi

  warn "New version is not healthy. Last log lines:"
  compose logs --tail 50 "$SERVICE" >&2 || true
  warn "Rolling back to the previous image and restoring the backup"
  stop_app
  # Pin the old image first, so the exit trap never restarts the broken one.
  pin_image "$ROLLBACK_TAG"
  restore_data "$BACKUP_FILE"
  start_app
  wait_healthy || die "ROLLBACK IS ALSO UNHEALTHY. Check 'docker compose logs $SERVICE' in $APP_DIR"
  die "deploy of $new_ref failed; previous version restored with data from $BACKUP_FILE"
}

cmd_rollback() {
  local current_id rollback_id prev_override=""
  rollback_id="$(docker image inspect -f '{{.Id}}' "$ROLLBACK_TAG" 2> /dev/null)" ||
    die "no $ROLLBACK_TAG image on this server; nothing to roll back to"
  current_id="$(running_image_id || true)"
  [[ "$current_id" != "$rollback_id" ]] || die "already running the rollback image"
  preflight

  if [[ -f "$OVERRIDE" ]]; then prev_override="$(cat "$OVERRIDE")"; fi
  backup

  log "Rolling back to $ROLLBACK_TAG ($(cut -d' ' -f2 "$STATE_DIR/previous" 2> /dev/null || echo unknown))"
  pin_image "$ROLLBACK_TAG"
  start_app

  if wait_healthy; then
    printf '%s %s\n' "$rollback_id" "$ROLLBACK_TAG" > "$STATE_DIR/current"
    prune_backups
    log "Rolled back. Data was NOT restored; this backup of the current data was taken first: $BACKUP_FILE"
    log "If the newer version migrated the data and the old one misbehaves, restore an older backup from $APP_DIR/$BACKUP_DIR"
    return 0
  fi

  warn "Rollback image is not healthy; returning to the version that was running"
  compose logs --tail 50 "$SERVICE" >&2 || true
  if [[ -n "$prev_override" ]]; then printf '%s\n' "$prev_override" > "$OVERRIDE"; else rm -f "$OVERRIDE"; fi
  start_app
  wait_healthy || die "app is unhealthy after returning to the previous version. Check 'docker compose logs $SERVICE'"
  die "rollback failed; still running the version from before"
}

cmd_status() {
  echo "Running:  $(running_image_ref || echo 'not running')"
  echo "Pinned:   $(sed -n 's/^ *image: //p' "$OVERRIDE" 2> /dev/null || echo 'no override (using docker-compose.yml)')"
  echo "Rollback: $(docker image inspect -f '{{.Id}}' "$ROLLBACK_TAG" 2> /dev/null || echo none)"
  echo "Previous: $(cat "$STATE_DIR/previous" 2> /dev/null || echo none)"
  echo "Backups:"
  ls -1t "$BACKUP_DIR"/actual-*.tar.gz 2> /dev/null | head -n "$KEEP_BACKUPS" | sed 's/^/  /' || true
}

case "${1:-deploy}" in
  deploy) cmd_deploy "${2:-latest}" ;;
  rollback) cmd_rollback ;;
  status) cmd_status ;;
  *) die "unknown command '$1' (use deploy [TAG], rollback or status)" ;;
esac
