#!/usr/bin/env bash
# Weekly restic restore verification.
#
# WHY THIS EXISTS
#   A copy you have never restored from is a rumor. The nightly backup can
#   report green for months while writing snapshots that restic cannot return
#   -- a corrupted pack, a repo whose password rotated out from under the env
#   file, a path silently dropped from the backup set. `restic backup` exiting
#   0 proves the write half. Only a restore proves the read half, so this runs
#   on a cadence rather than being a thing someone means to check.
#
#   This is the restic-level counterpart to campaign-db/scripts/restore-test.sh,
#   which proves the Postgres dump is restorable. That one asks "is the dump a
#   database?"; this one asks "can restic give the file back at all?". Both are
#   needed: the campaign dump is only as good as the snapshot holding it.
#
# WHAT IT PROVES (and what it doesn't)
#   Proves: the newest snapshot exists, is not stale, passes restic's own
#   integrity check, and that a RANDOM sample of files restores byte-identical
#   to what is live on disk right now.
#   Doesn't prove: that every file in the repo is good (a full verify would run
#   for hours on this box and is what `restic check --read-data` is for, run by
#   hand during a drill -- see AUDIT.md). Random sampling catches systemic
#   corruption, which is the failure mode that actually bites, without the
#   runtime of an exhaustive pass.
#
# WHY RANDOM RATHER THAN A FIXED LIST
#   A fixed sample gets implicitly whitelisted: the same handful of files pass
#   forever while rot spreads through everything else. Drawing fresh each week
#   means that over time the check walks the whole backup set, and a bad region
#   surfaces on some week rather than never.
#
# SAFETY
#   Restores into a throwaway dir under /tmp that is removed by an EXIT trap.
#   Nothing is ever written over live data -- live files are only read, for the
#   byte comparison.
#
# LOUD FAILURE
#   set -euo pipefail, and every check that cannot be MADE is a failure rather
#   than a pass (the lesson from campaign-db restore-test's live-count bug: a
#   check you could not perform has not passed). A failure leaves the unit red;
#   a pass says nothing beyond a log line.

set -euo pipefail

ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/env/restic.env"
[ -f "$ENV_FILE" ] || { echo "FATAL: $ENV_FILE missing" >&2; exit 2; }
set -a
# shellcheck disable=SC1090  # runtime-resolved env file, absent at lint time
source "$ENV_FILE"
set +a

# Overridable so the script can be exercised off-box, matching campaign-db's
# restore-test. Defaults to the shared homelab log dir the other units use.
LOG_DIR="${HOMELAB_LOG_DIR:-/var/log/homelab}"
LOG_FILE="$LOG_DIR/restore-test.log"
[ -d "$LOG_DIR" ] || { echo "FATAL: $LOG_DIR not present" >&2; exit 3; }

# How many files to pull back each run. Small enough to finish in minutes on a
# mini-PC, large enough that systemic corruption is near-certain to be caught.
SAMPLE_SIZE="${RESTIC_RESTORE_SAMPLE:-25}"
# A snapshot older than this means the nightly backup has stopped. Age is part
# of the assertion, not a note in a log -- this is the 22-day-silent-death
# shape: without it, the restore keeps passing against an ancient snapshot
# while every nightly run fails.
MAX_AGE_H="${RESTIC_MAX_SNAPSHOT_AGE_H:-48}"

log() { echo "$(date -Is) restic restore-test: $1" | tee -a "$LOG_FILE"; }

START=$(date +%s)
log "start (pid=$$)"

RESTORE_DIR="$(mktemp -d /tmp/restic-restore-test.XXXXXX)"
cleanup() { rm -rf "$RESTORE_DIR"; }
trap cleanup EXIT

# ─── 1. Newest snapshot exists and is fresh ───────────────────────────────────
SNAP_ID="$(restic snapshots --tag homelab-data --json 2>>"$LOG_FILE" \
  | jq -r 'sort_by(.time) | last | .short_id // empty')"
[ -n "$SNAP_ID" ] || { log "FATAL: no homelab-data snapshot found -- the nightly backup has never succeeded"; exit 5; }

