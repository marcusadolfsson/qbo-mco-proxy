#!/usr/bin/env node
// QBO MCP Proxy's entry point for Intuit's QuickBooks Online MCP server.
//
// Registers two internal, read-only tools on the upstream's own McpServer
// singleton, then loads Intuit's index.js unchanged, which registers its 140
// tools and connects stdio. Intuit's files are never modified.
//
// The tools exist for the read-cache sync, which must go through this
// process: it owns the company's rotating refresh token, and any second
// holder of that token would break the chain. The gateway hides both from
// clients and refuses client calls to them.
//
//   __qbobar_query  {query}                  GET /v3/company/<realm>/query
//   __qbobar_cdc    {entities, changedSince} GET /v3/company/<realm>/cdc
//
// Both return Intuit's JSON verbatim as text; errors set isError.

import { z } from "zod";
import { QuickbooksMCPServer } from "./server/qbo-mcp-server.js";
import { QuickbooksClient } from "./clients/quickbooks-client.js";

const MINOR_VERSION = "75";

async function qboGet(path, query) {
  const { accessToken, realmId, isSandbox } = await QuickbooksClient.getAuthCredentials();
  const base = isSandbox ? "https://sandbox-quickbooks.api.intuit.com" : "https://quickbooks.api.intuit.com";
  const url = new URL(`${base}/v3/company/${realmId}/${path}`);
  for (const [key, value] of Object.entries({ ...query, minorversion: MINOR_VERSION })) {
    url.searchParams.set(key, value);
  }
  const response = await fetch(url, {
    headers: { Authorization: `Bearer ${accessToken}`, Accept: "application/json" },
    signal: AbortSignal.timeout(120_000),
  });
  const body = await response.text();
  if (!response.ok) {
    throw new Error(`QuickBooks ${path} returned HTTP ${response.status}: ${body.slice(0, 500)}`);
  }
  return body;
}

function wrap(run) {
  return async ({ params }) => {
    try {
      return { content: [{ type: "text", text: await run(params) }] };
    } catch (error) {
      return { content: [{ type: "text", text: String(error?.message ?? error) }], isError: true };
    }
  };
}

const server = QuickbooksMCPServer.GetServer();

server.tool(
  "__qbobar_query",
  "Internal to QBO MCP Proxy: run a read-only QuickBooks query statement.",
  { params: z.object({ query: z.string().min(1) }) },
  wrap(({ query }) => {
    if (!/^\s*select\s/i.test(query)) throw new Error("Only SELECT queries are allowed.");
    return qboGet("query", { query });
  }),
);

server.tool(
  "__qbobar_cdc",
  "Internal to QBO MCP Proxy: Change Data Capture since a timestamp (at most 30 days back).",
  { params: z.object({ entities: z.string().min(1), changedSince: z.string().min(1) }) },
  wrap(({ entities, changedSince }) => qboGet("cdc", { entities, changedSince })),
);

// Intuit's entry registers its tools on the same singleton, then connects.
await import("./index.js");
