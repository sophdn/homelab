#!/usr/bin/env bash
# Poll a host's health and file what's wrong as BUGS in the work ledger.
#
# WHY BUGS AND NOT A PUSH NOTIFICATION
#   For anything actionable and durable — a failed backup, a disk filling, a
#   dump that stopped being produced — a bug beats a notification. A push buzzes
#   once, gets swiped, and leaves no record that anyone saw it. A bug has state,
#   dedupe, severity and a resolution: it stays until it is genuinely dealt
#   with, and it lands in the surface that is already read daily rather than in
#   a logfile nobody opens. It also keeps the stack owned — no third-party
#   channel, no account, no token.
#
# WHY THE OBSERVER POLLS INSTEAD OF THE BOX REPORTING
#   This is the load-bearing decision. A bug filed BY the failing box cannot be
#   filed when the box is the thing that is broken — disk full, docker dead, box
#   off, network gone. And nobody files a "backup succeeded" bug, so silence
#   would never distinguish healthy from dead. That is exactly the shape that
#   let a peer's backups run dead for 22 days: every safeguard failed quietly.
#
#   So the alarm must not share fate with what it watches. This runs on the
#   OBSERVER — a different machine, the one holding the ledger — reaches out,
#   and files what it finds. Absence is therefore detectable: if the host cannot
#   be reached at all, that is itself a finding, filed like any other.
#
# WHY UNKNOWN IS FILED, NOT SKIPPED
#   health-report.sh reports "unknown" for anything it cannot measure (SMART
#   with no smartctl, a unit that was never installed). Unknown is not ok — the
#   disks may be dying and we simply cannot see. A monitor that quietly skips
#   what it cannot measure is reporting health it never established, so unknowns
#   are filed too, at low severity.
#
# IDEMPOTENCE
#   Slugs are deterministic and prefixed `auto-<host>-`. An existing OPEN bug is
#   left alone rather than re-filed, so a persistent fault does not spam the
#   ledger. When a condition clears, its bug is resolved automatically — that
#   state transition is the thing a notification could never give us. Only bugs
#   this script filed (by prefix) are ever touched; a human-filed bug is never
#   auto-resolved.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

CFG="${HOMELAB_MONITOR_ENV:-$HOME/.config/homelab-monitor/monitor.env}"
if [ -f "$CFG" ]; then
  set -a
  # shellcheck disable=SC1090  # runtime-resolved config, absent at lint time
  source "$CFG"
  set +a
fi

# Required. No defaults: a monitoring target and a ledger URL are deployment
# config, not source — hardcoding them would put infra identifiers in a repo
# that publishes a public mirror.
TARGET="${HOMELAB_MONITOR_TARGET:-}"
TOOLKIT_URL="${HOMELAB_MONITOR_TOOLKIT_URL:-}"
PROJECT="${HOMELAB_MONITOR_PROJECT:-homelab}"
DRY_RUN="${HOMELAB_MONITOR_DRY_RUN:-0}"

if [ -z "$TARGET" ] || [ -z "$TOOLKIT_URL" ]; then
  echo "FATAL: HOMELAB_MONITOR_TARGET and HOMELAB_MONITOR_TOOLKIT_URL must be set." >&2
  echo "  Copy monitoring/monitor.env.example to $CFG and fill it in." >&2
  exit 2
fi

# Goes into every bug slug, so keep it short, stable and human. It deliberately
# does NOT derive from TARGET: that would bake a hostname or IP into every slug
# in the ledger, and a slug is forever — re-tagging later orphans the dedupe and
# a fault re-files under a new name.
HOST_TAG="${HOMELAB_MONITOR_HOST_TAG:-homelab}"

log() { echo "$(date -Is) monitor: $1"; }

# ─── ledger client ────────────────────────────────────────────────────────────
work() { # work <action> <params-json> [rationale]
  local action="$1" params="$2" rationale="${3:-}"
  jq -n --arg a "$action" --argjson p "$params" --arg pr "$PROJECT" --arg r "$rationale" \
    '{action:$a, params:$p, project:$pr} + (if $r == "" then {} else {rationale:$r} end)' \
    | curl -sS --max-time 30 -X POST "$TOOLKIT_URL/mcp/work" \
        -H 'Content-Type: application/json' \
        -H 'X-MCP-Actor: homelab-health-poller' \
        --data-binary @-
}

open_bug_slugs() {
  work bug_list '{"status":"open","limit":500}' \
    | jq -r '(if type=="array" then . else (.bugs // []) end)[] | .slug' 2>/dev/null || true
}

