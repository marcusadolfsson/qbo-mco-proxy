import Foundation

/// Tools a company endpoint answers itself instead of forwarding upstream.
public struct LocalTools: Sendable {
    public var definitions: [JSON]
    public var call: @Sendable (_ name: String, _ arguments: JSON) async -> JSON

    public init(definitions: [JSON], call: @escaping @Sendable (String, JSON) async -> JSON) {
        self.definitions = definitions
        self.call = call
    }

    public func handles(_ name: String) -> Bool {
        definitions.contains { $0["name"] == .string(name) }
    }

    /// Several tool sets as one; each call goes to the set that defines it.
    public static func merged(_ sets: [LocalTools]) -> LocalTools {
        LocalTools(definitions: sets.flatMap(\.definitions)) { name, arguments in
            guard let owner = sets.first(where: { $0.handles(name) }) else {
                return ["content": [["type": "text", "text": .string("Unknown tool: \(name)")]], "isError": true]
            }
            return await owner.call(name, arguments)
        }
    }
}

/// `whoami` and `list_recent_writes`: answered from the gateway's own
/// knowledge of the company and its write log, no QuickBooks call needed
/// beyond the (cached) company names.
public enum CompanyTools {
    public static func make(gateway: CompanyGateway, audit: WriteAudit?) -> LocalTools {
        LocalTools(definitions: definitions) { name, arguments in
            let args = arguments["params"].flatMap { $0.objectValue != nil ? $0 : nil } ?? arguments
            switch name {
            case "whoami":
                return QBOCacheService.text(await gateway.whoami())
            case "get_general_ledger_compact":
                return await generalLedger(gateway, args)
            case "list_recent_writes":
                guard let audit else { return QBOCacheService.error("The write log isn't available.") }
                do {
                    return QBOCacheService.text(try await audit.recent(
                        limit: QBOCacheService.number(args["limit"]).map { Int($0) } ?? 20,
                        since: args["since"]?.stringValue, tool: args["tool"]?.stringValue,
                        entityID: args["entity_id"]?.stringValue))
                } catch {
                    return QBOCacheService.error("\(error)")
                }
            default:
                return QBOCacheService.error("Unknown tool \(name).")
            }
        }
    }

