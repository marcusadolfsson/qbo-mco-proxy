import Foundation
import XCTest
@testable import QBOCore

final class HTTPParserTests: XCTestCase {
    func testContentLengthBody() throws {
        let raw = Data("POST /acme/mcp?x=1 HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhelloEXTRA".utf8)
        guard case .request(let request, let consumed) = HTTPParser.parse(raw) else { return XCTFail() }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/acme/mcp")
        XCTAssertEqual(request.query["x"], "1")
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "hello")
        XCTAssertEqual(consumed, raw.count - 5)
    }

    func testIncompleteUntilBodyArrives() {
        let head = "POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\n12345"
        XCTAssertEqual(HTTPParser.parse(Data(head.utf8)), .incomplete)
        XCTAssertEqual(HTTPParser.parse(Data("GET / HTTP/1.1\r\nHost:".utf8)), .incomplete)
    }

    func testChunkedBody() throws {
        let raw = Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5;x=y\r\npedia\r\n0\r\n\r\n".utf8)
        guard case .request(let request, let consumed) = HTTPParser.parse(raw) else { return XCTFail() }
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "Wikipedia")
        XCTAssertEqual(consumed, raw.count)
        XCTAssertEqual(HTTPParser.parse(raw.prefix(raw.count - 3)), .incomplete)
    }

    func testRejectsGarbage() {
        guard case .invalid(let status, _) = HTTPParser.parse(Data("NONSENSE\r\n\r\n".utf8)) else { return XCTFail() }
        XCTAssertEqual(status, 400)
    }

    func testPercentDecodedPathAndRepeatedHeaders() throws {
        let raw = Data("GET /a%20b/sse HTTP/1.1\r\nX: 1\r\nx: 2\r\n\r\n".utf8)
        guard case .request(let request, _) = HTTPParser.parse(raw) else { return XCTFail() }
        XCTAssertEqual(request.path, "/a b/sse")
        XCTAssertEqual(request.headers["x"], "1, 2")
    }
}

final class EnvFileTests: XCTestCase {
    func testReadUpdatePreservesOtherLines() {
        var env = EnvFile(text: "# comment\nQUICKBOOKS_CLIENT_ID=abc\nexport QUICKBOOKS_REALM_ID=\"123\"\nOTHER=x\n")
        XCTAssertEqual(env[QBOEnv.clientID], "abc")
        XCTAssertEqual(env[QBOEnv.realmID], "123")
        env[QBOEnv.refreshToken] = "new"
        env[QBOEnv.clientID] = "def"
        env["OTHER"] = nil
        XCTAssertEqual(env.text, "# comment\nQUICKBOOKS_CLIENT_ID=def\nexport QUICKBOOKS_REALM_ID=\"123\"\nQUICKBOOKS_REFRESH_TOKEN=new\n")
    }

    func testWriteIsOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(".env")
        try EnvFile(values: [("A", "1")]).write(to: url)
        try EnvFile(values: [("A", "2")]).write(to: url)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(try EnvFile.read(url)["A"], "2")
    }
}

final class SlugTests: XCTestCase {
    func testSuggestions() {
        XCTAssertEqual(Slug.suggest(from: "Aced Aviation, LLC", avoiding: []), "aced-aviation")
        XCTAssertEqual(Slug.suggest(from: "Phenom Pilots Inc.", avoiding: []), "phenom-pilots")
        XCTAssertEqual(Slug.suggest(from: "Café Ütö", avoiding: []), "cafe-uto")
        XCTAssertEqual(Slug.suggest(from: "Acme", avoiding: ["acme"]), "acme-2")
        XCTAssertEqual(Slug.suggest(from: "!!!", avoiding: []), "company")
        XCTAssertTrue(Slug.isValid("st-pete-aviators"))
        XCTAssertFalse(Slug.isValid("-x"))
        XCTAssertFalse(Slug.isValid("Upper"))
    }
}

final class RedactionTests: XCTestCase {
    func testRedactsTokens() {
        let line = #"refresh_token=AB11700000000abcdefghijklmnopqrstuv "client_secret": "s3cr3tvalue123" key qbo_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef"#
        let redacted = Redaction.redact(line)
        XCTAssertFalse(redacted.contains("AB117"))
        XCTAssertFalse(redacted.contains("s3cr3t"))
        XCTAssertFalse(redacted.contains("qbo_ABC"))
        XCTAssertTrue(redacted.contains("refresh_token=[redacted]"))
    }
}

final class AccessKeyTests: XCTestCase {
    func testFormatAndMatching() {
        let key = AccessKey(name: "MacBook")
        XCTAssertTrue(key.secret.hasPrefix("qbo_"))
        XCTAssertEqual(key.secret.count, 36)
        XCTAssertTrue(key.matches(key.secret))
        XCTAssertFalse(key.matches(key.secret + "x"))
        XCTAssertFalse(key.matches(String(key.secret.dropLast()) + "?"))
        XCTAssertNotEqual(AccessKey(name: "a").secret, AccessKey(name: "b").secret)
    }
}

