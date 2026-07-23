# Tailscale config — homelab

This subtree carries the canonical Tailscale ACL JSON for the homelab.
Tailscale itself is configured admin-side via
[tailscale.com/admin/acls](https://login.tailscale.com/admin/acls); this
file is the source of truth for what the admin-console paste should
contain. Edit here, paste there, commit the change.

## What's here

| File | Purpose |
|---|---|
| `acl.json` | Canonical ACL — paste into the admin console. |
| `README.md` | This file. |

## What's NOT here

- The tailscale device registrations themselves (the mini-PC's
  per-device auth key) live on the device, not in this repo.
- Per-device tags (e.g. `tag:portal` for ACL-by-tag rules). The
  default ACL uses identity-based groups; tag-based variants are a
  later refinement.

## Workflow

1. Edit `acl.json`, commit, push.
2. Open the admin console (link above).
3. Replace the existing JSON with the contents of `acl.json`.
4. Save in the admin console — Tailscale validates and applies the
   ACL within seconds across every device.
5. Verify: from a tailnet client, `curl -k https://mini-pc.<tailnet>.ts.net/healthz`
   should return `ok 200`. From a non-tailnet host, the hostname
   should not resolve.

## Group membership and the design

`portal-readers` and `portal-writers` split GET-only from POST-capable
identities. v1 puts the user's primary identity in both — future
device-only identities (a phone login that should browse but not
post) land in `portal-readers` only.

The `mini-pc:443` destination matches the Caddy stanza in
`caddy/config/Caddyfile` that `bind`s `tailscale0` and serves the
portal write-API behind `tls internal`. Port 443 is the canonical
Caddy listen port; the tailnet ACL closes off any other port from
non-self traffic.
