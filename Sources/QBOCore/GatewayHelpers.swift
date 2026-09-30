import Foundation

/// `count: true` on Intuit's search tools, done properly.
///
/// The upstream passes `count` into node-quickbooks as if it were a filter,
/// which breaks the query or returns an empty list. The gateway answers such
/// calls itself with `SELECT COUNT(*)`, translating the same criteria shapes
/// the upstream accepts.
enum CountQuery {
    static let entities: [String: String] = [
        "search_customers": "Customer", "search_estimates": "Estimate", "search_bills": "Bill",
        "search_invoices": "Invoice", "search_accounts": "Account", "search_items": "Item",
        "search_vendors": "Vendor", "search_employees": "Employee", "search_journal_entries": "JournalEntry",
        "search_bill_payments": "BillPayment", "search_purchases": "Purchase",
    ]

    static let metaFields: Set<String> = ["asc", "desc", "limit", "offset", "count", "fetchAll"]

    static func entity(for tool: String) -> String? { entities[tool] }

    /// True when the call asks for a count, at the top of `params` or inside
    /// its criteria (as an advanced-options object or a `{field: "count"}`).
    static func wantsCount(_ arguments: JSON) -> Bool {
        let params = arguments["params"] ?? arguments
        if params["count"]?.boolValue == true { return true }
        let criteria = params["criteria"]
        if criteria?["count"]?.boolValue == true { return true }
        return criteria?.arrayValue?.contains { $0["field"] == "count" && $0["value"]?.boolValue != false } ?? false
    }

    struct Unsupported: Error, CustomStringConvertible {
        let description: String
    }

    static func statement(entity: String, arguments: JSON) throws -> String {
        let params = arguments["params"] ?? arguments
        let conditions = try conditions(params["criteria"])
        let filter = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        return "SELECT COUNT(*) FROM \(entity)\(filter)"
    }

    /// The upstream's criteria shapes: `[{field, value, operator}]`,
    /// `[{key, value}]`, `{Field: value}`, or `{filters|criteria: [...]}`.
    static func conditions(_ criteria: JSON?) throws -> [String] {
        guard let criteria else { return [] }
        if let list = criteria.arrayValue {
            return try list.compactMap { item in
                let field = item["field"]?.stringValue ?? item["key"]?.stringValue
                guard let field, !metaFields.contains(field) else { return nil }
                return try condition(field, item["operator"]?.stringValue ?? "=", item["value"] ?? .null)
            }
        }
        guard let object = criteria.objectValue else { return [] }
        if let nested = object["filters"] ?? object["criteria"] { return try conditions(nested) }
        return try object.keys.sorted().compactMap { key in
            guard !metaFields.contains(key), let value = object[key] else { return nil }
            return try condition(key, "=", value)
        }
    }

    static func condition(_ field: String, _ operation: String, _ value: JSON) throws -> String {
        guard field.range(of: #"^[A-Za-z][A-Za-z0-9_.]*$"#, options: .regularExpression) != nil else {
            throw Unsupported(description: "Unsupported field name for count: \(field)")
        }
        let op = operation.uppercased()
        guard ["=", "<", ">", "<=", ">=", "LIKE", "IN"].contains(op) else {
            throw Unsupported(description: "Unsupported operator for count: \(operation)")
        }
        if op == "IN" {
            let items = value.arrayValue ?? [value]
            return "\(field) IN (\(try items.map(literal).joined(separator: ", ")))"
        }
        return "\(field) \(op) \(try literal(value))"
    }

    static func literal(_ value: JSON) throws -> String {
        switch value {
        case .string(let text): return "'" + text.replacingOccurrences(of: "'", with: "\\'") + "'"
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number):
            return number.rounded() == number ? String(Int64(number)) : String(number)
        default: throw Unsupported(description: "Unsupported value in count criteria.")
        }
    }
}

