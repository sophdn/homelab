#!/usr/bin/env bash
# Proof-of-parseability for the whole repo: every Compose stack config-checks,
# every shell script passes shellcheck, and the stack/config YAML lints clean.
# Runnable locally (`make validate`) and in CI (.github/workflows/validate.yml).
#
# The point is "does the entire server-as-code actually parse", not deployment.
set -euo pipefail
cd "$(dirname "$0")/.."

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

echo "==> docker compose config (all stacks parse)"
for f in */docker-compose.yml; do
  printf '    %s\n' "$f"
  docker compose -f "$f" config -q
done

echo "==> shellcheck (scripts + git hook)"
shellcheck \
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

echo "==> yamllint (compose + gitea-actions config)"
yamllint ./*/docker-compose.yml gitea-actions/config.yaml

echo "OK — all stacks parse; scripts and YAML lint clean."
