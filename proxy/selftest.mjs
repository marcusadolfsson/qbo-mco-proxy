// Self-test for qbo-proxy. Connects as an MCP HTTP+SSE client, exercises a real tool call,
// then the destroy/reconnect torture + concurrent clients that crash a 1:1 bridge.
//
// Run inside the container against a company slug you have configured:
//   docker exec -e TSLUG=<your-slug> qbo-mcp node /app/proxy/selftest.mjs
import http from "node:http";
const PORT = Number(process.env.TPORT || 8200);
const SLUG = process.env.TSLUG || "";
if (!SLUG) { console.error("set TSLUG=<company-slug>"); process.exit(2); }

function sse(onEndpoint, onMessage) {
  const req = http.get({ host: "localhost", port: PORT, path: `/${SLUG}/sse` }, (res) => {
    let buf = "";
    res.on("data", (d) => {
      buf += d; let i;
      while ((i = buf.indexOf("\n\n")) >= 0) {
        const evt = buf.slice(0, i); buf = buf.slice(i + 2);
        const ev = /event: (\w+)/.exec(evt)?.[1];
        const data = /data: (.*)/s.exec(evt)?.[1];
        if (ev === "endpoint") onEndpoint(data, req);
        else if (ev === "message") onMessage(JSON.parse(data), req);
      }
    });
  });
  req.on("error", (e) => console.log("  SSE err", e.code || e.message));
  return req;
}
function post(endpoint, msg) {
  const body = JSON.stringify(msg);
  const req = http.request({ host: "localhost", port: PORT, path: endpoint, method: "POST",
    headers: { "content-type": "application/json", "content-length": Buffer.byteLength(body) } }, (r) => r.resume());
  req.on("error", () => {});
  req.end(body);
}
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
async function rpc(label, method, params) {
  return new Promise((resolve) => {
    const want = Math.floor(Math.random() * 1e6);
    const req = sse(
      (endpoint) => post(endpoint, { jsonrpc: "2.0", id: want, method, params: params || {} }),
      (msg) => { if (msg.id === want) { console.log(`  ${label}: ${msg.error ? "ERROR " + msg.error.message : "OK"}`); req.destroy(); resolve(msg); } }
    );
    setTimeout(() => { console.log(`  ${label}: TIMEOUT`); req.destroy(); resolve(null); }, 15000);
  });
}

(async () => {
  console.log("1) health"); await new Promise((res) => http.get({host:"localhost",port:PORT,path:`/${SLUG}/healthz`},(r)=>{console.log("  status",r.statusCode);r.resume();res();}));
  console.log("2) initialize"); await rpc("initialize", "initialize", { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "t", version: "1" } });
  console.log("3) tools/list"); const tl = await rpc("tools/list", "tools/list"); if (tl?.result?.tools) console.log("   tools:", tl.result.tools.length);
  console.log("4) real tool call get_company_info");
  await new Promise((resolve) => {
    const id = 999;
    const req = sse((endpoint) => post(endpoint, { jsonrpc:"2.0", id, method:"tools/call", params:{ name:"get_company_info", arguments:{ params:{} } } }),
      (msg) => { if (msg.id === id) { console.log("   reply:", JSON.stringify(msg.result||msg.error).slice(0,90)); req.destroy(); resolve(); } });
    setTimeout(()=>{console.log("   TIMEOUT");req.destroy();resolve();},20000);
  });
  console.log("5) TORTURE: open A, destroy ungracefully, then B + C must still work");
  const a = sse(() => { console.log("  A connected"); setTimeout(() => { console.log("  A destroyed"); a.destroy(); }, 400); }, () => {});
  await wait(1200);
  await rpc("B after drop", "tools/list");
  await rpc("C after drop", "tools/list");
  console.log("6) CONCURRENT: two clients at once");
  await Promise.all([rpc("client-1", "tools/list"), rpc("client-2", "tools/list")]);
  console.log("DONE"); process.exit(0);
})();
