// A stand-in for Intuit's server: newline-delimited JSON-RPC over stdio, with
// tools that misbehave on request so the gateway's supervision can be tested.
import { createInterface } from "node:readline";

let initializeCount = 0;
let writes = 0;
let throttled = 0;
const reply = (id, result) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
const text = (id, t, isError) => reply(id, { content: [{ type: "text", text: t }], ...(isError ? { isError: true } : {}) });

const tools = ["echo", "slow", "fail", "soft_fail", "crash", "authfail", "init_count", "create_journal_entry",
  "update-bill", "write_count", "search_customers", "get_general_ledger", "__qbobar_query", "__qbobar_cdc"]
  .map((name) => ({ name, description: `fake ${name}`, inputSchema: { type: "object" } }));

createInterface({ input: process.stdin }).on("line", async (line) => {
  const msg = JSON.parse(line);
  if (msg.method === "initialize") {
    initializeCount++;
    return reply(msg.id, { protocolVersion: "2024-11-05", capabilities: { tools: { listChanged: true } },
      serverInfo: { name: "Fake QBO", version: "0.0.1" } });
  }
  if (msg.method === "notifications/initialized") return;
  if (msg.method === "tools/list") return reply(msg.id, { tools });
  if (msg.method !== "tools/call") return;

  const { name, arguments: args = {} } = msg.params;
  const p = args.params || {};
  switch (name) {
    case "echo":
      return text(msg.id, `Echo created successfully: ${JSON.stringify({ Id: String(p.n ?? 0), SyncToken: "0", Line: [{ Id: "999" }] })}`);
    case "slow":
      await new Promise((r) => setTimeout(r, p.ms ?? 300));
      return text(msg.id, `slow ${p.tag ?? ""}`);
    case "fail":
      return text(msg.id, `Error: fake failure ${p.n ?? ""}`, true);
    case "crash":
      process.exit(3);
    case "authfail":
      console.error("[qbo-client] Token refresh failed (invalid_grant); falling back to interactive OAuth");
      return; // hang, as the upstream does while it waits for a browser
    case "init_count":
      return text(msg.id, String(initializeCount));
    case "soft_fail":
      // Intuit's tools mostly report failure like this: text, no isError.
      return text(msg.id, "Error: Object Not Found");
    case "create_journal_entry":
      writes++;
      return text(msg.id, `Journal entry created successfully: ${JSON.stringify({
        Id: String(900 + writes), SyncToken: "0", DocNumber: p.journalEntry?.DocNumber ?? null,
        TxnDate: "2026-09-30", TotalAmt: 0.01 })}`);
    case "update-bill":
      if (throttled < 1) { throttled++; return text(msg.id, "Error: Request failed with status code 429 (ThrottleExceeded)"); }
      writes++;
      return text(msg.id, `Bill updated: ${JSON.stringify({ Id: "5", SyncToken: "2" })}`);
    case "write_count":
      return text(msg.id, String(writes));
    case "get_general_ledger": {
      const col = (title, key) => ({ ColTitle: title, MetaData: [{ Name: "ColKey", Value: key }] });
      const data = (date, type, id, num, name, memo, split, amount, balance) => ({ type: "Data", ColData: [
        { value: date }, { value: type, id }, { value: num }, { value: name }, { value: memo },
        { value: split, id: "440" }, { value: amount }, { value: balance }, { value: "No" }] });
      const report = {
        Header: { StartPeriod: "2026-01-01", EndPeriod: "2026-09-30" },
        Columns: { Column: [col("Date", "tx_date"), col("Transaction Type", "txn_type"), col("Num", "doc_num"),
          col("Name", "name"), col("Memo/Description", "memo"), col("Split", "split_acc"),
          col("Amount", "subt_nat_amount"), col("Balance", "rbal_nat_amount"), col("Adj", "is_adj")] },
        Rows: { Row: [{
          type: "Section", Header: { ColData: [{ value: "Bad Debt Loss", id: "439" }] },
          Rows: { Row: [
            data("2025-12-31", "Journal Entry", "36855", "WO-1", "Bodystack", "write-off", "Loans to Bodystack", "210526.25", "210526.25"),
            data("2025-12-31", "Journal Entry", "36856", "WO-2", "Kloozed", "write-off", "Loans to Kloozed", "79268.72", "289794.97"),
            data("2026-02-01", "Check", "900", "1001", "Shell", "fuel", "Checking", "45.10", "289840.07"),
          ] },
          Summary: { ColData: [{ value: "Total for Bad Debt Loss" }, {}, {}, {}, {}, {}, { value: "289840.07" }, {}] },
        }] },
      };
      return reply(msg.id, { content: [{ type: "text", text: "General Ledger Report:" }, { type: "text", text: JSON.stringify(report) }] });
    }
    case "search_customers":
      return text(msg.id, "Found 0 customers"); // the broken count path must never get here
    case "__qbobar_query": {
      const q = p.query;
      if (q.startsWith("SELECT * FROM CompanyInfo"))
        return text(msg.id, JSON.stringify({ QueryResponse: { CompanyInfo: [{ LegalName: "Acme Aviation, LLC", CompanyName: "Acme Aviation" }] } }));
      if (q.startsWith("SELECT COUNT(*)"))
        return text(msg.id, JSON.stringify({ QueryResponse: { totalCount: 42 } }));
      const entity = q.split(" ")[3];
      const staples = { value: "3", name: "Staples" };
      const rows = {
        Purchase: [
          { Id: "77", TxnDate: "2026-09-01", TotalAmt: 12.5, PrivateNote: "cache test", SyncToken: "0",
            EntityRef: staples, MetaData: { LastUpdatedTime: "2026-09-01T10:00:00-07:00" },
            Line: [{ Id: "1", Amount: 12.5, DetailType: "AccountBasedExpenseLineDetail",
                     AccountBasedExpenseLineDetail: { AccountRef: { value: "9", name: "Office Supplies" } } }] },
          { Id: "78", TxnDate: "2026-09-02", TotalAmt: 40, SyncToken: "0",
            EntityRef: { value: "4", name: "Shell" }, MetaData: { LastUpdatedTime: "2026-09-02T10:00:00-07:00" }, Line: [] },
        ],
        Vendor: /like '%stap/i.test(q) ? [{ Id: "3", DisplayName: "Staples" }] : [],
        Bill: /VendorRef = '3'/.test(q) ? [{ Id: "12", TxnDate: "2026-08-15", TotalAmt: 99, VendorRef: staples,
                                             MetaData: { LastUpdatedTime: "2026-08-15T10:00:00-07:00" }, Line: [] }] : [],
        Account: [{ Id: "9", Name: "Office Supplies", FullyQualifiedName: "Expenses:Office Supplies",
                    AccountType: "Expense", Active: true, CurrentBalance: 0,
                    MetaData: { LastUpdatedTime: "2026-01-01T00:00:00-07:00" } }],
      }[entity] ?? [];
      return text(msg.id, JSON.stringify({ QueryResponse: { [entity]: rows } }));
    }
    case "__qbobar_cdc":
      return text(msg.id, JSON.stringify({ CDCResponse: [{ QueryResponse: [] }] }));
  }
});
