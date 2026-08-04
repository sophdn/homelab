#!/usr/bin/env bash
# Dump the campaign-settings Postgres to a timestamped file under
# campaign-db/data/, then prune old dumps behind a hard floor.
#
# WHY THIS EXISTS
#   The campaign DB is years of irreplaceable creative work — there is no
#   "re-derive from source". Until 2026-07-15 it was backed up by NOTHING:
#   restic covers /home/youruser/homelab, /mnt/general/jellyfin-docker-config
#   and /mnt/general/nextcloud, but Postgres keeps its data in a docker
#   volume (campaign-settings-deploy_campaign-prod-pgdata) under
#   /var/lib/docker/volumes — none of those paths. dm-manager-backup.timer
#   backs up the PREDECESSOR app's data dir, not this.
#
# HOW IT REACHES THE BACKUP DISK
#   Dumps land under /home/youruser/homelab, which restic already backs up to
#   the repo on /mnt/jellyfin (a separate physical NVMe). So this script does
#   not talk to restic at all — it just puts a consistent file where the
#   nightly run will find it. restic/scripts/backup.sh calls this during its
#   pre-backup quiesce, BEFORE `restic backup`, so each night's snapshot
#   contains that night's dump rather than yesterday's. Same contract as the
#   SQLite `.backup` siblings alongside it.
#
#   Threat model is unchanged and stated in the README: this survives disk
#   failure, a bad migration, and a fat-finger DELETE. It does NOT survive a
#   house fire — off-box replication remains a deferred follow-up.
#
# WHY pg_dump AND NOT A FILE-COPY
#   Copying a live Postgres data dir gives you a torn cluster, not a backup.
#   pg_dump runs inside the container against a live server and produces a
#   consistent snapshot (single transaction), no quiesce or downtime needed.
#   --format=custom so pg_restore can run it selectively and compressed.
#
# LOUD FAILURE
#   set -euo pipefail + no `|| true` on anything that must be able to warn.
#   A failure here fails restic's backup.sh, which fails
#   homelab-backup.service, which shows as a failed unit. (Push alerting to a
#   human is bug `backup-and-disk-events-do-not-reach-a-human-silent-failure`
#   — until it lands, a failed unit is the signal.)

set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"

# Optional env file — defaults work for the deployed stack, so a fresh clone
# backs up correctly with no configuration. Override only to point at a
# different container/database.
ENV_FILE="$HERE/env/campaign-db.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090  # runtime-resolved env file, absent at lint time
  source "$ENV_FILE"
  set +a
fi

PG_CONTAINER="${CS_PG_CONTAINER:-campaign-settings-postgres}"
DUMP_DIR="${CS_DUMP_DIR:-$HERE/data}"
# Retention on the LOCAL dumps only. The long tail lives in restic
# (7 daily / 4 weekly / 6 monthly), so this is a fast-restore cache, not the
# archive — keep it short but never empty.
KEEP_DAYS="${CS_DUMP_KEEP_DAYS:-14}"
# HARD FLOOR: the prune below can never take the directory below this many
# dumps, whatever their age. A cleanup that can delete to zero is a cleanup
# that will, eventually, on the one night it matters.
KEEP_MIN="${CS_DUMP_KEEP_MIN:-3}"

# Overridable so the scripts can be exercised off-box (see campaign-db/README).
# Defaults to the homelab log dir the other units use.
LOG_DIR="${CS_LOG_DIR:-/var/log/homelab}"
LOG_FILE="$LOG_DIR/campaign-db.log"
[ -d "$LOG_DIR" ] || { echo "FATAL: $LOG_DIR not present" >&2; exit 3; }

log() { echo "$(date -Is) campaign-db: $1" | tee -a "$LOG_FILE"; }

if ! docker inspect "$PG_CONTAINER" >/dev/null 2>&1; then
  log "FATAL: container $PG_CONTAINER not found — campaign DB NOT dumped"
  exit 4
fi

# Read the credentials off the running container rather than storing a second
# copy: the compose stack already owns them, and a duplicated secret is a
# secret that drifts.
container_env() {
  docker inspect "$PG_CONTAINER" --format "{{range .Config.Env}}{{println .}}{{end}}" \
    | sed -n "s/^$1=//p" | head -1
}
PG_USER="${CS_PG_USER:-$(container_env POSTGRES_USER)}"
PG_DB="${CS_PG_DB:-$(container_env POSTGRES_DB)}"
: "${PG_USER:?could not resolve POSTGRES_USER from $PG_CONTAINER; set CS_PG_USER}"
: "${PG_DB:?could not resolve POSTGRES_DB from $PG_CONTAINER; set CS_PG_DB}"

mkdir -p "$DUMP_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TARGET="$DUMP_DIR/${PG_DB}-${STAMP}.dump"

# Dump to a .partial and rename only on success, so an interrupted run can
# never leave a truncated file that looks like a good backup — and so the
# restore test never picks a half-written dump.
log "dump start db=$PG_DB container=$PG_CONTAINER -> $TARGET"
docker exec "$PG_CONTAINER" pg_dump -U "$PG_USER" -d "$PG_DB" --format=custom > "$TARGET.partial"
mv "$TARGET.partial" "$TARGET"
SIZE="$(stat -c %s "$TARGET")"
[ "$SIZE" -gt 0 ] || { log "FATAL: dump is 0 bytes — $TARGET"; exit 5; }
log "dump ok bytes=$SIZE"

# ─── Prune, floor first ───────────────────────────────────────────────────────
# Sort newest-first, keep the first KEEP_MIN unconditionally, and only then
# consider age. `find -delete` alone would honour age and ignore the floor.
mapfile -t DUMPS < <(find "$DUMP_DIR" -maxdepth 1 -name "${PG_DB}-*.dump" -printf '%T@ %p\n' \
  | sort -rn | cut -d' ' -f2-)
TOTAL="${#DUMPS[@]}"
PRUNED=0
if [ "$TOTAL" -gt "$KEEP_MIN" ]; then
  for f in "${DUMPS[@]:$KEEP_MIN}"; do
    if [ -n "$(find "$f" -mtime +"$KEEP_DAYS" -print -quit)" ]; then
      rm -f "$f"
      PRUNED=$((PRUNED + 1))
    fi
  done
fi
log "prune ok kept=$((TOTAL - PRUNED)) pruned=$PRUNED floor=$KEEP_MIN keep_days=$KEEP_DAYS"
