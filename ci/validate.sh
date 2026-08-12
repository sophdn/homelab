#!/usr/bin/env bash
# Proof-of-parseability for the whole repo: every Compose stack config-checks,
# every shell script passes shellcheck, and the stack/config YAML lints clean.
# Runnable locally (`make validate`) and in CI (.github/workflows/validate.yml).
#
# The point is "does the entire server-as-code actually parse", not deployment.
#
# Every check runs, even after one fails. The old version died at the first
# failing step under `set -e`, which meant a workstation missing yamllint never
# reached the unit tests below it — the gate looked like it ran and had silently
# skipped the most behaviour-relevant check in the file. A gate whose failure
# mode is to stop checking is a gate you cannot read the output of.
#
# A check whose tool is not installed is SKIPPED, reported as such, and still
# exits non-zero. Skips are deliberately not tolerated: CI installs every tool,
# so a skip there would mean the image lost something, and treating it as a pass
# would be the same silent downgrade this structure exists to prevent.
set -uo pipefail
# `set -e` is deliberately absent — see the header. That makes the bare `cd`
# below a real hazard rather than a theoretical one, hence the explicit guard.
cd "$(dirname "$0")/.." || exit 1

# Stacks whose compose uses `env_file:` pointing at a gitignored real env file.
# Stage the committed *.example so `docker compose config` can resolve it, then
# remove it on exit. Values are placeholders — only structure is validated.
ENV_STACKS=(caddy nextcloud)
cleanup() {
  local s
  for s in "${ENV_STACKS[@]}"; do rm -f "$s/env/$s.env"; done
}
trap cleanup EXIT
for s in "${ENV_STACKS[@]}"; do
  cp "$s/env/$s.env.example" "$s/env/$s.env"
done

PASSED=()
FAILED=()
SKIPPED=()

# run_check <label> <required-tool> <command...>
# Records the outcome instead of aborting, so later checks still run.
run_check() {
  local label="$1" tool="$2"
  shift 2
  echo "==> $label"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "    SKIPPED — '$tool' is not installed on this machine"
    SKIPPED+=("$label (needs $tool)")
    return
  fi
  if "$@"; then
    PASSED+=("$label")
  else
    echo "    FAILED — $label"
    FAILED+=("$label")
  fi
}

compose_config() {
  local f rc=0
  for f in */docker-compose.yml; do
    printf '    %s\n' "$f"
    docker compose -f "$f" config -q || rc=1
  done
  return "$rc"
}

run_check "docker compose config (all stacks parse)" docker compose_config

run_check "shellcheck (scripts + git hook)" shellcheck shellcheck \
  restic/scripts/backup.sh \
  campaign-db/scripts/dump.sh \
  campaign-db/scripts/restore-test.sh \
  monitoring/scripts/health-report.sh \
  monitoring/scripts/poll-and-file.sh \
  caddy/tailscale-cert-renew.sh \
  .git-hooks/pre-commit \
  ci/validate.sh \
  scripts/publish-public.sh \
  scripts/secret-scan-tree.sh

run_check "yamllint (compose + gitea-actions config)" yamllint \
  yamllint ./*/docker-compose.yml gitea-actions/config.yaml

run_check "python unit tests (media-ingest parser)" python3 \
  python3 -m unittest discover -s jellyfin/scripts -t jellyfin/scripts -q

echo
echo "── summary ─────────────────────────────────────────────────────────────"
for c in "${PASSED[@]}";  do echo "  pass     $c"; done
for c in "${SKIPPED[@]}"; do echo "  SKIPPED  $c"; done
for c in "${FAILED[@]}";  do echo "  FAILED   $c"; done

if [ ${#FAILED[@]} -gt 0 ]; then
  echo
  echo "${#FAILED[@]} check(s) failed."
  exit 1
fi
if [ ${#SKIPPED[@]} -gt 0 ]; then
  echo
  echo "${#SKIPPED[@]} check(s) could not run because a tool is missing, so this"
  echo "run does NOT clear the gate. Install the tool(s) named above and re-run."
  exit 1
fi

echo
echo "OK — all stacks parse; scripts and YAML lint clean; unit tests pass."