enum CompanyName {
    /// Compares company names the way a person would: case, punctuation and
    /// legal-form suffixes don't matter ("Aced Aviation, LLC" is "aced aviation").
    static func normalize(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var words = folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let suffixes: Set<String> = ["llc", "inc", "ltd", "corp", "corporation", "co", "company", "lp", "llp", "pllc", "pa", "plc"]
        while words.count > 1, let last = words.last, suffixes.contains(last) { words.removeLast() }
        return words.joined(separator: " ")
    }
}

/// Adds the gateway-only write options to Intuit's write tools, and to batch.
enum WriteOptions {
    static let expectCompany: JSON = [
        "type": "string",
        "description": "Optional safety check: the company you mean to change (legal name, company name, slug or realm ID). The write is refused, unsent, if this endpoint is a different company.",
    ]
    static let idempotencyKey: JSON = [
        "type": "string",
        "description": "Optional: a unique key for this write. Repeating a call with the same key within 24 hours returns the original result instead of posting again.",
    ]

    static func decorate(_ tool: JSON) -> JSON {
        guard let name = tool["name"]?.stringValue,
              CompanyGateway.isWrite(name) || name == Batch.toolName,
              let schema = tool["inputSchema"]
        else { return tool }
        var properties = schema["properties"]?.objectValue ?? [:]
        properties["expect_company"] = expectCompany
        if name != Batch.toolName { properties["idempotency_key"] = idempotencyKey }
        return tool.setting("inputSchema", to: schema.setting("properties", to: .object(properties)))
    }
}

/// Journal entries must balance before they're sent.
///
/// Checked on the lines (debits against credits), never on TotalAmt, which
/// QuickBooks reports as 0 even for a balanced entry.
enum JournalBalance {
    static let tools: Set<String> = ["create_journal_entry", "update_journal_entry"]

    /// Nil when balanced, or when there are no posting lines to check (a
    /// sparse update that doesn't touch the lines).
    static func problem(tool: String, arguments: JSON) -> String? {
        guard tools.contains(tool) else { return nil }
        let params = arguments["params"] ?? arguments
        let entry = params["journalEntry"] ?? params["journal_entry"] ?? params
        let lines = entry["Line"]?.arrayValue ?? []
        var debits = 0.0, credits = 0.0, posting = 0
        for line in lines {
            guard let detail = line["JournalEntryLineDetail"], let type = detail["PostingType"]?.stringValue else { continue }
            let amount = QBOCacheService.number(line["Amount"]) ?? 0
            posting += 1
            if type == "Debit" { debits += amount } else if type == "Credit" { credits += amount }
        }
        guard posting > 0 else { return nil }
        let cents = { (value: Double) in Int((value * 100).rounded()) }
        guard cents(debits) != cents(credits) else { return nil }
        let format = { (value: Double) in String(format: "%.2f", value) }
        return "Journal entry doesn't balance: debits \(format(debits)), credits \(format(credits)) "
            + "(off by \(format(abs(debits - credits)))). Nothing was sent to QuickBooks."
    }
}

/// Just enough JSON Schema to catch a malformed call before it's sent:
/// required keys, unknown keys where the schema forbids them, basic types,
/// one level into `params`.
enum SchemaCheck {
    static func problems(_ value: JSON, schema: JSON, path: String = "arguments") -> [String] {
        guard schema["type"] == "object" || schema["properties"] != nil else { return typeProblem(value, schema, path) }
        guard let object = value.objectValue else { return ["\(path) should be an object"] }
        var problems: [String] = []
        let properties = schema["properties"]?.objectValue ?? [:]
        for key in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[key] == nil {
            problems.append("\(path).\(key) is required")
        }
        if schema["additionalProperties"] == .bool(false) {
            for key in object.keys.sorted() where properties[key] == nil {
                problems.append("\(path).\(key) is not a known argument")
            }
        }
        for (key, child) in object.sorted(by: { $0.key < $1.key }) {
            guard let childSchema = properties[key] else { continue }
            if path == "arguments" {
                problems += Self.problems(child, schema: childSchema, path: "\(path).\(key)")
            } else {
                problems += typeProblem(child, childSchema, "\(path).\(key)")
            }
        }
        return problems
    }

