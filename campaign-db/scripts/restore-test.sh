#!/usr/bin/env bash
# Restore the newest campaign-settings dump into a throwaway database and
# verify it, then drop it.
#
# WHY THIS EXISTS
#   A copy you have never restored from is a rumor. The dump half of this
#   pair can succeed nightly for months while producing files that pg_restore
#   would reject — wrong format, truncated, dumped from an empty database
#   after a bad migration. Only a restore proves otherwise, so this runs on a
#   cadence rather than being a thing someone means to check.
#
# WHAT IT PROVES (and what it doesn't)
#   Proves: the newest dump is readable by pg_restore, reconstructs the
#   schema, and carries a non-empty core table set. That is the failure mode
#   that actually bites — a dump that isn't a database.
#   Doesn't prove: byte-equality with production, or that restic can return
#   the file (restic has its own restore drill; see AUDIT.md).
#
# SAFETY
#   The restore target is a throwaway database created and dropped inside the
#   same Postgres instance — production's database is never written, read
#   only for its table list. This mirrors what campaign-settings' own test
#   suite already does per-suite (cs_test_<uuid> throwaway databases), so the
#   pattern is proven on this box.
#
# LOUD FAILURE
#   set -euo pipefail; the throwaway DB is dropped via an EXIT trap so a
#   failure can't leak a database, but the exit status still propagates and
#   fails the unit. Nothing here is wrapped in `|| true`.

set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"

ENV_FILE="$HERE/env/campaign-db.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090  # runtime-resolved env file, absent at lint time
  source "$ENV_FILE"
  set +a
fi

PG_CONTAINER="${CS_PG_CONTAINER:-campaign-settings-postgres}"
DUMP_DIR="${CS_DUMP_DIR:-$HERE/data}"
# Tables that must exist AND be non-empty for a restore to count as good.
# entities + worlds are the irreplaceable content; users gates access to it.
VERIFY_TABLES="${CS_VERIFY_TABLES:-worlds entities users}"

# Overridable so the scripts can be exercised off-box (see campaign-db/README).
# Defaults to the homelab log dir the other units use.
LOG_DIR="${CS_LOG_DIR:-/var/log/homelab}"
LOG_FILE="$LOG_DIR/campaign-db.log"
[ -d "$LOG_DIR" ] || { echo "FATAL: $LOG_DIR not present" >&2; exit 3; }

log() { echo "$(date -Is) campaign-db restore-test: $1" | tee -a "$LOG_FILE"; }

docker inspect "$PG_CONTAINER" >/dev/null 2>&1 || {
  log "FATAL: container $PG_CONTAINER not found"; exit 4; }

container_env() {
  docker inspect "$PG_CONTAINER" --format "{{range .Config.Env}}{{println .}}{{end}}" \
    | sed -n "s/^$1=//p" | head -1
}
PG_USER="${CS_PG_USER:-$(container_env POSTGRES_USER)}"
PG_DB="${CS_PG_DB:-$(container_env POSTGRES_DB)}"
: "${PG_USER:?could not resolve POSTGRES_USER; set CS_PG_USER}"
: "${PG_DB:?could not resolve POSTGRES_DB; set CS_PG_DB}"

NEWEST="$(find "$DUMP_DIR" -maxdepth 1 -name "${PG_DB}-*.dump" -printf '%T@ %p\n' 2>/dev/null \
  | sort -rn | head -1 | cut -d' ' -f2-)"
[ -n "$NEWEST" ] || { log "FATAL: no dump found in $DUMP_DIR — nothing to restore-test"; exit 5; }

AGE_H=$(( ( $(date +%s) - $(stat -c %Y "$NEWEST") ) / 3600 ))
log "restoring $(basename "$NEWEST") (age=${AGE_H}h)"
# A dump that stopped being produced is the 22-day-silent-death shape: the
# restore would keep passing against an ancient file while nightly dumps were
# failing. Age is part of the assertion, not a note in a log.
if [ "$AGE_H" -gt 48 ]; then
  log "FATAL: newest dump is ${AGE_H}h old (>48h) — the nightly dump has stopped"
  exit 6
fi

TARGET_DB="cs_restore_test_$(date -u +%Y%m%d%H%M%S)"
psql_q() { docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d "$1" -tAc "$2"; }

cleanup() {
  docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d postgres \
    -c "DROP DATABASE IF EXISTS $TARGET_DB;" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d postgres \
  -c "CREATE DATABASE $TARGET_DB;" >/dev/null
docker exec -i "$PG_CONTAINER" pg_restore -U "$PG_USER" -d "$TARGET_DB" --no-owner < "$NEWEST" >/dev/null
log "pg_restore ok -> $TARGET_DB"

FAILED=0
for t in $VERIFY_TABLES; do
  restored="$(psql_q "$TARGET_DB" "SELECT count(*) FROM $t;" 2>/dev/null || echo MISSING)"
  if [ "$restored" = "MISSING" ]; then
    log "VERIFY FAIL: table $t absent from the restored database"
    FAILED=1
    continue
  fi
  # Compare against production so a dump taken from an emptied database is
  # caught. Exact equality would be flaky (the dump predates live writes), so
  # assert the restore is non-empty and not wildly short of production.
  #
  # A failed live read is a FAILURE, not a zero. Defaulting it to 0 (as the
  # first version did) silently disarmed the assertion below: with live=0 the
  # "restored 0 but production has rows" case can never fire, so an empty dump
  # would report "verify ok". A check that cannot be made has not passed.
  live="$(psql_q "$PG_DB" "SELECT count(*) FROM $t;" 2>/dev/null || echo UNKNOWN)"
  if [ "$live" = "UNKNOWN" ]; then
    log "VERIFY FAIL: could not read $t from production to compare against — the check could not be made"
    FAILED=1
    continue
  fi
  if [ "$restored" -eq 0 ] && [ "$live" -gt 0 ]; then
    log "VERIFY FAIL: $t restored 0 rows but production has $live"
    FAILED=1
  else
    log "verify ok: $t restored=$restored live=$live"
  fi
done

[ "$FAILED" -eq 0 ] || { log "FATAL: restore verification FAILED for $(basename "$NEWEST")"; exit 7; }
log "restore test PASSED for $(basename "$NEWEST")"
