#!/usr/bin/env bash
# Refresh the Tailscale-issued TLS cert for the tailnet host (fronts Nextcloud + Gitea), then reload Caddy
# so it picks up the new files. `tailscale cert` is a no-op until the cert is
# within its renewal window, so running this weekly is cheap and safe.
set -euo pipefail
FQDN=mini-pc.tailnet-name.ts.net
CERTDIR=/var/lib/tailscale/certs
tailscale cert --cert-file "$CERTDIR/$FQDN.crt" --key-file "$CERTDIR/$FQDN.key" "$FQDN"
docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
