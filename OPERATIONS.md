# Operations

How this homelab is kept honest: a small, repeatable discipline that treats the
running server and the repo as two things that must be *proven* equal, not
assumed equal. (The live working notes that drive this — dated container
inventories and gap lists — stay private; this is the sanitized shape of the
process.)

## Audit → Reconcile → Verify

The repo is maintained through a three-step loop, run whenever the live server
and the tracked config might have drifted:

1. **Audit** — enumerate what is actually running on the box (containers, images,
   published ports, bind mounts, systemd units, backup timers) and what state
   each service owns on disk.
2. **Reconcile** — diff that live picture against the repo. Every gap becomes a
   tracked item with an owner: either the repo is wrong (fix the config) or the
   box is wrong (redeploy from the repo). A gap is not closed until one side
   changed to match the other.
3. **Verify** — a short acceptance checklist proves the repo *reproducibly*
   describes the server: each stack parses (`docker compose config`), every
   secret referenced by a compose file resolves from a gitignored `.env`, the
   ingress endpoints answer as expected, and the backup has a **performed**
   restore drill (not just a configured job).

The goal is that a from-scratch rebuild off this repo yields the same server —
`RUNBOOK.md` is that rebuild, in dependency order.

## Secrets

No secret is ever committed. Each stack keeps a gitignored `env/<stack>.env`
alongside a committed `env/<stack>.env.example` that documents every key and how
to generate it. A pre-commit hook blocks the Compose `$`-escaping footgun (a
literal `$` in an `env_file` value must be `$$`), turning a real past incident
into a mechanical guard. A positive-control leak scan periodically extracts every
real `.env` value and greps the tracked tree to confirm none are present.

## Backups

Nightly `restic` with a real threat model: the SQLite databases (gitea, the
toolkit ledger) are quiesced with `.backup` before capture — correct for both
rollback-journal and WAL modes — the repo lives on a separate physical disk, and
a restore has actually been drilled and diff-verified. What the backup does **not**
survive (an off-site event) is stated plainly rather than implied.

## Ingress & TLS

A single Caddy reverse proxy fronts everything. The tailnet hostname serves a
Tailscale-issued Let's Encrypt cert (refreshed by a weekly systemd timer + reload);
the LAN name falls back to Caddy's internal CA. Internal services bind loopback and
are reached only through the proxy; write surfaces that rely on the tailscale
network boundary for auth are bound to the tailnet interface only, never the LAN.
