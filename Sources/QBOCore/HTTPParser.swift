import Foundation

/// One parsed HTTP/1.1 request.
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    /// The raw request target, e.g. `/acme/message?sessionId=…`.
    public var target: String
    /// Header names lowercased. Repeated headers are joined with ", ".
    public var headers: [String: String]
    public var body: Data

    public init(method: String, target: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.target = target
        self.headers = headers
        self.body = body
    }

    /// The path without its query string, percent-decoded.
    public var path: String {
        let raw = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        return raw.removingPercentEncoding ?? raw
    }

    public var query: [String: String] {
        guard let components = URLComponents(string: "http://x\(target)") else { return [:] }
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] where result[item.name] == nil {
            result[item.name] = item.value ?? ""
        }
        return result
    }

    public var rawQuery: String? {
        let parts = target.split(separator: "?", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : nil
    }

    public var keepAlive: Bool {
        (headers["connection"]?.lowercased() ?? "") != "close"
    }
}

/// Incremental HTTP/1.1 request parser.
///
/// Pure and synchronous so it can be tested byte by byte: the connection feeds
/// whatever arrived, and the parser either needs more, yields a request plus
/// how many bytes it consumed, or rejects the input with a status to send.
public enum HTTPParser {
    public static let maxHeaderBytes = 64 * 1024
    /// Base64 of a 100 MB attachment (the upstream `create_attachable` limit)
    /// is about 134 MB, plus JSON framing.
    public static let maxBodyBytes = 150 * 1024 * 1024

    public enum Result: Equatable, Sendable {
        case incomplete
        case request(HTTPRequest, consumed: Int)
        case invalid(status: Int, reason: String)
    }

    private static let crlfcrlf = Data("\r\n\r\n".utf8)
    private static let crlf = Data("\r\n".utf8)

    /// The request line and headers, once they've fully arrived, so the
    /// server can decide how much body to accept before reading any of it.
    public static func head(_ buffer: Data) -> HTTPRequest? {
        guard case .head(let request, _) = parseHead(buffer) else { return nil }
        return request
    }

    private enum HeadResult {
        case incomplete
        case invalid(status: Int, reason: String)
        case head(HTTPRequest, bodyStart: Int)
    }

    private static func parseHead(_ buffer: Data) -> HeadResult {
        guard let headerEnd = buffer.range(of: crlfcrlf) else {
            return buffer.count > maxHeaderBytes
                ? .invalid(status: 431, reason: "headers too large") : .incomplete
        }
        guard headerEnd.lowerBound - buffer.startIndex <= maxHeaderBytes else {
            return .invalid(status: 431, reason: "headers too large")
        }
        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .invalid(status: 400, reason: "headers are not UTF-8")
        }
        var lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            return .invalid(status: 400, reason: "malformed request line")
        }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                return .invalid(status: 400, reason: "malformed header")
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        let request = HTTPRequest(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers)
        return .head(request, bodyStart: headerEnd.upperBound)
    }

    public static func parse(_ buffer: Data) -> Result {
        let parsed = parseHead(buffer)
        guard case .head(var request, let bodyStart) = parsed else {
            if case .invalid(let status, let reason) = parsed { return .invalid(status: status, reason: reason) }
            return .incomplete
        }
        let headers = request.headers

        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            switch decodeChunked(buffer, from: bodyStart) {
            case .incomplete: return .incomplete
            case .invalid(let reason): return .invalid(status: 400, reason: reason)
            case .done(let body, let end):
                request.body = body
                return .request(request, consumed: end - buffer.startIndex)
            }
        }

        let length: Int
        if let declared = headers["content-length"] {
            guard let value = Int(declared), value >= 0 else {
                return .invalid(status: 400, reason: "bad content-length")
            }
            length = value
        } else {
            length = 0
        }
        guard length <= maxBodyBytes else { return .invalid(status: 413, reason: "body too large") }
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }
        request.body = Data(buffer[bodyStart..<(bodyStart + length)])
        return .request(request, consumed: bodyStart + length - buffer.startIndex)
    }

    private enum ChunkResult {
        case incomplete
        case invalid(String)
        case done(Data, end: Int)
    }

    private static func decodeChunked(_ buffer: Data, from start: Int) -> ChunkResult {
        var body = Data()
        var cursor = start
        while true {
            guard let lineEnd = buffer.range(of: crlf, in: cursor..<buffer.endIndex) else {
                return .incomplete
            }
            let sizeText = String(decoding: buffer[cursor..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(sizeText, radix: 16), size >= 0 else {
                return .invalid("bad chunk size")
            }
            cursor = lineEnd.upperBound
            if size == 0 {
                // Skip optional trailers up to the terminating blank line.
                guard let end = buffer.range(of: crlf, in: cursor..<buffer.endIndex) else {
                    return .incomplete
                }
                if end.lowerBound == cursor { return .done(body, end: end.upperBound) }
                guard let trailerEnd = buffer.range(of: crlfcrlf, in: cursor..<buffer.endIndex) else {
                    return .incomplete
                }
                return .done(body, end: trailerEnd.upperBound)
            }
            guard body.count + size <= maxBodyBytes else { return .invalid("body too large") }
            guard buffer.endIndex - cursor >= size + 2 else { return .incomplete }
            body.append(buffer[cursor..<(cursor + size)])
            cursor += size + 2
        }
    }
}

/// A complete (non-streaming) HTTP response.
public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func text(_ status: Int, _ text: String) -> HTTPResponse {
        HTTPResponse(
            status: status, headers: [("Content-Type", "text/plain; charset=utf-8")],
            body: Data(text.utf8))
    }

    public static func json(_ status: Int, _ value: JSON, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(
            status: status, headers: [("Content-Type", "application/json")] + headers,
            body: value.encoded())
    }

    public static func html(_ status: Int, _ html: String) -> HTTPResponse {
        HTTPResponse(
            status: status, headers: [("Content-Type", "text/html; charset=utf-8")],
            body: Data(html.utf8))
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 413: "Payload Too Large"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }

    func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}
