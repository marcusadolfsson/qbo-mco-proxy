#!/usr/bin/env node
// QBO multi-company MCP multiplexing proxy.
//
// Replaces both supergateway and Caddy. One HTTP server on :8200 that:
//   - routes by path prefix /<slug>/...  (the company selector)
//   - holds ONE persistent stdio child (the Intuit MCP server) per company, connected
//     once and never torn down — so the upstream "one transport per process, ever"
//     limit is never violated by client churn
//   - serves MANY concurrent client SSE sessions per company, multiplexing their
//     JSON-RPC over the single child by rewriting message ids
//
// This fixes the single-client reconnect 502 (the child never sees a reconnect) and
// enables many clients (all share one child + one rotating token chain).
//
// Transport to clients: MCP HTTP+SSE.
//   GET  /<slug>/sse                       -> SSE stream; first event is the message endpoint
//   POST /<slug>/message?sessionId=...      -> JSON-RPC in; 202; reply arrives on the SSE stream
//   GET  /<slug>/healthz                    -> "ok" once the child is initialized
// No external deps (Node builtins only).

import http from "node:http";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { randomUUID } from "node:crypto";
import { appendFileSync, mkdirSync, statSync, renameSync } from "node:fs";

const PORT       = Number(process.env.PORT || 8200);
const SLUGS      = (process.env.SLUGS || "").trim().split(/\s+/).filter(Boolean);
const COMPANIES  = process.env.COMPANIES_DIR || "/app/companies";
const PROTO      = process.env.MCP_PROTOCOL || "2024-11-05";
const MAXLOG     = Number(process.env.QBO_MAXLOG_BYTES || 5_000_000);
const KEEPALIVE  = 20_000;

if (!SLUGS.length) { console.error("[proxy] SLUGS env is empty"); process.exit(1); }

const ts = () => new Date().toISOString();
function log(slug, msg) {
  const line = `${ts()} [${slug}] ${msg}`;
  console.log(line);
  try {
    const dir = `${COMPANIES}/${slug}/logs`;
    mkdirSync(dir, { recursive: true });
    const f = `${dir}/gateway.log`;
    try { if (statSync(f).size > MAXLOG) renameSync(f, `${f}.1`); } catch {}
    appendFileSync(f, line + "\n");
  } catch {}
}

// ───────────────────────── one upstream child per company ─────────────────────────
class Company {
  constructor(slug) {
    this.slug = slug;
    this.child = null;
    this.ready = false;
    this.initResult = null;          // cached `initialize` result (describes the server)
    this.sessions = new Map();       // sessionId -> { res (SSE), }
    this.pending = new Map();        // upstreamId -> { sessionId, origId }
    this.upId = 0;
    this.start();
  }

  start() {
    const dir = `${COMPANIES}/${this.slug}`;
    log(this.slug, `[child] spawning node ${dir}/dist/index.js`);
    const child = spawn("node", [`${dir}/dist/index.js`], { stdio: ["pipe", "pipe", "pipe"] });
    this.child = child;
    this.ready = false;

    const rl = createInterface({ input: child.stdout });
    rl.on("line", (line) => {
      if (!line.trim()) return;
      let msg; try { msg = JSON.parse(line); } catch { return; } // non-JSON = ignore
      this.onUpstream(msg);
    });
    // server logs (token rotation, errors) come on stderr — capture for visibility
    createInterface({ input: child.stderr }).on("line", (l) => l.trim() && log(this.slug, `[child-stderr] ${l}`));

    child.on("exit", (code, sig) => {
      log(this.slug, `[child] exited code=${code} sig=${sig} — failing ${this.pending.size} in-flight, respawning in 1s`);
      this.ready = false;
      // fail any in-flight client requests so clients can retry cleanly
      for (const [, p] of this.pending) this.sendToSession(p.sessionId, { jsonrpc: "2.0", id: p.origId,
        error: { code: -32000, message: "upstream restarted; retry" } });
      this.pending.clear();
      setTimeout(() => this.start(), 1000);
    });

    // perform the single upstream initialize handshake
    this.send({ jsonrpc: "2.0", id: "__init__", method: "initialize",
      params: { protocolVersion: PROTO, capabilities: {}, clientInfo: { name: "qbo-proxy", version: "1" } } });
  }

  send(msg) { try { this.child.stdin.write(JSON.stringify(msg) + "\n"); } catch (e) { log(this.slug, `[child] write failed: ${e.message}`); } }