file_bug() { # file_bug <slug> <title> <severity> <problem> <acceptance>
  local slug="$1" title="$2" sev="$3" problem="$4" accept="$5"
  if printf '%s\n' "$OPEN_SLUGS" | grep -qxF "$slug"; then
    log "already open, not re-filing: $slug"
    return
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY-RUN would file [$sev] $slug"
    return
  fi
  local params
  params="$(jq -n --arg s "$slug" --arg t "$title" --arg sv "$sev" --arg p "$problem" --arg a "$accept" \
    --arg src "homelab-health-poller (automated, observer-side poll of $TARGET)" \
    '{kind:"bug", slug:$s, title:$t, severity:$sv, problem_statement:$p,
      acceptance_criteria:$a, surface:"homelab,monitoring,automated", source:$src}')"
  work forge "$params" "Automated health poll of $TARGET found this condition. Filed by the observer, not by the monitored host, so it is reported even when that host is the thing that is broken." >/dev/null
  log "FILED [$sev] $slug"
}

clear_bug() { # clear_bug <slug> <why>
  local slug="$1" why="$2"
  printf '%s\n' "$OPEN_SLUGS" | grep -qxF "$slug" || return 0
  case "$slug" in
    auto-*) : ;;   # only ever touch what this poller filed
    *) return 0 ;;
  esac
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY-RUN would resolve $slug"
    return
  fi
  local params
  # 'unversioned' is the sentinel for a resolution whose artifact lives outside
  # version control — nothing was committed here, the condition simply cleared.
  params="$(jq -n --arg s "$slug" --arg n "$why" \
    '{slug:$s, resolution_kind:"fixed", commit_sha:"unversioned", resolution_note:$n}')"
  work bug_resolve "$params" "Automated health poll: the condition cleared." >/dev/null
  log "RESOLVED (condition cleared): $slug"
}

# ─── collect ──────────────────────────────────────────────────────────────────
OPEN_SLUGS="$(open_bug_slugs)"
UNREACHABLE_SLUG="auto-${HOST_TAG}-unreachable"

REPORT="$(timeout 60 ssh -o BatchMode=yes -o ConnectTimeout=15 "$TARGET" 'bash -s' < "$HERE/health-report.sh" 2>/dev/null || true)"

if [ -z "$REPORT" ] || ! printf '%s' "$REPORT" | jq -e . >/dev/null 2>&1; then
  # THE deadman. A host that cannot be reached reports nothing, and nothing is
  # indistinguishable from healthy unless someone is looking. Someone is.
  file_bug "$UNREACHABLE_SLUG" \
    "Health poll cannot reach ${TARGET#*@} — it is unmonitored, and possibly down" \
    "high" \
    "The automated health poll could not reach ${TARGET#*@} over ssh, or it returned nothing parseable. Nothing is known about its backups, disks or units right now. This is filed by the OBSERVER precisely because a host that is down cannot report that it is down. Check: is the box up, is tailscale up, did ssh key auth break?" \
    "- the host answers the health poll again, or\n- the outage is understood and this bug is closed deliberately"
  log "target unreachable — filed $UNREACHABLE_SLUG"
  exit 1
fi
clear_bug "$UNREACHABLE_SLUG" "The host answered the health poll again."

# ─── evaluate ─────────────────────────────────────────────────────────────────
FINDINGS=0

# units
while read -r unit status reason result age; do
  [ -n "$unit" ] || continue
  slug="auto-${HOST_TAG}-unit-$(printf '%s' "$unit" | sed 's/\.service$//; s/[^a-zA-Z0-9]/-/g')"
  case "$status" in
    fail)
      FINDINGS=$((FINDINGS+1))
      file_bug "$slug" "$unit failed on ${TARGET#*@} (result=$result)" "high" \
        "systemd reports Result=$result for $unit on ${TARGET#*@}; its last run was ${age}h ago. A failed backup-adjacent unit is the exact silent failure this monitoring exists to surface — it would otherwise sit as a red unit nobody runs systemctl against. Investigate with: journalctl -u $unit -n 100" \
        "- $unit runs to Result=success again\n- if it failed for a real reason, that reason is fixed rather than the unit being ignored"
      ;;
    unknown)
      FINDINGS=$((FINDINGS+1))
      file_bug "$slug-unknown" "$unit is not installed on ${TARGET#*@} — it is not running at all" "medium" \
        "The health poll expected $unit on ${TARGET#*@} but: $reason. This is filed rather than skipped because 'never ran' looks identical to 'nothing wrong' from the outside — which is how a job that was never deployed passes for a job that is working." \
        "- $unit is installed and enabled, or\n- it is deliberately not wanted here and is removed from HOMELAB_WATCH_UNITS"
      ;;
    ok) clear_bug "$slug" "$unit reports Result=success (last run ${age}h ago)."
        clear_bug "$slug-unknown" "$unit is installed and reporting again." ;;
  esac
