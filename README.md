# QuickBooks Online MCP Gateway

Self-host Intuit's official [QuickBooks Online MCP server](https://github.com/intuit/quickbooks-online-mcp-server)
for **one or many companies**, behind a **single multiplexing proxy** on one port — usable from
Claude Code, Claude Desktop, or any MCP client, by any number of clients at once.

One small container. One port. Bring your own Intuit developer app. Full read/write access to the
QuickBooks Online Accounting API.

> ⚠️ **Writes are live.** The MCP tools include `create_*` / `update_*` / `delete_*` and act on the
> real books of whichever company you connect. Consider the read-only switches (below) for
> companies you only want to query.

---

## Is this what you want? — vs. Claude's built-in QuickBooks connector

Claude (on claude.ai / Claude Desktop) offers a **managed QuickBooks connector**: you click
"connect", sign in with OAuth, and Claude can query that account — zero hosting. This project is the
**self-hosted** alternative. They solve different problems:

| | **This gateway (self-hosted QBO MCP)** | **Claude's built-in QuickBooks connector** |
|---|---|---|
| Setup | You run a container + your own Intuit app | Click-to-connect in the Claude UI |
| Hosting / data path | Your infrastructure; traffic goes You → your server → Intuit | Managed by Anthropic |
| Companies | **Many** — each its own endpoint on one gateway | Typically the one account you connect |
| Tool surface | The **full** Intuit MCP server (~140 tools/company: invoices, bills, journal entries, payments, items, customers/vendors, all reports, …) | A curated subset defined by the connector |
| Writes | Full create/update/delete (toggle read-only per company) | As allowed by the connector |
| Where it works | Any MCP client (Claude Code, Claude Desktop, others) | Claude surfaces that support the connector |
| Multi-client / team / automation | **Yes** — many concurrent clients share one token chain per company | Per-user account connection |
| Effort | Higher (this repo) | Minimal |

**Use the built-in connector if** you're one person, one company, want zero setup, and mostly read.
**Use this gateway if** you need multiple companies, the full API surface with writes, control over
hosting/privacy, use across different MCP clients, or many clients/automation against the same books.

> The built-in connector's exact scope evolves — verify current capabilities in Claude's connector
> directory before deciding. This README describes the self-hosted path.

---

## How it works

```
client A ─┐                              ┌─ child: company-one   (1 stdio process)
client B ─┤  http://HOST:8200/<slug>/sse ├─ child: company-two …    one refresh-token
   …      ├─────────────────────────────►│   qbo-proxy (mux)         chain per company
client N ─┘     (path = company slug)    └─ child: company-N     ─► Intuit QBO API
```

`proxy/qbo-proxy.mjs` is a small dependency-free Node server that:

- routes by `/<slug>/` path (the company selector),
- holds **one persistent stdio child** (the Intuit MCP server) **per company**, connected once and
  never torn down,
- **multiplexes many client sessions** over each child (answers `initialize`/`ping` locally,
  forwards tool calls with rewritten JSON-RPC ids, routes replies back per session).

**Why a custom proxy instead of a generic stdio→SSE bridge:** the upstream Intuit MCP server accepts
**one transport connection per process, ever**. With a 1:1 bridge, any client reconnect after an
ungraceful drop (laptop sleep, wifi blip, app restart) collides with the still-attached dead
transport, crashes the process, and returns 502s mid-recovery — even with a single client. The proxy
owns that one connection permanently, so client churn never reaches the upstream, and many clients
can share it. The only ceiling is Intuit's per-realm API rate limit (see Limits).

Because one process = one refresh-token chain per company, there is **no token clobbering** and no
need to authorize a company more than once — no matter how many clients connect.

---

## Prerequisites

- A host with **Docker** + **Docker Compose** (a NAS, a small VM, a Linux box). Build on the host so
  native deps match its CPU (x86_64 / arm64).
- An **Intuit Developer** account and a QuickBooks Online app (below).
- A QuickBooks Online **company** (or several) you can authorize.

---

## 1. Set up your Intuit developer app

1. Sign in at **[developer.intuit.com](https://developer.intuit.com/)** and open the **Dashboard**.
2. **Create an app** → select the **QuickBooks Online and Payments** platform → scope
   **`com.intuit.quickbooks.accounting`**.
3. In the app, go to **Keys & credentials** and switch to the **Production** keys (not Development/
   sandbox — these connect to real books). Copy the **Client ID** and **Client Secret**.
4. Still under the production app, add this **Redirect URI** (used only to mint tokens in step 2):
   ```
   https://developer.intuit.com/v2/OAuth2Playground/RedirectUrl
   ```
5. Production apps may require Intuit to review/approve the app before it can connect real companies —
   follow any prompts in the dashboard. The **Client ID/Secret are shared** across all your
   companies; only the tokens differ.

## 2. Generate a refresh token per company

Do this once per QuickBooks company, using Intuit's OAuth Playground (simpler than a redirect
server, and matches the redirect URI you added above):

