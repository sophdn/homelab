# gitea-actions — Gitea Actions CI runner

`act_runner` executes Gitea Actions workflows for the local Gitea instance. It
was originally started ad-hoc with `docker run` (2026-05-07) and lived outside
this repo; it is now a tracked Compose stack so CI is reproducible from source.

## What runs

| Container | Image | Network | Exposed |
|-----------|-------|---------|---------|
| `act_runner` | gitea/act_runner:latest | `gitea_default` (external) | none — talks out to Gitea |

Jobs run as **sibling containers on the host Docker daemon** (docker-out-of-Docker
via the mounted socket), on the `gitea_default` network, so they can reach Gitea
at its in-network address.

## Config-as-code

- **`config.yaml`** — runner config (capacity, the `NODE_EXTRA_CA_CERTS` trust
  for Caddy's internal CA, and the job-container cert mount). Non-secret; tracked.
- **`caddy-internal-root.crt`** — the Caddy Local Authority root **certificate**
  (public, not a private key). Job containers mount it so Node TLS clients trust
  the Caddy-fronted Gitea. Tracked.

`config.yaml` still references the host path `/etc/act_runner/caddy-internal-root.crt`
for the **job** containers it spawns (they mount from the host, not from this
container). On a fresh box that path must exist — install the committed cert
there (see below).

## Registration (the one piece NOT in this repo)

The runner's registration token is stored in the **external `act_runner_data`
volume** at `/data/.runner`, generated when the runner first registered against
Gitea. It is intentionally not committed. Recreating the container reuses the
volume and keeps the existing registration.

## Fresh-box bring-up

```sh
# 1. Prereqs: the `gitea` stack is up (creates the gitea_default network).
# 2. Job containers need the CA cert at the host path config.yaml expects:
sudo install -D -m0644 caddy-internal-root.crt /etc/act_runner/caddy-internal-root.crt

# 3a. If restoring an existing runner: restore the act_runner_data volume from
#     restic (contains /data/.runner) BEFORE first up.
# 3b. If registering a NEW runner: create the external volume, bring the stack
#     up, then register against Gitea (Site Admin -> Actions -> Runners ->
#     "Create new runner" for the token):
docker volume create act_runner_data
docker compose up -d
docker compose exec act_runner act_runner register --no-interactive \
  --instance http://gitea:3000/ --token <REGISTRATION_TOKEN> --name mini-pc
docker compose restart act_runner
```

## Day-to-day

```sh
docker compose up -d          # start / apply config changes
docker compose logs -f        # watch runner + job pickup
docker compose restart        # after editing config.yaml
```

The runner + its config + `/etc/act_runner/caddy-internal-root.crt` are covered by
the restic backup (repo-root README §BACKUP), so `/data/.runner` is recoverable.
