import Foundation

/// The `batch` tool: many tool calls in one MCP round trip.
///
/// It lives in the gateway rather than in Intuit's server, so it works on top
/// of any upstream version. If the upstream ever
/// ships its own `batch`, that one is listed and called instead (see
/// `addingTool`, which only adds this definition when the name is free).
public enum Batch {
    public static let toolName = "batch"
    public static let concurrency = 4
    public static let maxCalls = 200

    public static let definition: JSON = [
        "name": .string(toolName),
        "description": """
            Run MANY QBO write calls in ONE request (saves tokens + round-trips vs calling each tool \
            separately). Input: {calls:[{name, arguments}, ...], summary_only?} — each call item is exactly \
            what you'd pass to that tool on its own, INCLUDING its 'params' wrapper (e.g. \
            {name:'update_purchase', arguments:{params:{purchase:{Id, SyncToken, ...}}}}). Runs up to 4 \
            concurrently; each call is independent (one failure doesn't stop the rest). By DEFAULT returns a \
            terse {ok, failed, failures:[{index, name, error}]} — successes are implied (everything not in \
            failures, in input order), which is all you need for bulk classify. Pass summary_only:false to \
            instead get {ok, failed, results:[{ok:true, Id, SyncToken}|{ok:false, error}]} when you need each \
            SyncToken for chaining. Max 200 calls per request.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "calls": [
                    "type": "array",
                    "description": "Tool calls to execute, in order.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string", "description": "QBO tool name, e.g. 'update_purchase'."],
                            "arguments": [
                                "type": "object",
                                "description": "That tool's arguments (include its 'params' wrapper).",
                            ],
                        ],
                        "required": ["name", "arguments"],
                    ],
                ],
                "summary_only": [
                    "type": "boolean",
                    "description": "Default true: return only counts + failures. Set false for per-call results with Id/SyncToken.",
                ],
                "dry_run": [
                    "type": "boolean",
                    "description": "Check every call without sending any: expect_company, known tool, argument shape, journal balance, read-only key, idempotency keys already used. Returns per-index problems.",
                ],
            ],
            "required": ["calls"],
        ],
    ]

    /// Appends `batch` to a `tools/list` response unless the upstream already
    /// has a tool by that name.
    static func addingTool(to response: JSON) -> JSON {
        guard let tools = response["result"]?["tools"]?.arrayValue,
              !tools.contains(where: { $0["name"] == .string(toolName) }),
              let result = response["result"]
        else { return response }
        return response.setting("result", to: result.setting("tools", to: .array(tools + [definition])))
    }

    struct Call: Sendable {
        let name: String
        let arguments: JSON
    }

    struct Plan: Sendable {
        let calls: [Call]
        let summaryOnly: Bool

        struct Invalid: Error, CustomStringConvertible {
            let description: String
        }

        init(_ arguments: JSON) throws {
            guard let calls = arguments["calls"]?.arrayValue else {
                throw Invalid(description: "batch: 'calls' must be an array of {name, arguments}.")
            }
            guard !calls.isEmpty else { throw Invalid(description: "batch: 'calls' is empty.") }
            guard calls.count <= Batch.maxCalls else {
                throw Invalid(description: "batch: at most \(Batch.maxCalls) calls per request (got \(calls.count)).")
            }
            self.calls = try calls.enumerated().map { index, call in
                guard let name = call["name"]?.stringValue, !name.isEmpty else {
                    throw Invalid(description: "batch: call \(index) has no 'name'.")
                }
                guard name != Batch.toolName else {
                    throw Invalid(description: "batch: call \(index) is itself a batch; nesting is not allowed.")
                }
                return Call(name: name, arguments: call["arguments"] ?? [:])
            }
            summaryOnly = arguments["summary_only"]?.boolValue ?? true
        }
    }

    struct Outcome: Sendable {
        let ok: Bool
        let error: String?
        let entityID: String?
        let syncToken: String?

        init(response: JSON) {
            if ToolResult.isFailure(response) {
                ok = false
                error = CompanyGateway.errorText(response)
                entityID = nil
                syncToken = nil
                return
            }
            ok = true
            error = nil
            let text = response["result"]?["content"]?.arrayValue?
                .compactMap { $0["text"]?.stringValue }.joined(separator: "\n") ?? ""
            entityID = Self.firstString(named: "Id", in: text)
            syncToken = Self.firstString(named: "SyncToken", in: text)
        }

        /// Upstream results are prose followed by the entity as JSON, e.g.
        /// "Invoice created successfully: {…}". The entity's own Id and
        /// SyncToken come before any nested ones, so the first match is it.
        /// The first numeric value of `"key": 123.45` in text.
        static func firstNumber(named key: String, in text: String) -> Double? {
            let pattern = "\"\(key)\"\\s*:\\s*(-?[0-9]+(?:\\.[0-9]+)?)"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text)
            else { return nil }
            return Double(text[range])
        }

        static func firstString(named key: String, in text: String) -> String? {
            let pattern = "\"\(key)\"\\s*:\\s*\"([^\"]*)\""
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text)
            else { return nil }
            return String(text[range])
        }
    }

    static func summarize(plan: Plan, outcomes: [Outcome]) -> JSON {
        let ok = outcomes.filter(\.ok).count
        var summary: [String: JSON] = [
            "ok": .number(Double(ok)),
            "failed": .number(Double(outcomes.count - ok)),
        ]
        if plan.summaryOnly {
            summary["failures"] = .array(outcomes.enumerated().compactMap { index, outcome in
                guard !outcome.ok else { return nil }
                return [
                    "index": .number(Double(index)),
                    "name": .string(plan.calls[index].name),
                    "error": .string(outcome.error ?? "error"),
                ]
            })
        } else {
            summary["results"] = .array(outcomes.map { outcome in
                guard outcome.ok else { return ["ok": false, "error": .string(outcome.error ?? "error")] }
                var entry: [String: JSON] = ["ok": true]
                if let id = outcome.entityID { entry["Id"] = .string(id) }
                if let token = outcome.syncToken { entry["SyncToken"] = .string(token) }
                return .object(entry)
            })
        }
        return .object(summary)
    }
}

/// Keeps secrets out of log files.
public enum Redaction {
    private static let patterns: [NSRegularExpression] = [
        // key=value and "key": "value" forms of token-ish fields.
        #"(?i)((?:refresh_?token|access_?token|client_?secret|authorization)["']?\s*[:=]\s*["']?(?:Bearer\s+)?)[A-Za-z0-9._\-~+/=]{8,}"#,
        // Intuit refresh tokens (AB11…) and JWT-shaped access tokens.
        #"\bAB11[A-Za-z0-9]{20,}\b"#,
        #"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b"#,
        // Access keys issued by this app.
        #"\bqbo_[A-Za-z0-9]{20,}\b"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    public static func redact(_ text: String) -> String {
        var result = text
        for (index, regex) in patterns.enumerated() {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result, range: range, withTemplate: index == 0 ? "$1[redacted]" : "[redacted]")
        }
        return result
    }
}

/// Reading upstream tool results.
///
/// Intuit's tools mostly report failure as ordinary text beginning "Error:"
/// (or "Unknown error:") without setting MCP's `isError`, so success can't be
/// judged by the flag alone.
enum ToolResult {
    static func text(_ response: JSON) -> String {
        response["result"]?["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue }.joined(separator: "\n") ?? ""
    }

    static func isFailure(_ response: JSON) -> Bool {
        if response["error"] != nil || response["result"]?["isError"] == .bool(true) { return true }
        let start = text(response).prefix(40).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return start.hasPrefix("error") || start.hasPrefix("unknown error")
    }

    /// Intuit's rate limiting (HTTP 429, "ThrottleExceeded"). A throttled
    /// request was not processed, so retrying it is safe even for writes.
    static func isThrottled(_ response: JSON) -> Bool {
        guard isFailure(response) else { return false }
        let body = ((response["error"]?["message"]?.stringValue ?? "") + " " + text(response)).lowercased()
        return body.contains("throttl") || body.contains("too many requests")
            || body.range(of: #"\b429\b"#, options: .regularExpression) != nil
    }
}