final class OAuthTests: XCTestCase {
    func testAuthorizeURLAndState() throws {
        let state = IntuitOAuth.makeState(port: 8200)
        XCTAssertTrue(state.hasPrefix("8200-"))
        let url = IntuitOAuth.authorizeURL(clientID: "cid", redirectURI: GatewaySettings.defaultRedirectURI, state: state)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "redirect_uri" }?.value, GatewaySettings.defaultRedirectURI)
        XCTAssertEqual(items.first { $0.name == "scope" }?.value, "com.intuit.quickbooks.accounting")
        XCTAssertEqual(items.first { $0.name == "state" }?.value, state)
    }

    func testSavedOldRedirectMovesToTheRenamedRepo() throws {
        let paths = Paths(base: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.base) }
        try GatewaySettings(redirectURI: "https://marcusadolfsson.github.io/qbo-mco-proxy/callback/").save(paths)
        XCTAssertEqual(GatewaySettings.load(paths).redirectURI, GatewaySettings.defaultRedirectURI)
        try GatewaySettings(redirectURI: "https://example.com/mine/").save(paths)
        XCTAssertEqual(GatewaySettings.load(paths).redirectURI, "https://example.com/mine/", "custom addresses are kept")
    }

    func testPastedCallback() throws {
        let callback = try IntuitOAuth.Callback(
            pastedURL: " https://marcusadolfsson.github.io/qbo-mcp-proxy/callback/?code=AB&state=8200-x&realmId=9341 ")
        XCTAssertEqual(callback, IntuitOAuth.Callback(code: "AB", realmID: "9341", state: "8200-x"))
        XCTAssertThrowsError(try IntuitOAuth.Callback(pastedURL: "https://x/?error=access_denied&state=1"))
        XCTAssertThrowsError(try IntuitOAuth.Callback(pastedURL: "https://x/?code=1"))
    }
}

final class BatchTests: XCTestCase {
    func testPlanValidation() throws {
        XCTAssertThrowsError(try Batch.Plan(["calls": []]))
        XCTAssertThrowsError(try Batch.Plan(["calls": [["name": "batch", "arguments": [:]]]]))
        XCTAssertThrowsError(try Batch.Plan(["calls": .array(Array(repeating: ["name": "x"], count: 201))]))
        let plan = try Batch.Plan(["calls": [["name": "echo", "arguments": [:]]], "summary_only": false])
        XCTAssertFalse(plan.summaryOnly)
    }

    func testOutcomeTakesTheEntitysOwnId() {
        let response = RPC.toolText(id: 1, text: #"Bill updated: {"Id":"42","SyncToken":"3","Line":[{"Id":"1"}]}"#)
        let outcome = Batch.Outcome(response: response)
        XCTAssertTrue(outcome.ok)
        XCTAssertEqual(outcome.entityID, "42")
        XCTAssertEqual(outcome.syncToken, "3")
    }

    func testAddsToolOnlyWhenAbsent() {
        let plain = RPC.response(id: 1, result: ["tools": [["name": "x"]]])
        XCTAssertEqual(Batch.addingTool(to: plain)["result"]?["tools"]?.arrayValue?.count, 2)
        let has = RPC.response(id: 1, result: ["tools": [["name": "batch"]]])
        XCTAssertEqual(Batch.addingTool(to: has)["result"]?["tools"]?.arrayValue?.count, 1)
    }
}

final class QueryEscapingTests: XCTestCase {
    func testCountLiteralsCantBreakOutOfQuotes() throws {
        XCTAssertEqual(try CountQuery.literal("O'Brien"), "'O\\'Brien'")
        XCTAssertThrowsError(try CountQuery.literal("x\\' OR Id > '0"))
    }
}

final class NodeCheckTests: XCTestCase {
    func testVersionsAndThisMachine() {
        XCTAssertEqual(NodeCheck.major("v20.11.1"), 20)
        XCTAssertEqual(NodeCheck.major("v18.0.0"), 18)
        XCTAssertNil(NodeCheck.major("garbage"))
        XCTAssertTrue(NodeCheck.candidates(override: "/x/node").first == "/x/node", "an override is tried first")
        // The test suite itself needs Node, so this machine must pass.
        guard case .ok(_, let version) = NodeCheck.run(override: nil) else { return XCTFail("no usable node") }
        XCTAssertGreaterThanOrEqual(NodeCheck.major(version) ?? 0, NodeCheck.minimumMajor)
    }
}

final class ClientSnippetTests: XCTestCase {
    func testURLWithKeyIsAccepted() {
        let url = ClientSnippets.urlWithKey(host: "mac.local", port: 8200, slug: "acme", key: "qbo_Abc123")
        XCTAssertEqual(url, "http://mac.local:8200/acme/mcp?key=qbo_Abc123")
        let request = HTTPRequest(method: "POST", target: "/acme/mcp?key=qbo_Abc123")
        XCTAssertEqual(request.query["key"], "qbo_Abc123")
    }
}

final class JSONTests: XCTestCase {
    func testIntegralNumbersRoundTripWithoutFraction() throws {
        let value: JSON = ["id": 7, "x": .number(1.5), "s": "a/b"]
        let text = value.encodedString()
        XCTAssertTrue(text.contains("\"id\":7"))
        XCTAssertTrue(text.contains("1.5"))
        XCTAssertTrue(text.contains("a/b"))
        XCTAssertEqual(try JSON.parse(text), value)
    }
}