    /// The general ledger, flat and paged: Intuit's report nests rows in
    /// account sections, and a single account's year can run to ~66 KB.
    static func generalLedger(_ gateway: CompanyGateway, _ args: JSON) async -> JSON {
        var upstream: [String: JSON] = [:]
        for key in ["start_date", "end_date", "accounting_method", "account", "source_account", "sort_by"] {
            if let value = args[key], value != .null { upstream[key] = value }
        }
        let response = await gateway.forwardWithRetry(
            CompanyGateway.toolCall("get_general_ledger", ["params": .object(upstream)], id: 0), id: 0)
        guard !ToolResult.isFailure(response) else {
            return QBOCacheService.error(CompanyGateway.errorText(response))
        }
        let texts = response["result"]?["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue } ?? []
        guard let report = texts.lazy.compactMap({ try? JSON.parse($0) }).first(where: { $0["Rows"] != nil || $0["Header"] != nil }) else {
            return QBOCacheService.error("The general ledger came back in an unexpected format.")
        }
        let flat = ReportFlattener.flatten(report)
        var rows = flat.rows
        if let q = args["q"]?.stringValue?.lowercased(), !q.isEmpty {
            rows = rows.filter { row in
                ["name", "memo", "doc_num", "split_account"].contains { (row[$0]?.stringValue?.lowercased() ?? "").contains(q) }
            }
        }
        let limit = min(max(QBOCacheService.number(args["limit"]).map { Int($0) } ?? 200, 1), 1000)
        let offset = max(QBOCacheService.number(args["offset"]).map { Int($0) } ?? 0, 0)
        let page = Array(rows.dropFirst(offset).prefix(limit))
        return QBOCacheService.text([
            "period": ["start": report["Header"]?["StartPeriod"] ?? .null, "end": report["Header"]?["EndPeriod"] ?? .null],
            "total_rows": .number(Double(rows.count)), "offset": .number(Double(offset)),
            "returned": .number(Double(page.count)), "has_more": .bool(offset + page.count < rows.count),
            "rows": .array(page),
            "account_totals": .array(flat.sectionTotals),
        ])
    }

    static let definitions: [JSON] = [
        [
            "name": "get_general_ledger_compact",
            "description": """
                The general ledger as flat, paged rows instead of Intuit's nested report: one row per line with \
                {date, txn_type, txn_id, doc_num, name, memo, split_account, amount, running_balance, account, \
                account_id}, plus per-account totals. Same filters as get_general_ledger (start_date, end_date, \
                accounting_method, account, source_account, sort_by), a q substring filter over name, memo, doc \
                number and split account, and limit (default 200, max 1000) / offset for paging.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "start_date": ["type": "string", "description": "YYYY-MM-DD"],
                    "end_date": ["type": "string", "description": "YYYY-MM-DD"],
                    "accounting_method": ["type": "string", "enum": ["Cash", "Accrual"]],
                    "account": ["type": "string", "description": "Account ID"],
                    "source_account": ["type": "string"],
                    "sort_by": ["type": "string"],
                    "q": ["type": "string"],
                    "limit": ["type": "number"],
                    "offset": ["type": "number"],
                ],
            ],
        ],
        [
            "name": "whoami",
            "description": """
                Which QuickBooks company this endpoint reads and writes: {slug, name, legal_name, company_name, \
                realm_id, environment, read_only}. A cheap identity check before writing (instead of \
                get_company_info); pair with expect_company on write tools.
                """,
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "list_recent_writes",
            "description": """
                The write log for this company: every create/update/delete that went through this gateway, newest \
                first, with time, tool, success, Id, SyncToken, DocNumber, TxnDate, TotalAmt, the client that sent \
                it, and the full arguments. Filters: since (ISO time), tool, entity_id. Default limit 20, max 200.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": ["type": "number"],
                    "since": ["type": "string", "description": "ISO 8601, e.g. 2026-09-18T00:00:00Z"],
                    "tool": ["type": "string", "description": "e.g. create_journal_entry"],
                    "entity_id": ["type": "string"],
                ],
            ],
        ],
    ]
}

/// A one-line summary of a company's cache, for the menu.
public struct CacheSummary: Sendable, Equatable {
    public var state: String  // fresh | stale | never_synced | needs_auth | syncing | error
    public var lastSuccess: Date?
    public var transactions: Int
    public var lastError: String?

    public init(state: String, lastSuccess: Date?, transactions: Int, lastError: String?) {
        self.state = state
        self.lastSuccess = lastSuccess
        self.transactions = transactions
        self.lastError = lastError
    }
}

