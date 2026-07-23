# RUNBOOK — rebuild mini-pc infra from this repo

From-scratch, dependency-ordered bring-up of the mini-pc homelab **infra**
from a clean box (or an agent) using only this repo plus the documented secrets.
Reflects the live state as of 2026-07-03 (see `RECONCILE.md`); supersedes the
LAN-era assumptions in the companion recipes (see [§ Companion recipes](#companion-recipes)).

**In scope:** the 8 infra stacks — `caddy`, `gitea`, `gitea-actions`,
`toolkit-server`, `jellyfin`, `nextcloud`, `tailscale`, `restic`.

**Out of scope (do NOT bring up from here):** `campaign-settings`,
`campaign-settings-deploy`, `dm-manager` — application deployments, each tracked in
its own repo and gitignored here.

---

## 0. Host prerequisites

On a fresh box, before any stack:

```sh
# Docker Engine + Compose v2 plugin, restic, tailscale, git, sqlite3.
#   docker: https://docs.docker.com/engine/install/
#   restic: apt install restic        (>= 0.16)
#   tailscale: https://tailscale.com/download/linux
sudo apt-get install -y restic sqlite3
# add your user to the docker group so `docker` runs without sudo:
sudo usermod -aG docker "$USER"   # re-login after this

git clone http://<gitea-host>:3000/sophdn/homelab.git ~/homelab
cd ~/homelab
# Install the env-escape pre-commit hook (blocks unescaped $ in *.env):
ln -sf ../../.git-hooks/pre-commit .git/hooks/pre-commit
```

Data lives on two mounts the stacks bind into; recreate/mount them first:
`/mnt/general/` (nextcloud + jellyfin config/data) and `/mnt/jellyfin/` (media +
the restic backup repo). If restoring, see [§ 8](#8-restore-stateful-data-from-restic).

---

## 1. Secrets: fill every `.env` from its `.env.example`

Every stack that carries a secret sources it from a gitignored `env/<stack>.env`
(chmod 600). Populate them from the committed examples **before** bringing up that
stack. Off-disk copies of un-regenerable values (MariaDB password, restic
passphrase, bcrypt hashes) must be recovered from your password manager / paper
backup — they are NOT in the repo (see README § SECRETS).

```sh
for stack in caddy nextcloud restic; do
  cp $stack/env/$stack.env.example $stack/env/$stack.env
  chmod 600 $stack/env/$stack.env
  $EDITOR $stack/env/$stack.env     # fill placeholders with the real values
done
```

`gitea`, `toolkit-server`, `jellyfin`, `gitea-actions` need no secret `.env`
(gitea/toolkit config is inline + secret-free; jellyfin needs none; the runner's
token lives in the `act_runner_data` volume — see § 4/§ 8).

**Compose `$` gotcha:** literal `$` in an env value (e.g. a bcrypt hash) must be
escaped `$$`, or Compose substitutes it away. The pre-commit hook enforces this;
the `.env.example` files show the pattern.

---

## 2. Bring-up order (dependencies)

```
tailscale (host)  ─┐
                   ├─►  caddy  ──►  gitea  ──►  gitea-actions
                   │                   │
                   │                   └────►  (git remote for toolkit-server binary)
                   ├─►  toolkit-server
                   ├─►  jellyfin
                   └─►  nextcloud
restic (timer) ─── last: needs data present to back up
```

Rationale for the ordering vs. the companion recipes: those bring caddy up first on
`tls internal` (LAN). The live server now serves **Tailscale-issued LE certs**, so
**tailscale must be up and `tailscale cert` run before caddy can serve HTTPS on the
tailnet host.** caddy can still bootstrap LAN-only on `tls internal` if you defer the
tailnet — but to reproduce current reality, do tailscale first.

### 2a. tailscale (host daemon — not a container)

```sh
sudo tailscale up                       # authenticate this node to the tailnet
tailscale status                        # note the MagicDNS name: mini-pc.<tailnet>.ts.net
# Issue the LE cert Caddy will serve (writes into /var/lib/tailscale/certs/):
sudo tailscale cert mini-pc.<tailnet>.ts.net
# ACL policy as code: paste tailscale/acl.json into the admin console
#   https://login.tailscale.com/admin/acls  (adjust group/device placeholders first)
```

Weekly cert refresh is a systemd timer shipped in `caddy/systemd/`
(`tailscale-cert-renew.{service,timer}` → runs `caddy/tailscale-cert-renew.sh`:
`tailscale cert` + `caddy reload`). Install it in § 7.

### 2b. caddy — the reverse-proxy substrate

```sh
cd ~/homelab/caddy && docker compose up -d
```

Fronts every human-reachable service on ports 80/443 (`network_mode: host`). Routes
live as `config/routes/*.caddy` snippets imported by the site block
(`gitea.caddy`, `toolkit-server.caddy`, `portal.caddy`). Serves the Tailscale cert
from `/var/lib/tailscale/certs/` (mounted RO); `tls internal` (Caddy local CA)
remains for the LAN `.local` name. Verify: `curl -k https://mini-pc.<tailnet>.ts.net/healthz` → `ok`.

### 2c. gitea

```sh
cd ~/homelab/gitea && docker compose up -d
```

Creates the **`gitea_default`** Docker network (gitea-actions joins it). Config is
inline in the compose `environment:` (tailnet DOMAIN/ROOT_URL, SSH disabled,
registration disabled, sqlite). First run: open `https://…/git/`, complete the
install screen, create the admin account. DB at `gitea/data/gitea/gitea.db`
(gitignored; restic-backed). Verify: `https://…/git/` → 200.

### 2d. gitea-actions (CI runner) — needs gitea up + a registration token

```sh
# Job containers need the Caddy CA cert at the host path config.yaml expects:
sudo install -D -m0644 gitea-actions/caddy-internal-root.crt /etc/act_runner/caddy-internal-root.crt

cd ~/homelab/gitea-actions
docker volume create act_runner_data                 # NEW runner only (see § 8 to restore)
docker compose up -d
# Register (NEW runner): token from Gitea → Site Admin → Actions → Runners → "Create":
docker compose exec act_runner act_runner register --no-interactive \
  --instance http://gitea:3000/ --token <REGISTRATION_TOKEN> --name mini-pc
docker compose restart act_runner
```

Verify: `docker compose logs act_runner` shows `… declare successfully`. See
`gitea-actions/README.md` for the config-as-code details (the runner's config.yaml +
CA cert are tracked; the token persists in `act_runner_data`, not the repo).

### 2e. toolkit-server

```sh
# The binary is bind-mounted (gitignored), not in the image. Build on the dev box
# and ship it into place:
scp <devbox>:.../toolkit-server ~/homelab/toolkit-server/bin/toolkit-server
cd ~/homelab/toolkit-server
docker compose build --no-cache toolkit-server        # first time / on Node|CLI bumps
docker compose up -d
```

HTTP-only on `127.0.0.1:3001`; Caddy routes `/api/*` (basicauth-gated) to it. Mounts
the host `~/.claude/.credentials.json` RO for the portal chat-relay. DB at
`toolkit-server/data/toolkit.db` (gitignored; restic-backed). Verify:
`curl -k https://…/api/projects` → 401 (auth gate intact).

> Note: the companion `toolkit-server-deploy` recipe documents a `/dashboard/*`
> route — that route is **retired** (no SPA is served); only `/api/*` is live today.

### 2f. jellyfin + nextcloud (independent of the above)

```sh
cd ~/homelab/jellyfin  && docker compose up -d        # host net :8096; media at /mnt/jellyfin
cd ~/homelab/nextcloud && docker compose up -d        # nextcloud + mariadb:11 + redis; 127.0.0.1:8080
```

nextcloud data/db bind-mount under `/mnt/general/nextcloud/{data,db}` — restore
those first if rebuilding (§ 8). Fronted by Caddy on the tailnet host. Verify:
jellyfin `:8096` → 302; nextcloud `:8080` → 200.

### 2g. restic backup (systemd timer) — last

Install the units (§ 7) once the stacks are running and data is in place, so the
first nightly snapshot captures real state.

---

## 7. One-time systemd installs

```sh
# restic nightly backup (runs as root — needs to read container-written files):
sudo cp ~/homelab/restic/systemd/homelab-backup.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now homelab-backup.timer

# Tailscale cert weekly renewal:
sudo cp ~/homelab/caddy/systemd/tailscale-cert-renew.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now tailscale-cert-renew.timer

# Weekly restic restore verification (proves the backup can be READ back):
sudo cp ~/homelab/restic/systemd/homelab-restore-test.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now homelab-restore-test.timer

# Weekly campaign-settings DB restore test (proves the nightly dump restores):
sudo cp ~/homelab/campaign-db/systemd/campaign-db-restore-test.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now campaign-db-restore-test.timer
```

Verify:

```sh
systemctl list-timers | grep -E 'homelab-backup|tailscale-cert|restore-test'
```

Every timer committed under `*/systemd/` must appear in that list. A unit that
lives in this repo but was never installed reads, from the outside, exactly
like a unit that is working — which is how `campaign-db-restore-test.service`
sat un-deployed until an automated poll noticed (bug
`auto-homelab-unit-campaign-db-restore-test-unknown`). It was absent from this
section, so it was never installed. **When you add a unit to this repo, add its
install line here in the same commit.**

---

## 8. Restore stateful data from restic

All `**/data/` dirs and bind-mount targets are gitignored — the ONLY source of
truth for stateful data is the restic repo at
`/mnt/jellyfin/backups/homelab-restic/` (separate NVMe from `/mnt/general`).

```sh
set -a; source ~/homelab/restic/env/restic.env; set +a   # RESTIC_REPOSITORY + RESTIC_PASSWORD
restic snapshots                                          # confirm the repo opens
restic check                                              # integrity

# Full DR restore onto a re-imaged box (recover RESTIC_PASSWORD off-disk first):
restic restore latest --target /
# This repopulates: ~/homelab/**/data (gitea.db, toolkit.db, caddy TLS, act_runner
# via /etc/act_runner), /mnt/general/{jellyfin-docker-config,nextcloud}, and
# /etc/act_runner/. Then run the bring-up order above; existing DBs + the runner's
# /data/.runner registration are already in place, so skip the "NEW runner" steps.

# Partial restore (one path):
restic restore latest --target /tmp/restore --include /home/youruser/homelab/<path>
```

Retention: `--keep-daily 7 --keep-weekly 4 --keep-monthly 6` after each run.
Caveat: snapshots are byte-level mid-transaction (no DB dump pre-hook in v1); the
gitea/toolkit sqlite `.backup` quiesce in `restic/scripts/backup.sh` mitigates this
for those two, mariadb relies on redo-log replay. Off-machine copy is out of scope
for v1 — a single primary-disk failure is recoverable; theft/fire/both-disk is not.

---

## Companion recipes

Detailed, per-service walkthroughs live in the seed-packet repo at
`process-docs/adhoc/network-and-setup-recipes/`:
`caddy-stack-bringup-walkthrough`, `gitea-bring-up-walkthrough`,
`gitea-add-repo-walkthrough`, `toolkit-server-deploy-walkthrough`, and the
`minipc-architecture` decision record.

**They predate the tailnet cutover** (2026-05-06/07) and describe the LAN-era shape:
`mini-pc.local` + `tls internal` as canonical, Tailscale as a "future
follow-up," and a `/dashboard/*` toolkit route. Where they disagree with this
RUNBOOK, **this RUNBOOK is authoritative** for current state; the recipes remain
useful for the fine-grained per-service command detail (Caddyfile snippet mechanics,
gitea first-run, the `handle_path` prefix-strip behaviour). Specifically superseded:
tailnet host + Tailscale LE certs are now primary (arch-doc Decision 2B/3C landed),
the stacks are split (not a `server-compose` bundle), and CI (`gitea-actions`) +
restic backup — both deferred in the arch doc — are now live tracked stacks.