  onUpstream(msg) {
    // our own initialize reply → cache, then send initialized notification → ready
    if (msg.id === "__init__") {
      this.initResult = msg.result;
      this.send({ jsonrpc: "2.0", method: "notifications/initialized" });
      this.ready = true;
      const n = msg.result?.serverInfo?.name || "?";
      log(this.slug, `[child] initialized (server=${n}); ready`);
      return;
    }
    if (msg.id !== undefined && this.pending.has(msg.id)) {
      const { sessionId, origId } = this.pending.get(msg.id);
      this.pending.delete(msg.id);
      msg.id = origId;
      this.sendToSession(sessionId, msg);
      return;
    }
    // id-less notification from server → broadcast to all this company's sessions
    if (msg.id === undefined && msg.method) {
      for (const sid of this.sessions.keys()) this.sendToSession(sid, msg);
    }
  }

  // a client POSTed a JSON-RPC message for this session
  fromClient(sessionId, msg) {
    const m = msg.method;
    // handle locally (don't disturb the shared child):
    if (m === "initialize")
      return this.sendToSession(sessionId, { jsonrpc: "2.0", id: msg.id, result: this.initResult });
    if (m === "ping")
      return this.sendToSession(sessionId, { jsonrpc: "2.0", id: msg.id, result: {} });
    if (m === "notifications/initialized" || (m && m.startsWith("notifications/") && msg.id === undefined))
      return; // client notification — swallow / no-op (initialized already done once upstream)
    if (msg.id === undefined) { this.send(msg); return; } // other client notification → forward as-is

    // request → rewrite id, map, forward to shared child
    const up = ++this.upId;
    this.pending.set(up, { sessionId, origId: msg.id });
    this.send({ ...msg, id: up });
  }

  addSession(sessionId, res) { this.sessions.set(sessionId, { res }); }
  removeSession(sessionId) { this.sessions.delete(sessionId); }
  sendToSession(sessionId, msg) {
    const s = this.sessions.get(sessionId);
    if (!s) return;
    try { s.res.write(`event: message\ndata: ${JSON.stringify(msg)}\n\n`); } catch {}
  }
}

const companies = new Map(SLUGS.map((s) => [s, new Company(s)]));

// ───────────────────────────────── HTTP server ─────────────────────────────────
function parsePath(url) {
  // /<slug>/<rest...>
  const u = new URL(url, "http://x");
  const m = u.pathname.match(/^\/([^/]+)\/(.*)$/);
  return m ? { slug: m[1], rest: m[2], query: u.searchParams } : { slug: null };
}

const server = http.createServer((req, res) => {
  const { slug, rest, query } = parsePath(req.url);

  if (req.method === "GET" && (req.url === "/" || req.url === "")) {
    res.writeHead(200, { "content-type": "text/plain" });
    return res.end(`qbo-proxy — companies: ${SLUGS.join(", ")}\nuse /<company>/sse\n`);
  }
  if (!slug || !companies.has(slug)) { res.writeHead(404); return res.end("unknown company"); }
  const co = companies.get(slug);

  if (req.method === "GET" && rest === "healthz")
    { res.writeHead(co.ready ? 200 : 503, { "content-type": "text/plain" }); return res.end(co.ready ? "ok" : "starting"); }

  // open an SSE session
  if (req.method === "GET" && rest === "sse") {
    const sessionId = randomUUID();
    res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache",
      connection: "keep-alive", "x-accel-buffering": "no" });
    co.addSession(sessionId, res);
    // first event: where the client should POST messages
    res.write(`event: endpoint\ndata: /${slug}/message?sessionId=${sessionId}\n\n`);
    log(slug, `[sse] session ${sessionId} open (sessions=${co.sessions.size})`);
    const ka = setInterval(() => { try { res.write(`:ka\n\n`); } catch {} }, KEEPALIVE);
    req.on("close", () => { clearInterval(ka); co.removeSession(sessionId); log(slug, `[sse] session ${sessionId} closed (sessions=${co.sessions.size})`); });
    return;
  }

  // client → server JSON-RPC
  if (req.method === "POST" && rest === "message") {
    const sessionId = query.get("sessionId");
    if (!sessionId || !co.sessions.has(sessionId)) { res.writeHead(404); return res.end("no such session"); }
    let body = "";
    req.on("data", (d) => (body += d));
    req.on("end", () => {
      let msg; try { msg = JSON.parse(body); } catch { res.writeHead(400); return res.end("bad json"); }
      res.writeHead(202); res.end("accepted");           // reply is delivered over SSE
      try { co.fromClient(sessionId, msg); } catch (e) { log(slug, `[msg] handler error: ${e.message}`); }
    });
    return;
  }

  res.writeHead(404); res.end("not found");
});

server.listen(PORT, () => log("proxy", `listening on :${PORT} — companies: ${SLUGS.join(", ")}`));