/// The read-cache for every company: stores, the hourly sync, daily
/// backups, and the `cache_*` tools.
public actor QBOCacheService {
    public nonisolated let directory: URL
    private let log: FileLog
    private let scheduler = JobScheduler()
    private var stores: [String: QBOCacheStore] = [:]
    private var fetchers: [String: QBOFetcher] = [:]
    private var summaries: [String: CacheSummary] = [:]
    private var syncing: Set<String> = []
    private var lastResults: [String: QBOCacheSync.Result] = [:]
    /// Manual syncs closer together than this reuse the last result.
    static let manualSyncSpacing: TimeInterval = 30

    public static let syncInterval: TimeInterval = 3600
    public static let backupRetentionDays = 5

    public init(directory: URL) {
        self.directory = directory
        log = FileLog(url: directory.appendingPathComponent("sync.log"))
    }

    public func databasePath(_ slug: String) -> String {
        directory.appendingPathComponent("\(slug).db").path
    }

    // MARK: Companies

    /// Opens (or creates) a company's cache and remembers how to fetch for it.
    public func attach(slug: String, fetcher: QBOFetcher) throws {
        if stores[slug] == nil {
            let store = try QBOCacheStore(slug: slug, path: databasePath(slug))
            stores[slug] = store
        }
        fetchers[slug] = fetcher
        Task { await refreshSummary(slug) }
    }

    public func detach(slug: String) {
        stores[slug] = nil
        fetchers[slug] = nil
        summaries[slug] = nil
    }

    /// Deletes the company's cache file; the next sync rebuilds from scratch.
    public func rebuild(slug: String) async throws {
        guard let fetcher = fetchers[slug] else { return }
        stores[slug] = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: databasePath(slug) + suffix)
        }
        try attach(slug: slug, fetcher: fetcher)
        log.write("[\(slug)] [cache] rebuilding from scratch")
        await sync(slug: slug)
    }

    // MARK: Scheduling

    public func start() async {
        await scheduler.schedule("qbo-cache-sync", every: Self.syncInterval, initialDelay: 30) { [weak self] in
            guard let self else { return .init(summary: "stopped") }
            return await self.syncAll()
        }
        await scheduler.schedule("qbo-cache-backup", every: 86400, initialDelay: 600) { [weak self] in
            guard let self else { return .init(summary: "stopped") }
            return await self.backupAll()
        }
    }

    public func stop() async { await scheduler.stopAll() }

    public func syncNow() async { await scheduler.runNow("qbo-cache-sync") }

    func syncAll() async -> JobScheduler.Outcome {
        var failed = false
        var parts: [String] = []
        for slug in stores.keys.sorted() {
            let result = await sync(slug: slug)
            if result?.status != "ok" { failed = true }
            parts.append("\(slug): \(result?.status ?? "skipped")")
        }
        return .init(summary: parts.joined(separator: ", "), failed: failed)
    }

    /// Syncs one company now. Companies are synced one at a time, so the
    /// hourly run and a manual one never overlap on the same file.
    @discardableResult
    public func sync(slug: String, only: Set<String>? = nil) async -> QBOCacheSync.Result? {
        guard let store = stores[slug], let fetcher = fetchers[slug], !syncing.contains(slug) else { return nil }
        syncing.insert(slug)
        summaries[slug]?.state = "syncing"
        let result = await QBOCacheSync.run(store: store, fetcher: fetcher, log: log, only: only)
        syncing.remove(slug)
        lastResults[slug] = result
        await refreshSummary(slug, needsAuth: result.status == "needs_auth")
        return result
    }

    private func refreshSummary(_ slug: String, needsAuth: Bool = false) async {
        guard let store = stores[slug], let status = try? await store.status(needsAuth: needsAuth) else { return }
        let last = status["last_successful_sync"]?.stringValue.flatMap(QBOCacheSync.date)
        summaries[slug] = CacheSummary(
            state: status["state"]?.stringValue ?? "unknown", lastSuccess: last,
            transactions: (try? await store.transactionCount()) ?? 0,
            lastError: status["last_run"]?["error"]?.stringValue)
    }

    public func summary(_ slug: String) -> CacheSummary? { summaries[slug] }

    // MARK: Backups

    func backupAll() async -> JobScheduler.Outcome {
        let folder = directory.appendingPathComponent("backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        var failures: [String] = []
        for (slug, store) in stores {
            let target = folder.appendingPathComponent("\(slug)-\(day).db").path
            try? FileManager.default.removeItem(atPath: target)
            do {
                try await store.backup(to: target)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target)
            } catch {
                failures.append("\(slug): \(error)")
            }
        }
        // Keep the last few days per company.
        let cutoff = Date().addingTimeInterval(-Double(Self.backupRetentionDays) * 86400)
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
        log.write("[cache] backup \(failures.isEmpty ? "ok" : "failed: \(failures.joined(separator: "; "))")")
        return .init(summary: failures.isEmpty ? "ok" : failures.joined(separator: "; "), failed: !failures.isEmpty)
    }

    // MARK: Tools

    /// The three read-only tools for one company's endpoint. Each closes over
    /// that company's slug, so a call on /acme/mcp can only ever reach
    /// acme.db.
    public nonisolated func tools(for slug: String, needsAuth: @escaping @Sendable () async -> Bool) -> LocalTools {
        LocalTools(definitions: Self.definitions) { [weak self] name, arguments in
            guard let self else { return Self.error("The cache is shutting down.") }
            let args = arguments["params"].flatMap { $0.objectValue != nil ? $0 : nil } ?? arguments
            switch name {
            case "cache_status": return await self.statusTool(slug, needsAuth: await needsAuth())
            case "cache_search": return await self.searchTool(slug, args)
            case "cache_sql": return await self.sqlTool(slug, args)
            case "cache_sync_now": return await self.syncNowTool(slug, args)
            case "list_accounts_compact": return await self.accountsTool(slug, args)
            case "search_purchases_by_vendor": return await self.vendorSearchTool(slug, args)
            default: return Self.error("Unknown cache tool \(name).")
            }
        }
    }

    private func statusTool(_ slug: String, needsAuth: Bool) async -> JSON {
        guard let store = stores[slug] else { return Self.error("No cache for \(slug).") }
        do {
            var status = try await store.status(needsAuth: needsAuth)
            if syncing.contains(slug) { status = status.setting("syncing", to: true) }
            return Self.text(status)
        } catch {
            return Self.error("\(error)")
        }
    }

    private func searchTool(_ slug: String, _ args: JSON) async -> JSON {
        guard let store = stores[slug] else { return Self.error("No cache for \(slug).") }
        var query = QBOCacheStore.SearchQuery()
        query.text = args["q"]?.stringValue
        query.entityType = args["entity_type"]?.stringValue
        query.accountID = args["account_id"]?.stringValue
        query.accountName = args["account_name"]?.stringValue
        query.vendor = args["vendor"]?.stringValue
        query.dateFrom = args["date_from"]?.stringValue
        query.dateTo = args["date_to"]?.stringValue
        query.amount = Self.number(args["amount"])
        query.amountMin = Self.number(args["amount_min"])
        query.amountMax = Self.number(args["amount_max"])
        query.credit = args["credit"]?.boolValue
        query.includeDeleted = args["include_deleted"]?.boolValue ?? false
        query.limit = Self.number(args["limit"]).map { Int($0) } ?? 50
        query.offset = Self.number(args["offset"]).map { Int($0) } ?? 0
        do {
            return Self.text(try await store.search(query))
        } catch {
            return Self.error("\(error)")
        }
    }

    private func sqlTool(_ slug: String, _ args: JSON) async -> JSON {
        guard stores[slug] != nil else { return Self.error("No cache for \(slug).") }
        guard let sql = args["sql"]?.stringValue else { return Self.error("cache_sql needs 'sql'.") }
        let limit = min(max(Self.number(args["limit"]).map { Int($0) } ?? 200, 1), 1000)
        let path = databasePath(slug)
        // Off the actor: a slow query shouldn't hold up syncs or other tools.
        let outcome: Result<ReadOnlySQL.Result, Error> = await Task.detached {
            Result { try ReadOnlySQL.run(sql: sql, path: path, limits: .init(maxRows: limit)) }
        }.value
        switch outcome {
        case .success(let result):
            return Self.text([
                "columns": .array(result.columns.map { .string($0) }),
                "rows": .array(result.rows.map { .array($0.map(\.json)) }),
                "row_count": .number(Double(result.rows.count)),
                "truncated": .bool(result.truncated),
            ])
        case .failure(let error):
            return Self.error("\(error)")
        }
    }

    /// `cache_sync_now`: the menu's Sync Cache Now, for clients. One run per
    /// company at a time: a call during a run joins it rather than starting
    /// another, and calls within 30 seconds of the last reuse its result.
    private func syncNowTool(_ slug: String, _ args: JSON) async -> JSON {
        guard stores[slug] != nil else { return Self.error("No cache for \(slug).") }
        let wait = args["wait"]?.boolValue ?? true
        var only: Set<String>?
        if let requested = args["entity_types"]?.arrayValue?.compactMap(\.stringValue), !requested.isEmpty {
            let known = Set(QBOCacheStore.entityTypes.map(\.name))
            let unknown = requested.filter { !known.contains($0) }
            guard unknown.isEmpty else {
                return Self.error("Unknown entity types: \(unknown.joined(separator: ", ")). Known: \(known.sorted().joined(separator: ", ")).")
            }
            only = Set(requested)
        }
        if syncing.contains(slug) {
            guard wait else { return Self.text(["status": "already_running", "poll": "cache_status"]) }
            while syncing.contains(slug) { try? await Task.sleep(for: .milliseconds(500)) }
            return Self.text(lastResults[slug].map { $0.json.setting("joined_running_sync", to: true) } ?? ["status": "unknown"])
        }
        if let last = lastResults[slug], Date().timeIntervalSince(last.finished) < Self.manualSyncSpacing {
            return Self.text(last.json.setting("note", to: "Synced moments ago; returning that run's result."))
        }
        guard wait else {
            Task { await self.sync(slug: slug, only: only) }
            return Self.text(["status": "started", "poll": "cache_status"])
        }
        guard let result = await sync(slug: slug, only: only) else { return Self.error("Couldn't start a sync for \(slug).") }
        return Self.text(result.json)
    }

    private func accountsTool(_ slug: String, _ args: JSON) async -> JSON {
        guard let store = stores[slug] else { return Self.error("No cache for \(slug).") }
        do {
            return Self.text(try await store.accounts(
                contains: args["contains"]?.stringValue, type: args["type"]?.stringValue,
                activeOnly: args["active_only"]?.boolValue ?? true,
                limit: Self.number(args["limit"]).map { Int($0) } ?? 500))
        } catch {
            return Self.error("\(error)")
        }
    }

    /// `search_purchases_by_vendor`: live, because QuickBooks can't filter
    /// Purchases by payee. Finds matching vendors, scans Purchases in the date
    /// range and filters them here, adds that vendor's Bills (which can be
    /// filtered), and returns compact rows. Everything scanned also refreshes
    /// the cache.
    private func vendorSearchTool(_ slug: String, _ args: JSON) async -> JSON {
        guard let fetcher = fetchers[slug], let store = stores[slug] else { return Self.error("No cache for \(slug).") }
        guard let vendor = args["vendor"]?.stringValue?.trimmingCharacters(in: .whitespaces), !vendor.isEmpty else {
            return Self.error("search_purchases_by_vendor needs 'vendor'.")
        }
        let day = { (date: Date) in ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withFullDate]) }
        let dateFrom = args["date_from"]?.stringValue ?? day(Date().addingTimeInterval(-365 * 86400))
        let dateTo = args["date_to"]?.stringValue ?? day(Date())
        for date in [dateFrom, dateTo] where date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil {
            return Self.error("Dates must be YYYY-MM-DD (got \(date)).")
        }
        let limit = min(max(Self.number(args["limit"]).map { Int($0) } ?? 50, 1), 500)
        let includeBills = args["include_bills"]?.boolValue ?? true
        // Backslashes dropped before quotes are escaped: QuickBooks escapes
        // with a backslash, so one in the input could unescape our quote.
        let quoted = vendor.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "'", with: "\\'")
        do {
            let vendorResponse = try await fetcher.query(
                "SELECT * FROM Vendor WHERE DisplayName LIKE '%\(quoted)%' AND Active IN (true, false) MAXRESULTS 100")
            let vendors = vendorResponse["QueryResponse"]?["Vendor"]?.arrayValue ?? []
            let ids = Set(vendors.compactMap { $0["Id"]?.stringValue })
            let matched: [JSON] = vendors.map { ["id": $0["Id"] ?? .null, "name": $0["DisplayName"] ?? .null] }
            guard !ids.isEmpty else {
                return Self.text(["total": 0, "vendors_matched": [], "rows": [], "date_from": .string(dateFrom), "date_to": .string(dateTo)])
            }

            var rows: [JSON] = []
            var scanned = 0
            var truncated = false
            let range = "TxnDate >= '\(dateFrom)' AND TxnDate <= '\(dateTo)'"
            var position = 1
            while true {
                if position > 20 * QBOCacheSync.pageSize { truncated = true; break }
                let page = try await fetcher.query(
                    "SELECT * FROM Purchase WHERE \(range) ORDERBY TxnDate DESC STARTPOSITION \(position) MAXRESULTS \(QBOCacheSync.pageSize)")
                let purchases = page["QueryResponse"]?["Purchase"]?.arrayValue ?? []
                scanned += purchases.count
                _ = try? await store.ingest(entity: "Purchase", objects: purchases, watermark: nil)
                rows += purchases.filter { ids.contains($0["EntityRef"]?["value"]?.stringValue ?? "") }
                    .map { QBOCacheStore.compactRow(entity: "Purchase", $0) }
                if purchases.count < QBOCacheSync.pageSize { break }
                position += QBOCacheSync.pageSize
            }
            if includeBills {
                for id in ids.sorted().prefix(25) {
                    let page = try await fetcher.query(
                        "SELECT * FROM Bill WHERE VendorRef = '\(id)' AND \(range) MAXRESULTS \(QBOCacheSync.pageSize)")
                    let bills = page["QueryResponse"]?["Bill"]?.arrayValue ?? []
                    _ = try? await store.ingest(entity: "Bill", objects: bills, watermark: nil)
                    rows += bills.map { QBOCacheStore.compactRow(entity: "Bill", $0) }
                }
            }
            rows.sort { ($0["txn_date"]?.stringValue ?? "") > ($1["txn_date"]?.stringValue ?? "") }
            return Self.text([
                "total": .number(Double(rows.count)), "returned": .number(Double(min(rows.count, limit))),
                "vendors_matched": .array(matched), "date_from": .string(dateFrom), "date_to": .string(dateTo),
                "purchases_scanned": .number(Double(scanned)), "truncated": .bool(truncated),
                "rows": .array(Array(rows.prefix(limit))),
            ])
        } catch {
            return Self.error("\(error)")
        }
    }

    static func number(_ value: JSON?) -> Double? {
        switch value {
        case .number(let n): n
        case .string(let s): Double(s)
        default: nil
        }
    }

    static func text(_ value: JSON) -> JSON {
        ["content": [["type": "text", "text": .string(value.encodedString())]]]
    }

    static func error(_ message: String) -> JSON {
        ["content": [["type": "text", "text": .string(message)]], "isError": true]
    }

    static let definitions: [JSON] = [
        [
            "name": "cache_sync_now",
            "description": """
                Refresh this company's cache now instead of waiting for the hourly run, e.g. right after posting \
                writes you want to verify from the cache. One run per company at a time: calling during a run \
                joins it, and calls within 30 seconds of the last run return that run's result. wait (default \
                true) returns {status, started_at, finished_at, rows_upserted, rows_deleted, entity_errors}; \
                wait:false starts it and returns at once (poll cache_status). entity_types limits the query pass \
                (deletions are always checked).
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "entity_types": ["type": "array", "items": ["type": "string"],
                                     "description": "e.g. [\"JournalEntry\", \"Purchase\"]; default all"],
                    "wait": ["type": "boolean"],
                ],
            ],
        ],
        [
            "name": "list_accounts_compact",
            "description": """
                The chart of accounts, compact: {id, fully_qualified_name, type, sub_type, classification, active, \
                current_balance}. contains is a case-insensitive substring match on the name (unlike \
                search_accounts, which needs the exact name). From the cache, refreshed hourly. active_only \
                defaults to true; limit defaults to 500.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "contains": ["type": "string"],
                    "type": ["type": "string", "description": "AccountType, sub-type or classification, e.g. Expense, Bank"],
                    "active_only": ["type": "boolean"],
                    "limit": ["type": "number"],
                ],
            ],
        ],
        [
            "name": "search_purchases_by_vendor",
            "description": """
                Live search of Purchases (and, by default, Bills) for a vendor, done server-side because QuickBooks \
                can't filter Purchases by payee. vendor is a substring of the vendor's display name. Dates \
                YYYY-MM-DD; the range defaults to the last 12 months. Returns compact rows like cache_search, \
                newest first, with the matched vendors. Use cache_search first when the cache is fresh enough; \
                this one reads QuickBooks directly (and refreshes the cache as it goes).
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "vendor": ["type": "string"],
                    "date_from": ["type": "string"],
                    "date_to": ["type": "string"],
                    "limit": ["type": "number", "description": "Default 50, max 500"],
                    "include_bills": ["type": "boolean", "description": "Default true"],
                ],
                "required": ["vendor"],
            ],
        ],
        [
            "name": "cache_search",
            "description": """
                Search this company's local cache of QuickBooks transactions (all history, synced hourly). \
                Much cheaper than fetchAll searches. Returns compact rows {id, entity_type, txn_date, doc_number, \
                entity_name, total_amt, memo, account_names[]} plus the total match count. q is a substring match on \
                memo, payee, doc number and line descriptions. Voided and deleted transactions are hidden unless \
                include_deleted. Default limit 50, max 500. Check cache_status for freshness; QuickBooks stays the \
                source of truth.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "q": ["type": "string", "description": "Substring of memo, payee, doc number or line description"],
                    "entity_type": ["type": "string", "description": "e.g. Purchase, Bill, JournalEntry, Deposit, Invoice"],
                    "account_id": ["type": "string"],
                    "account_name": ["type": "string", "description": "Substring of a line's account name"],
                    "vendor": ["type": "string", "description": "Substring of the payee (vendor or customer) name"],
                    "date_from": ["type": "string", "description": "YYYY-MM-DD, inclusive"],
                    "date_to": ["type": "string", "description": "YYYY-MM-DD, inclusive"],
                    "amount": ["type": "number", "description": "Exact total (sign ignored)"],
                    "amount_min": ["type": "number"],
                    "amount_max": ["type": "number"],
                    "credit": ["type": "boolean", "description": "Purchases that are credits (refunds)"],
                    "include_deleted": ["type": "boolean"],
                    "limit": ["type": "number"],
                    "offset": ["type": "number"],
                ],
            ],
        ],
        [
            "name": "cache_sql",
            "description": """
                Run one read-only SELECT (or WITH … SELECT) against this company's cache. Tables: txns, txn_lines, \
                accounts, vendors, customers, items, classes, sync_state, sync_runs (txns and the lists have \
                deleted/voided flags; raw holds the full QuickBooks JSON, usable with json_extract). Limited to \
                `limit` rows (default 200, max 1000), 5 seconds and ~200 KB; one statement, no comments.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "sql": ["type": "string"],
                    "limit": ["type": "number"],
                ],
                "required": ["sql"],
            ],
        ],
        [
            "name": "cache_status",
            "description": """
                Freshness of this company's cache: state (fresh, stale, never_synced, needs_auth), last successful \
                sync and age, the last run's result, and per entity type the watermark, row counts and last error.
                """,
            "inputSchema": ["type": "object", "properties": [:]],
        ],
    ]
}
