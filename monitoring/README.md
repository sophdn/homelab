# monitoring — health polling that files findings as bugs

Silence must mean healthy, and healthy must be **proven**. This is the machinery
that makes that true for this box.

## The principle

**Autonomous means idempotent, self-healing, and LOUD about what it couldn't
do** — never "runs silently and hopes".

The failure that actually happens is not a dramatic one. It is a peer's
backups being dead for **22 days** because every safeguard failed quietly: the
offsite job ended in `2>/dev/null || true` (a job that cannot fail cannot warn),
the weekly verify wrote to a logfile nobody read, and mdadm emailed root on a
box with no mail server. Nothing was broken loudly. Everything was broken
silently.

So: no `|| true` on anything that must be able to warn, and no check that
reports health it has not established.

## Why findings are bugs, not push notifications

For anything actionable and durable — a failed backup, a filling disk, a dump
that stopped being produced — a **bug beats a notification**:

- a push buzzes once, gets swiped, and leaves no record that anyone saw it
- a bug has state, dedupe, severity and a resolution — it persists until it is
  genuinely dealt with
- it lands in the surface that is already read daily, not in a logfile
- it keeps the stack owned: no third-party channel, no account, no token

The state is the real win. When a condition clears, its bug **auto-resolves** —
a transition a notification can't express at all.

## Why the observer polls (the load-bearing bit)

**The box does not report on itself.** A bug filed *by* the failing host cannot
be filed when the host is the thing that is broken — disk full, docker dead, box
off, network gone. And nobody files a "backup succeeded" bug, so silence would
never distinguish healthy from dead.

So the alarm must not share fate with what it watches:

```
  observer (holds the ledger)                 monitored host
  ---------------------------                 --------------
  poll-and-file.sh  ──── ssh 'bash -s' ────>  health-report.sh
        │                <──── JSON ────           (measures only,
        │                                            decides nothing)
        └── files / resolves bugs in the ledger
```

`health-report.sh` is **piped over ssh, not installed** — so the host needs
nothing deployed and the check logic can never go stale on it.

Absence is therefore detectable: if the host can't be reached at all, that is
itself a finding (`auto-<tag>-unreachable`, high). That is the deadman, and it
only works because the thing raising it is somewhere else.

## Unknown is not OK

Every check that cannot run reports `unknown` with a reason — never `ok` — and
unknown is **filed**, not skipped. If `smartctl` isn't installed, the disks may
well be dying; we simply cannot see. A monitor that quietly skips what it can't
measure is reporting health it never established, which is the same lie as a
logfile nobody reads.

## What it watches

| Check | Finding |
|---|---|
| systemd units (`HOMELAB_WATCH_UNITS`) | `Result != success` → high · not installed → medium (never-ran looks identical to nothing-wrong) |
| disk usage per mount | over `HOMELAB_DISK_PCT_WARN` (85%) → high — a full disk takes the backups with it, quietly |
| SMART | unhealthy → high · `smartctl` absent or unreadable → medium (**unmeasured**, and filed as such) |
| backup artifacts | missing or older than its max age → high — an artifact that stops being refreshed *is* the silent-death signature |
| the host itself | unreachable → high |

## Idempotence

Slugs are deterministic and prefixed `auto-<tag>-`. An already-open finding is
left alone rather than re-filed, so a persistent fault doesn't spam the ledger
hourly. When the condition clears, the bug is resolved with
`commit_sha=unversioned` (the sentinel for a resolution whose artifact lives
outside version control — nothing was committed; the condition simply cleared).

Only bugs this poller filed are ever touched — a human-filed bug is never
auto-resolved.

## Install (on the OBSERVER, not on the monitored host)

```bash
mkdir -p ~/.config/homelab-monitor
cp monitoring/monitor.env.example ~/.config/homelab-monitor/monitor.env
$EDITOR ~/.config/homelab-monitor/monitor.env   # TARGET + TOOLKIT_URL

mkdir -p ~/.config/systemd/user
cp monitoring/systemd/homelab-health-poll.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now homelab-health-poll.timer
loginctl enable-linger "$USER"
```

`HOMELAB_MONITOR_TOOLKIT_URL` **must not** point at a service on the monitored
host — that would rebuild the shared-fate problem this design exists to avoid.

Try it first without touching anything:

```bash
HOMELAB_MONITOR_DRY_RUN=1 monitoring/scripts/poll-and-file.sh
```

## Enabling SMART on a target

Two steps, and the first alone is not enough — NVMe SMART needs root, so a poll
arriving as an unprivileged user gets "Permission denied" and correctly reports
`unknown` even with smartmontools installed:

```bash
# ON THE MONITORED HOST (not the observer — the observer never reads its disks)
sudo apt install smartmontools
echo "$USER ALL=(root) NOPASSWD: /usr/sbin/smartctl" | sudo tee /etc/sudoers.d/smartctl-health
sudo chmod 0440 /etc/sudoers.d/smartctl-health
```

The poll prefers `sudo -n smartctl` and falls back to a bare call, so a host
granting access another way still works. Once it reports
`smart.status=measured`, the `auto-<tag>-smart-unmeasured` bug auto-resolves and
real per-drive findings turn on.

## Known gap

This is pull, not push: a finding surfaces next time the observer polls, not as
a phone buzz at 03:00. For this threat model that's a deliberate trade — with
local dumps plus restic's 7d/4w/6m, a few hours' latency on "backup failed" is
not a data-loss event. The one case where latency genuinely costs is a disk
actively dying, which is the single place a real push would earn its keep. Not
built; recorded here so the trade is a decision rather than an oversight.
