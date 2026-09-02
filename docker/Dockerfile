# QuickBooks Online MCP Gateway — one container that self-hosts Intuit's official QBO MCP
# server for one or many companies, behind a single multiplexing proxy on one port.
#
# Self-contained: the build clones the pinned upstream Intuit server and compiles it for
# Linux/this CPU arch. A fresh clone of this repo can `docker compose build` with nothing else.
#
#   docker compose -f docker/docker-compose.yml build
#
# Pin a different upstream version with:  --build-arg SERVER_REF=<sha-or-tag>
# Secrets/tokens never live in the image — they come from the mounted volume at /app/companies.

# ---- build stage: clone + compile the upstream server for Linux/this CPU arch ----
FROM node:22-bookworm-slim AS build
ARG SERVER_REPO=https://github.com/intuit/quickbooks-online-mcp-server.git
# Pin to a known-good upstream commit for reproducibility. Override via --build-arg.
ARG SERVER_REF=def36872cb512fe621b6d49f1ccce3f2fbeabea8
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /build
RUN git clone "$SERVER_REPO" . \
 && git checkout --quiet "$SERVER_REF" \
 && (if [ -f package-lock.json ]; then npm ci; else npm install; fi) \
 && npm run build

# ---- runtime stage ----
FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends tini ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# node_modules baked at /app/node_modules — a parent of the /app/companies volume mount,
# so it's resolved up-tree by every company's compiled server and never copied into the volume.
COPY --from=build /build/node_modules  /app/node_modules
# The compiled server; seeded per-company into the volume by the entrypoint (it must sit next
# to each company's .env, which the upstream resolves as dist/../../.env).
COPY --from=build /build/dist          /opt/qbo/template/dist

# The multiplexing proxy: one HTTP server that holds one persistent stdio child per company
# and fans out to many client sessions.
COPY proxy/qbo-proxy.mjs               /app/proxy/qbo-proxy.mjs
COPY docker/entrypoint.sh              /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# SLUGS is the space-separated list of your company labels; set it in docker-compose.yml
# (one companies/<slug>/.env per label). PORT is the single front port.
ENV SLUGS=""
ENV PORT=8200
EXPOSE 8200

WORKDIR /app
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
