import Foundation

/// Intuit's OAuth 2.0 authorization-code flow, for adding and reconnecting
/// companies by signing in.
///
/// Intuit only accepts HTTPS redirect URIs for production apps, so the
/// redirect goes to a static bounce page (`docs/callback/` in this repo,
/// served by GitHub Pages). The page reads the gateway's port from `state`
/// and forwards the browser to `http://127.0.0.1:<port>/oauth/callback`.
/// The code it carries is single-use and worthless without the client secret,
/// which never leaves this Mac.
public enum IntuitOAuth {
    public static let authorizeEndpoint = URL(string: "https://appcenter.intuit.com/connect/oauth2")!
    public static let tokenEndpoint = URL(string: "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer")!
    public static let scope = "com.intuit.quickbooks.accounting"
    public static let callbackPath = "/oauth/callback"

    public struct Tokens: Sendable {
        public var accessToken: String
        public var refreshToken: String
        public var refreshTokenExpiresIn: TimeInterval?
    }

    public struct OAuthError: Error, CustomStringConvertible {
        public let description: String
    }

    /// `state` is `<port>-<nonce>`: the bounce page needs the port, and the
    /// nonce ties the callback to the flow this app started.
    public static func makeState(port: UInt16) -> String {
        "\(port)-\(AccessKey.generateSecret().dropFirst(4))"
    }

    public static func authorizeURL(clientID: String, redirectURI: String, state: String) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    public static func exchange(
        code: String, keys: IntuitAppKeys, redirectURI: String, session: URLSession = .shared
    ) async throws -> Tokens {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        let basic = Data("\(keys.clientID):\(keys.clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formEncode([
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
        ])

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSON.parse(data)) ?? .null
        guard status == 200,
              let access = body["access_token"]?.stringValue,
              let refresh = body["refresh_token"]?.stringValue
        else {
            let reason = body["error_description"]?.stringValue ?? body["error"]?.stringValue ?? "HTTP \(status)"
            throw OAuthError(description: "Intuit refused the authorization code: \(reason)")
        }
        var expires: TimeInterval?
        if case .number(let seconds) = body["x_refresh_token_expires_in"] ?? .null { expires = seconds }
        return Tokens(accessToken: access, refreshToken: refresh, refreshTokenExpiresIn: expires)
    }

    public static func apiBase(_ environment: IntuitEnvironment) -> URL {
        switch environment {
        case .production: URL(string: "https://quickbooks.api.intuit.com")!
        case .sandbox: URL(string: "https://sandbox-quickbooks.api.intuit.com")!
        }
    }

    /// The company's display name, used to name and slug it. Uses the access
    /// token only, so it does not touch the refresh-token chain.
    public static func companyName(
        realmID: String, accessToken: String, environment: IntuitEnvironment, session: URLSession = .shared
    ) async throws -> String {
        let url = apiBase(environment)
            .appendingPathComponent("v3/company/\(realmID)/companyinfo/\(realmID)")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "minorversion", value: "75")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSON.parse(data)) ?? .null
        guard status == 200, let name = body["CompanyInfo"]?["CompanyName"]?.stringValue else {
            throw OAuthError(description: "Could not read the company's name (HTTP \(status)).")
        }
        return name
    }

    static func formEncode(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    /// The parts of a redirect the app needs, from either the local callback
    /// or a URL the user pasted.
    public struct Callback: Sendable, Equatable {
        public var code: String
        public var realmID: String
        public var state: String

        public init(code: String, realmID: String, state: String) {
            self.code = code
            self.realmID = realmID
            self.state = state
        }

        public init(query: [String: String]) throws {
            if let error = query["error"] {
                let detail = query["error_description"].map { ": \($0)" } ?? ""
                throw OAuthError(description: error == "access_denied"
                    ? "Authorization was cancelled in QuickBooks."
                    : "QuickBooks returned an error: \(error)\(detail)")
            }
            guard let code = query["code"], !code.isEmpty,
                  let realm = query["realmId"], !realm.isEmpty,
                  let state = query["state"], !state.isEmpty
            else {
                throw OAuthError(description: "That redirect is missing the code, realmId or state.")
            }
            self.init(code: code, realmID: realm, state: state)
        }

        /// Accepts the full address-bar URL from the bounce page or the local
        /// callback.
        public init(pastedURL: String) throws {
            let trimmed = pastedURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let components = URLComponents(string: trimmed) else {
                throw OAuthError(description: "That doesn't look like a URL.")
            }
            var query: [String: String] = [:]
            for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
            try self.init(query: query)
        }
    }
}
