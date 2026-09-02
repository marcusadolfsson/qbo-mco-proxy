#!/usr/bin/env bash
# Seed each company's compiled server into the persistent volume (if missing), then exec the
# multiplexing proxy, which owns one stdio child per company and serves all clients on :8200.
#
# Volume layout (bind-mounted at /app/companies, persistent + writable):
#   /app/companies/<slug>/dist/            <- compiled server (seeded from image)
#   /app/companies/<slug>/.env             <- YOU provide; tokens rotate & persist here
#   /app/companies/<slug>/logs/gateway.log <- per-company debug log (written by the proxy)
# node_modules is baked at /app/node_modules (image) and resolved up-tree.
set -euo pipefail

SLUGS="${SLUGS:?SLUGS env not set}"
RESEED="${RESEED_CODE:-0}"

for slug in $SLUGS; do
  dir="/app/companies/$slug"
  mkdir -p "$dir/logs"

  if [ ! -d "$dir/dist" ] || [ "$RESEED" = "1" ]; then
    echo "[seed] dist -> $dir/dist"
    rm -rf "$dir/dist"
    cp -a /opt/qbo/template/dist "$dir/dist"
  fi

  if [ ! -f "$dir/.env" ]; then
    echo "[FATAL] missing $dir/.env — place this company's .env in the volume and restart." >&2
    exit 1
  fi
  chmod 600 "$dir/.env" 2>/dev/null || true
done

echo "[entrypoint] starting qbo-proxy on :${PORT:-8200} for: $SLUGS"
exec node /app/proxy/qbo-proxy.mjs
