# campaign-db — backup + restore test for the campaign-settings Postgres

The campaign database is years of irreplaceable creative work. There is no
"re-derive it from source", so it is the one dataset on this box whose loss
would be permanent.

Until 2026-07-15 it was backed up by **nothing**. Worth being precise about how
that happened, because the failure is a shape rather than an oversight:

- restic backs up `/home/youruser/homelab`, `/mnt/general/jellyfin-docker-config`
  and `/mnt/general/nextcloud`.
- The campaign-settings stack *is* deployed under `/home/youruser/homelab`, so it
  looked covered.
- But Postgres keeps its data in a docker volume
  (`campaign-settings-deploy_campaign-prod-pgdata`) under
  `/var/lib/docker/volumes/` — none of those paths.
- `dm-manager-backup.timer` looks adjacent, but backs up the *predecessor*
  app's data dir, not this.

So: a deployed stack whose data lives in a volume is not backed up by a
path-based backup, no matter where the compose file sits.

## What runs

| Unit | Cadence | Does |
|---|---|---|
| `homelab-backup.service` (existing) | nightly 03:00 | calls `campaign-db/scripts/dump.sh` during its pre-backup quiesce, then `restic backup` |
| `campaign-db-restore-test.timer` | Sun 04:30 | restores the newest dump into a throwaway DB and verifies it |

`dump.sh` is deliberately **not** its own timer. It runs inside restic's
quiesce step so the dump is written *before* `restic backup` in the same run —
otherwise each night's snapshot would carry the previous night's dump.

## Where the data goes

```
pg_dump --format=custom          (consistent; live server, no downtime)
  -> campaign-db/data/campaign_settings-<UTC timestamp>.dump
  -> (under /home/youruser/homelab, so restic takes it)
  -> restic repo on /mnt/jellyfin   (separate physical NVMe)
  -> retention 7 daily / 4 weekly / 6 monthly
```

Local dumps keep 14 days behind a **hard floor of 3**: pruning can never take
the directory below three dumps whatever their age, because a cleanup that
*can* delete to zero eventually will, on the one night it matters. The local
copies are a fast-restore cache; restic holds the long tail.

**Threat model — unchanged.** Survives disk failure, a bad migration, a
fat-finger `DELETE`. Does **not** survive a house fire; off-box replication is
still a deferred follow-up, same as the rest of this repo's backup story.

## Why a restore test

A copy you have never restored from is a rumor. The dump can succeed nightly
for months while producing files `pg_restore` would reject. The weekly test
asserts, and fails the unit if any of it breaks:

- the newest dump is **less than 48h old** — a dump that silently stopped being
  produced would otherwise let the restore keep passing against an ancient file
- `pg_restore` reconstructs it into a throwaway database
- `worlds`, `entities`, `users` exist and are non-empty — and are not 0 rows
  while production has data (the "dumped an emptied database" case)

The throwaway DB is created and dropped inside the same Postgres instance and
removed via an EXIT trap, so a failure can't leak one. Production is only read.
This mirrors what campaign-settings' own test suite already does per-suite
(`cs_test_<uuid>`), so the pattern is proven on this box.

## Configuration

None required — the defaults match the deployed stack, and no credentials are
stored here (the scripts read `POSTGRES_USER` / `POSTGRES_DB` off the running
container, so there's no second copy of a secret to drift). To override, copy
`env/campaign-db.env.example` to `env/campaign-db.env`.

## Install

```bash
cd ~/homelab && git pull
sudo cp campaign-db/systemd/campaign-db-restore-test.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now campaign-db-restore-test.timer
```

Verify it end to end without waiting for the timers:

```bash
sudo /home/youruser/homelab/campaign-db/scripts/dump.sh          # writes a dump
sudo /home/youruser/homelab/campaign-db/scripts/restore-test.sh  # proves it restores
sudo systemctl start homelab-backup.service                    # full nightly path
ls -la /home/youruser/homelab/campaign-db/data/
```

## Failure signalling — the known gap

Today a failure shows up as a **failed systemd unit** plus a line in
`/var/log/homelab/campaign-db.log`. That is the "logfile nobody reads" shape,
and it is tracked as bug
`backup-and-disk-events-do-not-reach-a-human-silent-failure` (a peer's backups
were dead for 22 days behind exactly this). When that lands, both scripts get
push notification on success *and* failure, so silence means healthy.

What is already true: nothing here is wrapped in `|| true` or
`2>/dev/null`, so every failure path is capable of warning. In particular, a
dump failure does **not** abort the rest of the nightly backup — the other
stacks still get backed up and the failure is re-raised at the end of the run,
so the unit still goes red.