SNAP_TIME="$(restic snapshots --tag homelab-data --json | jq -r 'sort_by(.time) | last | .time')"
SNAP_EPOCH="$(date -d "$SNAP_TIME" +%s)"
AGE_H=$(( ( $(date +%s) - SNAP_EPOCH ) / 3600 ))
log "newest snapshot $SNAP_ID (age=${AGE_H}h)"
if [ "$AGE_H" -gt "$MAX_AGE_H" ]; then
  log "FATAL: newest snapshot is ${AGE_H}h old (>${MAX_AGE_H}h) -- the nightly backup has stopped"
  exit 6
fi

# ─── 2. Repository integrity ──────────────────────────────────────────────────
# Structural check only (no --read-data): verifies the pack index and that
# every blob the snapshots reference is present. Cheap enough to run weekly;
# --read-data belongs in a hand-run drill.
if ! restic check 2>&1 | tee -a "$LOG_FILE"; then
  log "FATAL: restic check failed -- repository integrity is compromised"
  exit 7
fi
log "repository integrity ok"

# ─── 3. Restore a random sample and byte-compare against live ─────────────────
# Only regular files under /home/youruser/homelab are sampled: that subtree is
# config and state that changes slowly, so a mismatch is meaningful. Data dirs
# that legitimately churn between snapshot and now would produce false alarms.
mapfile -t CANDIDATES < <(restic ls "$SNAP_ID" --long 2>/dev/null \
  | awk '$1 ~ /^-/ && $NF ~ "^/home/youruser/homelab/" {print $NF}' \
  | grep -v -E '\.snapshot$|/\.git/|/data/' \
  || true)

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  log "FATAL: snapshot $SNAP_ID lists no comparable files -- the backup set may have silently emptied"
  exit 8
fi

mapfile -t SAMPLE < <(printf '%s\n' "${CANDIDATES[@]}" | shuf -n "$SAMPLE_SIZE")
log "sampling ${#SAMPLE[@]} of ${#CANDIDATES[@]} eligible files"

# Built as an array rather than an interpolated string so paths containing
# spaces survive: word-splitting a `printf --include %q` line would break the
# first such file, and the failure would look like a corrupt backup.
INCLUDE_ARGS=()
for f in "${SAMPLE[@]}"; do
  INCLUDE_ARGS+=(--include "$f")
done

restic restore "$SNAP_ID" --target "$RESTORE_DIR" \
  "${INCLUDE_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE"

CHECKED=0
MISMATCHED=0
SKIPPED=0
for f in "${SAMPLE[@]}"; do
  restored="$RESTORE_DIR$f"
  if [ ! -f "$restored" ]; then
    log "MISMATCH: $f was in the snapshot listing but did not restore"
    MISMATCHED=$(( MISMATCHED + 1 ))
    continue
  fi
  if [ ! -f "$f" ]; then
    # Deleted since the snapshot. Not a backup defect -- the whole point of a
    # backup is holding files that are no longer live -- so it is not counted
    # against the run. Logged because a large SKIPPED count means the sample is
    # drifting toward files nobody can compare, which weakens the check.
    SKIPPED=$(( SKIPPED + 1 ))
    continue
  fi
  if cmp -s "$restored" "$f"; then
    CHECKED=$(( CHECKED + 1 ))
  else
    # Could be legitimate (the file changed after the snapshot) or corruption.
    # Distinguishing them automatically is not possible from here, so this is
    # reported loudly and a human adjudicates. A false alarm that gets looked
    # at beats a silent corruption that does not.
    log "MISMATCH: $f differs from the restored copy (changed since snapshot, or corrupt)"
    MISMATCHED=$(( MISMATCHED + 1 ))
  fi
done

DURATION=$(( $(date +%s) - START ))

if [ "$MISMATCHED" -gt 0 ]; then
  log "FAILED duration=${DURATION}s -- $MISMATCHED mismatch(es), $CHECKED verified, $SKIPPED skipped"
  exit 9
fi

# A run that compared nothing has proven nothing. Without this, a sample drawn
# entirely from deleted files would exit 0 and read as a healthy restore test.
if [ "$CHECKED" -eq 0 ]; then
  log "FAILED duration=${DURATION}s -- nothing could be compared ($SKIPPED skipped); the check did not run"
  exit 10
fi

log "PASSED duration=${DURATION}s -- $CHECKED file(s) byte-identical, $SKIPPED skipped, snapshot $SNAP_ID"
