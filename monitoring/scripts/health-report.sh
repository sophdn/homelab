#!/usr/bin/env bash
# Emit a JSON health report for this host. Read-only: reports, never fixes,
# never files anything.
#
# HOW IT RUNS
#   Piped over ssh by the observer, NOT installed here:
#     ssh <host> 'bash -s' < monitoring/scripts/health-report.sh
#   So this box needs nothing deployed, and the check logic can never go stale
#   on it the way a copied script would. It versions with the observer.
#
# WHY IT DOESN'T DECIDE ANYTHING
#   Deciding "this is a problem" and filing it belongs to the observer, on a
#   different machine. This half only measures. That split is the whole point:
#   a box cannot be trusted to report its own death, so the thing that raises
#   the alarm must not share fate with the thing being watched. See
#   monitoring/README.md.
#
# UNKNOWN IS NOT OK
#   Every check that cannot run reports status "unknown" with a reason, never
#   "ok". A monitor that silently skips what it can't measure reports health it
#   has not established — which is the failure mode this exists to prevent.

set -uo pipefail

DISK_PCT_WARN="${HOMELAB_DISK_PCT_WARN:-85}"
# Units whose last result is load-bearing. A unit that has never run reports
# unknown, not ok.
UNITS="${HOMELAB_WATCH_UNITS:-homelab-backup.service campaign-db-restore-test.service}"

now_epoch=$(date +%s)

unit_json() {
  local unit="$1" state result ts age
  if ! systemctl list-unit-files "$unit" >/dev/null 2>&1 || \
     [ -z "$(systemctl show "$unit" -p LoadState --value 2>/dev/null)" ] || \
     [ "$(systemctl show "$unit" -p LoadState --value 2>/dev/null)" = "not-found" ]; then
    jq -n --arg u "$unit" '{unit:$u, status:"unknown", reason:"unit not installed on this host"}'
    return
  fi
  result="$(systemctl show "$unit" -p Result --value 2>/dev/null)"
  state="$(systemctl show "$unit" -p ActiveState --value 2>/dev/null)"
  ts="$(systemctl show "$unit" -p ExecMainExitTimestamp --value 2>/dev/null)"
  if [ -z "$ts" ]; then
    jq -n --arg u "$unit" --arg r "${result:-}" \
      '{unit:$u, status:"unknown", reason:"never run (no ExecMainExitTimestamp)", result:$r}'
    return
  fi
  age=$(( (now_epoch - $(date -d "$ts" +%s 2>/dev/null || echo "$now_epoch")) / 3600 ))
  jq -n --arg u "$unit" --arg r "$result" --arg s "$state" --argjson a "$age" \
    '{unit:$u, status:(if $r=="success" then "ok" else "fail" end), result:$r, active_state:$s, last_run_age_h:$a}'
}

disk_json() {
  # pcent per real block device mount. Reported as a number so the observer
  # owns the threshold rather than this script hiding one.
  # NB: no -P — it conflicts with --output on GNU df and silently yields
  # nothing, which is how the first draft of this reported zero disks.
  df --output=source,pcent,target 2>/dev/null | awk 'NR>1 && $1 ~ /^\/dev/ {gsub(/%/,"",$2); print $1, $2, $3}' \
    | while read -r src pct target; do
        jq -n --arg s "$src" --arg t "$target" --argjson p "$pct" --argjson w "$DISK_PCT_WARN" \
          '{source:$s, mount:$t, pct_used:$p, status:(if $p >= $w then "fail" else "ok" end)}'
      done | jq -s '.'
}

# Reading SMART off an NVMe needs root — as a normal user smartctl exits 2 with
# "Permission denied" (verified). This poll arrives over ssh as an unprivileged
# user, so plain smartctl would always report unknown even with smartmontools
# installed. Prefer passwordless sudo, fall back to a bare call so a host that
# grants access another way (a group, a udev rule) still works.
#   Needed on the target, once:
#     sudo apt install smartmontools
#     echo "$USER ALL=(root) NOPASSWD: /usr/sbin/smartctl" | sudo tee /etc/sudoers.d/smartctl-health
smartctl_cmd() {
  if sudo -n /usr/sbin/smartctl -V >/dev/null 2>&1; then
    sudo -n /usr/sbin/smartctl "$@"
  else
    smartctl "$@"
  fi
}

smart_json() {
  if ! command -v smartctl >/dev/null 2>&1 && ! sudo -n /usr/sbin/smartctl -V >/dev/null 2>&1; then
    # NOT "ok". The disks may well be failing; we simply cannot see. The
    # observer files this as its own finding rather than assuming health.
    jq -n '{status:"unknown", reason:"smartctl not installed on THIS host (sudo apt install smartmontools); disk health is UNMEASURED"}'
    return
  fi
  local out
  out="$(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}' | while read -r d; do
    local health
    health="$(smartctl_cmd -H "/dev/$d" 2>/dev/null | grep -iE "overall-health|SMART Health Status" | head -1)"
    if [ -z "$health" ]; then
      jq -n --arg d "$d" '{device:$d, status:"unknown", reason:"smartctl gave no health line — NVMe SMART needs root; add a NOPASSWD sudoers rule for smartctl (see monitoring/README.md)"}'
    elif printf '%s' "$health" | grep -qiE "PASSED|OK"; then
      jq -n --arg d "$d" '{device:$d, status:"ok"}'
    else
      jq -n --arg d "$d" --arg h "$health" '{device:$d, status:"fail", detail:$h}'
    fi
  done | jq -s '.')"
  jq -n --argjson disks "$out" '{status:"measured", disks:$disks}'
}

# Freshness of the artifacts other backups leave behind. An artifact that stops
# being refreshed is the silent-death signature: nothing errors, the file just
# quietly ages.
artifact_json() {
  # dir + pattern are separate so the pattern never rides through an unquoted
  # expansion — find does the matching, no shell glob involved.
  local name="$1" dir="$2" pattern="$3" max_age_h="$4" newest age
  newest="$(find "$dir" -maxdepth 1 -name "$pattern" -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-)"
  if [ -z "$newest" ] || [ ! -e "$newest" ]; then
    jq -n --arg n "$name" --arg p "$dir/$pattern" '{name:$n, status:"fail", reason:"no artifact matching \($p)"}'
    return
  fi
  age=$(( (now_epoch - $(stat -c %Y "$newest")) / 3600 ))
  jq -n --arg n "$name" --arg f "$newest" --argjson a "$age" --argjson m "$max_age_h" \
    '{name:$n, file:$f, age_h:$a, max_age_h:$m, status:(if $a > $m then "fail" else "ok" end)}'
}

units_out="$(for u in $UNITS; do unit_json "$u"; done | jq -s '.')"
artifacts_out="$(
  {
    artifact_json "campaign-db-dump" "$HOME/homelab/campaign-db/data" '*.dump' 48
    artifact_json "toolkit-ledger-snapshot" "$HOME/homelab/toolkit-ledger/data" 'toolkit.db.snapshot' 48
  } | jq -s '.'
)"

jq -n \
  --arg host "$(hostname)" \
  --arg ts "$(date -Is)" \
  --argjson units "$units_out" \
  --argjson disks "$(disk_json)" \
  --argjson smart "$(smart_json)" \
  --argjson artifacts "$artifacts_out" \
  '{host:$host, ts:$ts, units:$units, disks:$disks, smart:$smart, artifacts:$artifacts}'