    private static func typeProblem(_ value: JSON, _ schema: JSON, _ path: String) -> [String] {
        let types = schema["type"]?.arrayValue?.compactMap(\.stringValue) ?? schema["type"]?.stringValue.map { [$0] } ?? []
        guard !types.isEmpty else { return [] }
        let actual: String = switch value {
        case .string: "string"
        case .number: "number"
        case .bool: "boolean"
        case .array: "array"
        case .object: "object"
        case .null: "null"
        }
        let accepted = types.contains(actual) || (actual == "number" && types.contains("integer"))
        return accepted ? [] : ["\(path) should be \(types.joined(separator: " or ")), not \(actual)"]
    }
}

/// Flattens a QuickBooks report (nested sections of ColData rows) into one
/// row per line, keeping the section each row sits in.
enum ReportFlattener {
    /// QBO column keys → the names clients use.
    static let names: [String: String] = [
        "tx_date": "date", "txn_type": "txn_type", "doc_num": "doc_num", "name": "name", "memo": "memo",
        "split_acc": "split_account", "subt_nat_amount": "amount", "nat_amount": "amount",
        "rbal_nat_amount": "running_balance", "account_name": "account_name", "is_cleared": "cleared",
    ]
    static let numeric: Set<String> = ["amount", "running_balance"]
    /// Report columns that carry nothing a reader needs.
    static let dropped: Set<String> = ["is_adj"]

    struct Flat {
        var columns: [String]
        var rows: [JSON]
        var sectionTotals: [JSON]
    }

    static func flatten(_ report: JSON) -> Flat {
        let columns: [String] = (report["Columns"]?["Column"]?.arrayValue ?? []).map { column in
            let key = column["MetaData"]?.arrayValue?.first { $0["Name"] == "ColKey" }?["Value"]?.stringValue
                ?? column["ColTitle"]?.stringValue?.lowercased().replacingOccurrences(of: " ", with: "_") ?? "column"
            return names[key] ?? key
        }
        var rows: [JSON] = []
        var totals: [JSON] = []
        func visit(_ list: [JSON], section: (name: String, id: String?)?) {
            for row in list {
                if let data = row["ColData"]?.arrayValue, row["Rows"] == nil {
                    var item: [String: JSON] = [:]
                    for (index, cell) in data.enumerated() where index < columns.count {
                        let key = columns[index]
                        let text = cell["value"]?.stringValue ?? ""
                        if text.isEmpty || dropped.contains(key) { continue }
                        item[key] = numeric.contains(key) ? (Double(text).map { .number($0) } ?? .string(text)) : .string(text)
                        if key == "txn_type", let id = cell["id"]?.stringValue { item["txn_id"] = .string(id) }
                        if key == "split_account", let id = cell["id"]?.stringValue { item["split_account_id"] = .string(id) }
                    }
                    if let section {
                        item["account"] = .string(section.name)
                        if let id = section.id { item["account_id"] = .string(id) }
                    }
                    if !item.isEmpty { rows.append(.object(item)) }
                    continue
                }
                let header = row["Header"]?["ColData"]?.arrayValue?.first
                let current = header.map { (name: $0["value"]?.stringValue ?? "", id: $0["id"]?.stringValue) } ?? section
                visit(row["Rows"]?["Row"]?.arrayValue ?? [], section: current)
                if let summary = row["Summary"]?["ColData"]?.arrayValue, let current,
                   let amountIndex = columns.firstIndex(of: "amount"), amountIndex < summary.count {
                    let value = summary[amountIndex]["value"]?.stringValue ?? ""
                    totals.append(["account": .string(current.name), "account_id": current.id.map { .string($0) } ?? .null,
                                   "total": Double(value).map { .number($0) } ?? .string(value)])
                }
            }
        }
        visit(report["Rows"]?["Row"]?.arrayValue ?? [], section: nil)
        return Flat(columns: columns, rows: rows, sectionTotals: totals)
    }
}
