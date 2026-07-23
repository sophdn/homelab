#!/usr/bin/env bash
# Nightly homelab backup.
#
# Backs up homelab config + state + bind-mounted data to a restic repo on
# /mnt/jellyfin (separate physical NVMe from /mnt/general where most data
# lives). Off-machine destination is OUT OF SCOPE for v1; remote target
# (S3 / B2 / external drive) is a deferred follow-up.
#
# Pre-backup quiesce: live SQLite DBs (gitea, toolkit-server) get an
# online-backup sibling produced via `sqlite3 SRC .backup TARGET`. The
# sibling is a consistent point-in-time snapshot that restic captures as
# part of the same nightly run, regardless of mid-transaction state of
# the live .db / -wal / -shm files. The siblings live next to their
# sources at <db>.snapshot and are deliberately overwritten each night;
# cleaned at end of run. Closes bug homelab-restic-live-db-consistency-risk
# for both rollback-journal mode (gitea) and WAL mode (toolkit-server).
#
# Loud-failure: relies on systemd journaling. A failed run leaves the
# homelab-backup.service unit in `failed` state; check with
#   systemctl status homelab-backup.service
#   journalctl -u homelab-backup
# A failed run also writes a "backup FAILED" line to /var/log/homelab/backup.log.

set -euo pipefail

ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/env/restic.env"
[ -f "$ENV_FILE" ] || { echo "FATAL: $ENV_FILE missing" >&2; exit 2; }
set -a
# shellcheck disable=SC1090  # runtime-resolved env file, absent at lint time
source "$ENV_FILE"
set +a

LOG_DIR=/var/log/homelab
LOG_FILE="$LOG_DIR/backup.log"
[ -d "$LOG_DIR" ] || { echo "FATAL: $LOG_DIR not present (recipe-step 'create-log-dir' should land it)" >&2; exit 3; }

START=$(date +%s)
echo "$(date -Is) backup start (pid=$$)" | tee -a "$LOG_FILE"

# ─── Pre-backup: quiesce live SQLite DBs ──────────────────────────────────────
# Each entry: source path -> sibling .snapshot path. Removed at end of run
# (or by the next run if this one aborts mid-stream — `.snapshot` files
# left behind from a crashed run are still consistent themselves).
SQLITE_DBS=(
  "/home/youruser/homelab/gitea/data/gitea/gitea.db"
  "/home/youruser/homelab/toolkit-server/data/toolkit.db"
)
SNAPSHOT_FILES=()
for src in "${SQLITE_DBS[@]}"; do
  [ -f "$src" ] || { echo "$(date -Is) sqlite skip: $src not present" | tee -a "$LOG_FILE"; continue; }
  dst="${src}.snapshot"
  if sqlite3 "$src" ".backup '$dst'" 2>>"$LOG_FILE"; then
    SNAPSHOT_FILES+=("$dst")
    echo "$(date -Is) sqlite snapshot: $src -> $dst ($(stat -c %s "$dst") bytes)" | tee -a "$LOG_FILE"
  else
    echo "$(date -Is) sqlite snapshot FAILED: $src (continuing with live file in scope)" | tee -a "$LOG_FILE"
  fi
done

cleanup_snapshots() {
  for f in "${SNAPSHOT_FILES[@]}"; do
    [ -f "$f" ] && rm -f "$f"
  done
}
trap cleanup_snapshots EXIT

# ─── Pre-backup: dump the campaign-settings Postgres ──────────────────────────
# Postgres keeps its data in a docker volume under /var/lib/docker/volumes,
# which is in NONE of the backup paths below — so until 2026-07-15 the campaign
# DB (years of irreplaceable creative work) was backed up by nothing at all.
# The dump lands under /home/youruser/homelab and is therefore captured by the
# `restic backup` run below. It must happen HERE, before that run, or the
# night's snapshot would hold the previous night's dump.
#
# Unlike the SQLite siblings above, dumps are NOT cleaned at end of run: they
# rotate on their own retention (with a hard floor) so a restore can start from
# a local file, while restic holds the long tail. Same reason this is a hard
# failure rather than a "continuing" warning — there is no live file to fall
# back to, so a silent skip would mean no backup at all, which is the state
# this replaces.
#
# A dump failure must NOT abort this script: the rest of the box (gitea,
# nextcloud, toolkit-server) still needs backing up, and letting one database
# take the others down would be a worse outage than the one it reports. So the
# failure is recorded and re-raised at the very END of the run — everything
# gets backed up AND the unit still goes red. Recording-and-continuing is only
# honest because of that final exit; without it this would be the `|| true`
# anti-pattern that hid a peer's dead backups for 22 days.
CAMPAIGN_DUMP="/home/youruser/homelab/campaign-db/scripts/dump.sh"
CAMPAIGN_DUMP_FAILED=0
if [ -x "$CAMPAIGN_DUMP" ]; then
  if ! "$CAMPAIGN_DUMP" 2>&1 | tee -a "$LOG_FILE"; then
    CAMPAIGN_DUMP_FAILED=1
    echo "$(date -Is) campaign-db dump FAILED — continuing with the rest of the backup, will fail the run at exit" | tee -a "$LOG_FILE"
  fi
else
  CAMPAIGN_DUMP_FAILED=1
  echo "$(date -Is) campaign-db dump MISSING: $CAMPAIGN_DUMP not executable — the campaign DB is NOT being backed up" | tee -a "$LOG_FILE"
fi

# ─── Backup ───────────────────────────────────────────────────────────────────
# Backup paths cover homelab config + state + bind-mounted data + ad-hoc roots.
# The .snapshot siblings are picked up automatically because they sit next to
# their sources under /home/youruser/homelab.
# Excludes: /mnt/jellyfin/* (backup target itself + media — regeneratable)
# Excludes: ~/homelab/.git/objects/pack/* (recoverable from gitea remote)
restic backup \
  /home/youruser/homelab \
  /mnt/general/jellyfin-docker-config \
  /mnt/general/nextcloud \
  /var/lib/dm-toolkit \
  /etc/act_runner \
  --exclude='/home/youruser/homelab/.git/objects/pack/*' \
  --tag homelab-data 2>&1 | tee -a "$LOG_FILE"

# Retention: 7 daily, 4 weekly, 6 monthly. Prune unreachable data.
restic forget \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 6 \
  --prune \
  --tag homelab-data 2>&1 | tee -a "$LOG_FILE"

DURATION=$(( $(date +%s) - START ))

# Re-raise a campaign-db dump failure deferred from the quiesce step above.
# restic itself succeeded, so the other stacks are safely backed up — but the
# run is not "ok" and the unit must not report green.
if [ "$CAMPAIGN_DUMP_FAILED" -ne 0 ]; then
  echo "$(date -Is) backup FAILED duration=${DURATION}s — restic ok, but the campaign-db dump did not run; the campaign DB is NOT in tonight's snapshot" | tee -a "$LOG_FILE"
  exit 1
fi

echo "$(date -Is) backup ok duration=${DURATION}s" | tee -a "$LOG_FILE"
