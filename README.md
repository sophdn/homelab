# homelab

Compose-managed services on **mini-pc** (mini-PC). Primary ingress is the tailnet host `mini-pc.tailnet-name.ts.net` (Tailscale, with Tailscale-issued Let's Encrypt certs); the LAN/mDNS name `mini-pc.local` (192.0.2.10, Caddy internal CA) still works on the local network. Single source of truth for the configuration of everything currently scoped to the home server.

> Application deployments (`campaign-settings`, `campaign-settings-deploy`, `dm-manager`) run on this box but are **intentionally excluded** from this infra repo — each is tracked in its own repo and gitignored here.

## Layout

One subdirectory per Compose stack. Each subdir is self-contained: `docker-compose.yml` + any config trees + an `env/` directory with `.env.example` committed and `.env` gitignored.

```
homelab/
├── caddy/             # reverse proxy (network_mode: host); fronts every service on tailnet + LAN
├── gitea/             # git hosting at https://mini-pc.tailnet-name.ts.net/git/
├── gitea-actions/     # act_runner — Gitea Actions CI runner (joins gitea_default)
├── toolkit-server/    # MCP toolkit deployed instance, HTTP-only, 127.0.0.1:3001
├── jellyfin/          # media server (host net :8096)
├── nextcloud/         # file sync: nextcloud + mariadb + redis, 127.0.0.1:8080
├── tailscale/         # tailnet config-as-code (ACL policy); the daemon runs on the host
├── restic/            # nightly encrypted backup (systemd timer): scripts + units
├── RUNBOOK.md         # from-scratch, dependency-ordered infra bring-up + restore
├── AUDIT.md           # 2026-05-07 Phase-B audit + consolidation log (historical)
├── RECONCILE.md       # 2026-07-03 live-vs-repo reconciliation gap list
└── README.md
```

Runtime data (`*/data/`) is bind-mounted from the host but git-ignored; protected by T7 (restic).

## Edit workflow

1. Edit on the mini-PC working copy (`youruser@192.0.2.10:~/homelab/`).
2. `git commit` and `git push origin main` — origin is the Gitea repo on this same box.
3. Owner runs `docker compose up -d` in the affected subdir manually. No auto-redeploy in v1.

## Stacks at a glance

| Stack | Compose project | Exposed | Notes |
|-------|-----------------|---------|-------|
| caddy | caddy | host (80/443) | Routes `/healthz`, `/git/*`, `/api/*` (basicauth-gated); tailnet + LAN sites |
| gitea | gitea | 127.0.0.1:3000 (via caddy /git/) | Sqlite DB at gitea/data/gitea/gitea.db |
| gitea-actions | gitea-actions | none (dials out to Gitea) | act_runner CI; joins `gitea_default`; registration persists in the external `act_runner_data` volume |
| toolkit-server | toolkit-server | 127.0.0.1:3001 (via caddy /api/) | HTTP-only deployed instance; binary mounted from `bin/`, gitignored |
| jellyfin | jellyfin | host:8096 | Media server |
| nextcloud | nextcloud | 127.0.0.1:8080 | `nextcloud:apache` + `mariadb:11` + `redis:alpine`; data/db under `/mnt/general/nextcloud/` |
| tailscale | (host daemon) | tailnet | ACL policy as code (`acl.json`); Tailscale runs on the host, not as a container |
| restic | (systemd timer) | — | Nightly encrypted backup; `homelab-backup.{service,timer}` |

## SECRETS — env_file convention (T6)

Every secret-shaped value is sourced from a per-stack `env/<stack>.env` file rather than baked inline into compose stanzas or config files. Real `.env` files are gitignored (chmod 600); `.env.example` files are committed with placeholder values and explanatory comments.

### Layout

```
caddy/env/
  caddy.env           # gitignored — real values, chmod 600
  caddy.env.example   # committed — placeholders + comments

nextcloud/env/
  nextcloud.env       # gitignored — real values (incl. MariaDB password), chmod 600
  nextcloud.env.example

restic/env/
  restic.env          # gitignored — restic passphrase + repo location
  restic.env.example

gitea/env/
  gitea.env.example   # placeholder reservation; gitea config is inline + secret-free

toolkit-server/env/
  toolkit-server.env.example   # placeholder reservation; compose config is inline + secret-free
```

(`jellyfin` needs no env file; `gitea-actions` carries no secret in-repo — its
registration token lives in the external `act_runner_data` volume.)

### Bootstrapping a fresh box

```bash
git clone <gitea-url>/sophdn/homelab.git ~/homelab
cd ~/homelab
for stack in caddy nextcloud restic; do
  cp $stack/env/$stack.env.example $stack/env/$stack.env
  chmod 600 $stack/env/$stack.env
  $EDITOR $stack/env/$stack.env  # fill placeholders with real values
done
docker compose up -d  # in each stack subdir
```

### Compose `$VAR` substitution gotcha

**Docker Compose v2 applies `${VAR}` and `$VAR` substitution to values loaded via `env_file:`.** A literal `$` in a value (e.g. inside a bcrypt hash like `$2a$14$...`) must be escaped as `$$`. Otherwise compose treats fragments after `$` as variable references and silently substitutes blank strings. Symptom: an env value arrives at the container truncated, with characters between `$` markers missing.

The example files in this repo show the escaping pattern. Bcrypt hashes in particular are double-escaped:

```
BASIC_AUTH_HASH_CLAUDE=$$2a$$14$$<rest-of-hash>
```

A pre-commit hook at `.git-hooks/pre-commit` blocks staged `*.env` files with unescaped `$` followed by a letter / underscore / `{`. Install once per clone:

```bash
ln -sf ../../.git-hooks/pre-commit .git/hooks/pre-commit
```

### Where the passphrase backups live

Real `.env` values that cannot be regenerated (db credentials with already-initialized data, bcrypt hashes for shared accounts, future restic encryption passphrase) MUST be backed up off this disk:
- A password manager entry, OR
- A printed paper copy in a physical safe location, OR
- An encrypted file on a different machine/drive.

If both the `.env` files and the encrypted-backup target (T7 restic repo) live on the same physical disk, a disk failure loses everything together. Treat this as load-bearing — if you skip it once, the system has no recovery story.

### What is NOT in env/

- **Gitea internal secrets** (`SECRET_KEY`, `INTERNAL_TOKEN`, `JWT_SECRET`, `LFS_JWT_SECRET`) live in `gitea/data/gitea/conf/app.ini`, generated and rotated by gitea itself. The `data/` subtree is gitignored; backed up by T7.
- **Caddy auto-issued TLS material** lives in `caddy/data/`. Gitignored; regeneratable but inconvenient on restore (Caddy re-derives from `tls internal`). Backed up by T7.

## Outside this repo by design

| Path | Reason |
|------|--------|
| `/var/lib/dm-toolkit/` | dm-toolkit deployment pipeline state (bare repo + last-good-master symlink). Owned by `youruser` (NOT root, contrary to earlier audit notes). Distinct surface; the post-receive hook for that pipeline currently does not exist on disk. |
| `/etc/act_runner/caddy-internal-root.crt` | Host path the `gitea-actions` runner mounts into each **job** container for TLS trust to Caddy-fronted Gitea. The committed copy lives in `gitea-actions/`; on a fresh box install it here (see `gitea-actions/README.md`). |
| `/mnt/general/jellyfin-docker-config/` | Bind-mount target for jellyfin (config + cache). Runtime data, not config. |
| `/mnt/general/nextcloud/{data,db}/` | Bind-mount targets for nextcloud (user files + mariadb). Runtime data. |
| `/mnt/jellyfin/*` | Media library. Regeneratable from external sources. Out of T7 backup scope. |

The `act_runner` container (started 2026-05-07) was promoted from a bare `docker run` into the tracked `gitea-actions/` Compose stack on 2026-07-03; its config + CA cert are now config-as-code and its registration persists in the external `act_runner_data` volume.

## Roadmap pointers

- T7 (`backup-strategy-restic`) lands `scripts/backup.sh` + a systemd timer + a restore drill, and updates this README with a BACKUP section.

## Verified state at T6 close

Smoke gate passing as of last commit:
- `https://mini-pc.local/healthz` → `ok`
- `https://mini-pc.local/git/` → 200
- `https://mini-pc.local/api/projects` (no auth) → 401 (basicauth gate intact post env_file extraction)
- `http://localhost:8096/` (jellyfin) → 302 (healthy, post env_file extraction)
- `http://localhost:8080/` (nextcloud) → 200 (post env_file extraction)
- `nextcloud_db mysqladmin ping` → alive (post env_file extraction)
- Container env dump confirms `BASIC_AUTH_HASH_CLAUDE=$2a$14$...` (full bcrypt) and `MYSQL_*` set correctly on caddy / mariadb / nextcloud

## Autonomy — loud, not silent

This box is meant to run unattended, and the main enemy of an unattended box is
**silent failure**. So: autonomous means idempotent, self-healing, and LOUD
about what it couldn't do — never "runs silently and hopes".

Two rules follow, and they are enforced rather than aspirational:

- **No `|| true` / `2>/dev/null` on a job that must be able to warn.** A job
  that cannot fail cannot warn. Where those appear here, they feed a decision
  that still surfaces (a failed dump is re-raised at the end of the backup run;
  an unreachable host becomes a filed bug).
- **A check that cannot run reports `unknown`, never `ok`,** and unknown is
  filed. Health that was never established is not health.

Findings are filed as **bugs in the work ledger** by an observer on another
machine — see [monitoring/](monitoring/README.md). The box does not report on
itself, because a box cannot report its own death.

## BACKUP — restic (T7)

### What gets backed up

Restic snapshot taken nightly at 03:00 local (with up to 10 min random delay) covers:
- `/home/youruser/homelab/` (config + state + env files; excludes `.git/objects/pack/*` since git history is recoverable from Gitea origin)
- `/mnt/general/jellyfin-docker-config/` (jellyfin metadata + watch state)
- `/mnt/general/nextcloud/` (data + db)
- `/var/lib/dm-toolkit/` (dm-toolkit deployment-pipeline state)
- `/etc/act_runner/` (root-owned act_runner config)
- the **campaign-settings Postgres**, via a `pg_dump` written into `campaign-db/data/` during the pre-backup quiesce — see [campaign-db](campaign-db/README.md).

**A container's data is not backed up just because the container runs here.** Anything storing state in a docker *volume* lives under `/var/lib/docker/volumes/`, which is in none of the paths above. That is exactly how the campaign Postgres — years of irreplaceable creative work — went unbacked-up until 2026-07-15: the stack was deployed under `/home/youruser/homelab`, so it looked covered, while its actual data sat in a volume outside every backup path. When adding a stateful service, check where its data really lives before assuming this list covers it.

Excluded by intent: `/mnt/jellyfin/*` (media library — regeneratable; also where the backup repo lives, so backing it up to itself would be circular).

### Where it goes

Encrypted restic repo at `/mnt/jellyfin/backups/homelab-restic/`. Separate physical NVMe from `/mnt/general` (where most data lives), so single-disk failure on the primary disk is recoverable.

**Off-machine destination is OUT OF SCOPE for v1.** Remote target (S3 / B2 / a second box / external drive rotation) is a deferred follow-up. Today's backups survive single-disk failure on the primary; they do NOT survive both-disk failure, theft, or fire.

### Encryption passphrase

Generated at T7 (2026-05-07) from `/dev/urandom`. Stored:
- On disk: `~/homelab/restic/env/restic.env` (gitignored, chmod 600).
- Off disk: **owner-managed** — paper, password manager, or encrypted file on a different machine.

If both copies are lost, the repo is unrecoverable. This is non-negotiable; restic refuses unencrypted repos by design.

### Schedule

```
homelab-backup.timer    : OnCalendar=*-*-* 03:00:00, RandomizedDelaySec=10min
homelab-backup.service  : Type=oneshot, User=root, runs scripts/backup.sh
```

User=root is required because container-written files (mariadb data, gitea state, caddy TLS) are not all readable by `youruser`. Live-DB consistency risk acknowledged in the follow-up bug `homelab-restic-live-db-consistency-risk` (no DB dump pre-hook in v1; restic captures bytes mid-transaction; mariadb's redo log makes a recovered snapshot likely-but-not-guaranteed-replayable).

### Retention

`restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune` runs after each backup. Effective retention: ~6 months (with daily granularity for the most recent week, weekly granularity for the most recent month, monthly granularity beyond).

### Manual operations

```bash
# Source the env
set -a; source ~/homelab/restic/env/restic.env; set +a

# List snapshots
restic snapshots

# Browse a snapshot interactively
restic mount /tmp/restic-mount   # then ls /tmp/restic-mount/snapshots/...

# Partial restore (one path from latest snapshot)
restic restore latest --target /tmp/restore --include /home/youruser/homelab/<path>

# Full DR restore (re-imaged box)
# 1. Install OS, install docker, install restic
# 2. Recover RESTIC_PASSWORD from off-disk backup
# 3. RESTIC_REPOSITORY=<external/restored/repo>; RESTIC_PASSWORD=<recovered>
# 4. restic restore latest --target /
# 5. cd ~/homelab && for d in caddy gitea toolkit-server nextcloud restic; do
#      cp $d/env/$d.env.example $d/env/$d.env; $EDITOR $d/env/$d.env
#    done
# 6. docker compose up -d   (in each subdir)

# Verify repo integrity
restic check
```

### Loud-failure surface

A failed nightly backup leaves the unit in `failed` state:

```bash
systemctl status homelab-backup.service     # current run state
journalctl -u homelab-backup.service        # full output incl. restic errors
systemctl --failed                          # any failed units
tail -50 /var/log/homelab/backup.log        # tee'd output for grep-friendly review
```

DM_TOOLKIT_NOTIFY (push notification) is NOT wired to backup failure in v1 — when that env value lands (per T6 hand-off), the `OnFailure=` directive in the unit can call a notify helper. Tracked as a follow-up.

## PORTAL — write-API + chat (portal-write-api task 5)

Adds the tailnet-bound HTTP write surface that drives toolkit-server
from off-mini-PC clients (phone, laptop, anywhere on the tailnet).

### One-time bring-up

1. **Build the custom toolkit-server image** (Node 22 + claude CLI):
   ```bash
   cd ~/homelab/toolkit-server
   docker compose build --no-cache toolkit-server
   ```
   This bakes Node 22 + `@anthropic-ai/claude-code` into the image
   so the portal chat-relay's `claude -p` spawn finds claude on
   PATH. Rebuild ONLY on Node-version bumps or claude CLI updates;
   day-to-day toolkit-server binary updates ship via the bind-mount.

2. **Update `caddy/env/caddy.env`** (your real env file, gitignored):
   ```
   TAILNET_PORTAL_HOST=mini-pc.<tailnet-name>.ts.net
   ```
   Find the tailnet name in https://login.tailscale.com/admin/dns —
   "Tailnet name" near the top.

3. **Paste `tailscale/acl.json`** into the admin console:
   https://login.tailscale.com/admin/acls — the file is meant to
   replace the existing JSON wholesale. Read its header first; the
   placeholders (group identity, device name) likely need adjusting
   before paste.

4. **Reload Caddy + restart toolkit-server**:
   ```bash
   ssh youruser@192.0.2.10 'cd ~/homelab/caddy && docker compose restart && \
                          cd ~/homelab/toolkit-server && docker compose up -d'
   ```
   The new portal site block appears in `docker compose logs caddy`
   alongside the existing mini-pc.local site. The toolkit-server
   container picks up the custom image with claude CLI.

5. **Verify** from a tailnet client:
   ```bash
   curl -k https://mini-pc.<tailnet-name>.ts.net/healthz   # → ok
   curl -k https://mini-pc.<tailnet-name>.ts.net/portal/work/task/start \
        -X POST -H 'Content-Type: application/json' \
        -d '{"slug":"some-task","project":"seed-packet"}'
   ```

6. **Verify the LAN block is unchanged**:
   ```bash
   curl -k https://mini-pc.local/healthz   # → ok (LAN, untouched)
   curl -k https://mini-pc.local/portal/work/task/start  # → 404 (portal only on tailnet)
   ```

### Auth model

Tailscale identity is the auth — there is no portal-level token,
login flow, or session cookie. Every tailnet client that resolves
`{TAILNET_PORTAL_HOST}` is implicitly authorized to POST. The
`portal-readers` / `portal-writers` ACL groups in `tailscale/acl.json`
distinguish read-only from write-capable identities; v1 puts the
user's primary identity in both.

A LAN-bound bearer-token fallback is documented in the design doc but
NOT shipped in v1. To add it later, uncomment the LAN site block in
the design and populate `BEARER_TOKEN_PORTAL` in `caddy/env/caddy.env`.

### Common breakage

- **`Caddy fails to start: Tailnet hostname empty`** — `TAILNET_PORTAL_HOST`
  is unset in `caddy/env/caddy.env`. Caddy refuses to load the empty
  hostname stanza. Set the env var, restart Caddy.
- **`portal/* returns 404 from tailnet`** — toolkit-server isn't running
  the portal router. Check `~/homelab/toolkit-server/` is launching
  with HTTP enabled (not `--stdio-only`). The compose stack already
  uses `--http-only`; verify with `docker compose ps toolkit-server`.
- **`POST /portal/chat/message returns 500 + spawn claude: not found`** —
  the toolkit-server image doesn't have claude CLI. Rebuild via
  `docker compose build --no-cache toolkit-server` from the
  toolkit-server stack directory. Step 1 of bring-up covers this; if
  it surfaces later, it usually means a stale image got pulled.
- **SSE responses arrive in one chunk after the subprocess exits** — the
  Caddy `flush_interval -1` directive in `routes/portal.caddy` is
  missing. Confirm the file is up-to-date in the running container
  (`docker compose exec caddy cat /etc/caddy/routes/portal.caddy`).
- **Tailscale ACL paste rejects** — Tailscale's HuJSON validator
  flags trailing commas in some places it accepts elsewhere. The
  `acl.json` here is well-formed; if validation rejects, diff
  against the admin console's stock template and merge.

## Nextcloud (added 2026-06-07)

Self-hosted file sync (Google Drive replacement). Stack at `nextcloud/`:
`nextcloud:apache` + `mariadb:11` + `redis:alpine`, bound to `127.0.0.1:8080`
(loopback only). Data + DB bind-mounted under `/mnt/general/nextcloud/{data,db}`
— already inside the T7 restic scope, so backups need no change.

Reachability: fronted by Caddy on the **tailnet** hostname
`mini-pc.tailnet-name.ts.net` (Tailscale; works on LAN and remotely). Caddy
serves the Tailscale-issued Let's Encrypt cert from `/var/lib/tailscale/certs/`
(mounted read-only). `tailscale serve` is deliberately NOT used — it cannot
co-bind :443 with the host-network Caddy. Cert refresh:
`tailscale-cert-renew.timer` (weekly) runs `caddy/tailscale-cert-renew.sh`
(`tailscale cert` + `caddy reload`). Unit files tracked in `caddy/systemd/`.

Secrets in `nextcloud/env/nextcloud.env` (gitignored, chmod 600). The MariaDB
password is the one un-regeneratable secret — back it up off-disk per SECRETS.