done < <(printf '%s' "$REPORT" | jq -r '.units[] | [.unit, .status, (.reason // "-"), (.result // "-"), (.last_run_age_h // 0)] | @tsv')

# disks
while read -r source mount pct status; do
  [ -n "$source" ] || continue
  slug="auto-${HOST_TAG}-disk-$(printf '%s' "$mount" | sed 's#^/$#root#; s#[^a-zA-Z0-9]#-#g')"
  if [ "$status" = "fail" ]; then
    FINDINGS=$((FINDINGS+1))
    file_bug "$slug" "$mount is ${pct}% full on ${TARGET#*@}" "high" \
      "$source mounted at $mount is ${pct}% used on ${TARGET#*@}. A full disk takes the backups down with everything else, and does it quietly — restic simply starts failing." \
      "- $mount is back under the warn threshold\n- or the threshold is deliberately raised with a reason"
  else
    clear_bug "$slug" "$mount is back to ${pct}% used."
  fi
done < <(printf '%s' "$REPORT" | jq -r '.disks[] | [.source, .mount, .pct_used, .status] | @tsv')

# smart
SMART_STATUS="$(printf '%s' "$REPORT" | jq -r '.smart.status')"
SMART_SLUG="auto-${HOST_TAG}-smart-unmeasured"
if [ "$SMART_STATUS" = "unknown" ]; then
  FINDINGS=$((FINDINGS+1))
  file_bug "$SMART_SLUG" "Disk health on ${TARGET#*@} is UNMEASURED (no smartctl)" "medium" \
    "$(printf '%s' "$REPORT" | jq -r '.smart.reason') Filed rather than skipped: an unmeasured disk is not a healthy disk. Impending drive failure is one of the few things that gives warning, and right now that warning is not being read. Fix: apt install smartmontools on ${TARGET#*@} (needs sudo), then this poll starts reporting real SMART health and this bug auto-resolves." \
    "- smartctl is installed on the host\n- the health poll reports smart.status=measured\n- a failing drive would raise its own bug"
else
  clear_bug "$SMART_SLUG" "smartctl is present; SMART health is being measured again."
  while read -r device status detail; do
    [ -n "$device" ] || continue
    dslug="auto-${HOST_TAG}-smart-$device"
    if [ "$status" = "fail" ]; then
      FINDINGS=$((FINDINGS+1))
      file_bug "$dslug" "SMART reports /dev/$device UNHEALTHY on ${TARGET#*@}" "high" \
        "smartctl -H /dev/$device on ${TARGET#*@} reports: $detail. A drive that SMART is complaining about is the one warning you get before it takes the data with it. Verify the backups of anything on this drive can actually be restored BEFORE replacing it." \
        "- the drive is replaced, or the reading is understood to be benign and recorded as such"
    else
      clear_bug "$dslug" "SMART reports /dev/$device healthy again."
    fi
  done < <(printf '%s' "$REPORT" | jq -r '.smart.disks[]? | [.device, .status, (.detail // "-")] | @tsv')
fi

# artifacts — the silent-death detector: nothing errors, the file just ages
while read -r name status age max reason; do
  [ -n "$name" ] || continue
  slug="auto-${HOST_TAG}-artifact-$name"
  if [ "$status" = "fail" ]; then
    FINDINGS=$((FINDINGS+1))
    file_bug "$slug" "Backup artifact '$name' is missing or stale on ${TARGET#*@}" "high" \
      "The health poll expected a fresh '$name' on ${TARGET#*@}: ${reason:--} (age=${age}h, max=${max}h). An artifact that stops being refreshed is the signature of a backup that died quietly — no error is raised, the file simply gets older while everything looks fine. That is precisely how a peer's backups were dead for 22 days." \
      "- '$name' is fresh again (age under its max), meaning the job that produces it is running\n- or it is deliberately retired and removed from health-report.sh"
  else
    clear_bug "$slug" "'$name' is fresh again (age ${age}h)."
  fi
done < <(printf '%s' "$REPORT" | jq -r '.artifacts[] | [.name, .status, (.age_h // 0), (.max_age_h // 0), (.reason // "-")] | @tsv')

log "poll complete: $FINDINGS finding(s) on ${TARGET#*@}"
# Exit 0 even with findings: the findings ARE the report, and they are already
# in the ledger. Failing the unit here would just be a second, worse channel
# saying the same thing — and would make a persistent known fault look like a
# broken poller.
exit 0