1. Open the **[OAuth 2.0 Playground](https://developer.intuit.com/app/developer/playground)**.
2. Set environment to **Production** and select your app.
3. Scope: **`com.intuit.quickbooks.accounting`**.
4. **Get authorization code** → sign in → **choose the specific company** to authorize.
5. **Get tokens** → copy the **`realmId`** and **`refresh_token`**.

Repeat for each company. (Refresh tokens are valid ~100 days but **rotate on use** — every call
returns a new token, auto-persisted, resetting the clock; query each company at least once every
~100 days and it stays connected indefinitely.)

## 3. Configure and run

```sh
git clone https://github.com/<you>/qbo-mcp-gateway.git
cd qbo-mcp-gateway

# One .env per company. Pick a short label ("slug") for each — e.g. acme, contoso.
for slug in acme contoso; do
  mkdir -p companies/$slug
  cp .env.example companies/$slug/.env
  chmod 600 companies/$slug/.env
  # edit companies/$slug/.env: CLIENT_ID/SECRET (same for all), REALM_ID + REFRESH_TOKEN (per company)
done

# List your slugs in docker/docker-compose.yml -> services.qbo-mcp.environment.SLUGS
#   SLUGS: "acme contoso"

docker compose -f docker/docker-compose.yml build
docker compose -f docker/docker-compose.yml up -d
docker compose -f docker/docker-compose.yml logs -f qbo-mcp   # expect "[child] initialized" per company
```

Verify: `sh docker/qbo-logs.sh status` → each slug should print `ok`.

Each company is then served at:
```
http://HOST:8200/<slug>/sse        (MCP endpoint)
http://HOST:8200/<slug>/healthz    (health -> "ok")
```

## 4. Connect an MCP client

**Claude Code** (one entry per company; user scope makes it available in every session):
```sh
HOST=192.168.1.10   # your host's LAN IP / hostname / Tailscale name
claude mcp add --transport sse -s user "qbo-acme"    "http://$HOST:8200/acme/sse"
claude mcp add --transport sse -s user "qbo-contoso" "http://$HOST:8200/contoso/sse"
```
Restart the client, then confirm with `claude mcp list`.

Any MCP client that supports an SSE/remote server can use the same `http://HOST:8200/<slug>/sse` URL.

---

## Operations

- **Logs:** `docker logs qbo-mcp`, or per company `sh docker/qbo-logs.sh <slug>` (also persisted to
  `companies/<slug>/logs/gateway.log`, timestamped + size-rotated). `sh docker/qbo-logs.sh status`
  and `sh docker/qbo-logs.sh crashes` for quick checks.
- **Reset a wedged company:** `sh docker/clear.sh` (restarts the container, all children fresh).
- **Update the upstream server:** rebuild (`--build-arg SERVER_REF=<sha-or-tag>` to move the pin),
  then `RESEED_CODE=1 docker compose -f docker/docker-compose.yml up -d` once to refresh the seeded
  server code; `.env` files (and rotated tokens) are untouched.
- **Self-test the proxy** (torture + concurrency) against a configured company:
  `docker exec -e TSLUG=<slug> qbo-mcp node /app/proxy/selftest.mjs`
- **Read-only a company:** set `QUICKBOOKS_DISABLE_WRITE/UPDATE/DELETE=true` in its `.env`, restart.

## Security

These endpoints reach live financial books. **Keep port 8200 on a private network** (LAN, VPN, or
[Tailscale](https://tailscale.com/)); do **not** port-forward it to the internet. Secrets live only
in each `companies/<slug>/.env` on the host — never in the image or the client config. Add auth at a
reverse proxy in front if you need it.

## Limits & notes

- **One token chain per company.** All clients for a company share one stdio child + one rotating
  refresh token. This is what makes many clients safe — but it also means throughput is bounded by
  **Intuit's per-realm API limits** (production: roughly ~500 requests/min and ~10 concurrent per
  company). Heavy fan-out to the same company will hit Intuit's limit, not the gateway.
- **`404 no such session` right after a deploy/restart** is harmless — a client cached a session id
  from before the restart; it reconnects and gets a fresh one.
- **Not affiliated with Intuit or Anthropic.** "QuickBooks" is a trademark of Intuit; "Claude" of
  Anthropic. This project just self-hosts Intuit's open-source MCP server.

## License

MIT — see [LICENSE](LICENSE). The upstream Intuit server is cloned at build time under its own
license; this repo does not vendor it.
