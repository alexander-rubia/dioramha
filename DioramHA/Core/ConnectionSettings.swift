import Foundation

enum ConnectionError: LocalizedError, Equatable {
    case invalidURL
    case remoteMustUseHTTPS
    case insecureLocalHost
    case missingToken
    case incompleteAccessToken

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The URL is not valid."
        case .remoteMustUseHTTPS: "The Cloudflare URL must start with https://."
        case .insecureLocalHost: "http:// is only allowed on the local network (.local or a private IP)."
        case .missingToken: "The access token is missing."
        case .incompleteAccessToken: "Cloudflare Access needs both the Client ID and the Client Secret."
        }
    }
}

/// Where and how to connect. Stored entirely in the Keychain, never in UserDefaults.
struct ConnectionSettings: Codable, Equatable, Sendable {
    /// Chosen by hand on purpose: falling back to local automatically would let someone
    /// block HTTPS on an untrusted network and make the app send the token unencrypted.
    enum Mode: String, Codable, CaseIterable, Sendable { case remote, local }

    var mode: Mode = .local
    var remoteURL = ""
    var localURL = "http://homeassistant.local:8123"
    var token = ""
    var accessClientID = ""
    var accessClientSecret = ""

    /// True if the active connection sends the token unencrypted.
    var isUnencrypted: Bool {
        mode == .local && localURL.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://")
    }

    func webSocketRequest() throws -> URLRequest {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConnectionError.missingToken }
        let base = mode == .remote ? try Self.validatedRemote(remoteURL) : try Self.validatedLocal(localURL)

        var request = URLRequest(url: try Self.webSocketURL(from: base), timeoutInterval: 15)
        if mode == .remote {
            let id = accessClientID.trimmingCharacters(in: .whitespacesAndNewlines)
            let secret = accessClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard id.isEmpty == secret.isEmpty else { throw ConnectionError.incompleteAccessToken }
            if !id.isEmpty {
                request.setValue(id, forHTTPHeaderField: "CF-Access-Client-Id")
                request.setValue(secret, forHTTPHeaderField: "CF-Access-Client-Secret")
            }
        }
        return request
    }

    static func validatedRemote(_ raw: String) throws -> URLComponents {
        let c = try components(raw)
        guard c.scheme == "https" else { throw ConnectionError.remoteMustUseHTTPS }
        return c
    }

    static func validatedLocal(_ raw: String) throws -> URLComponents {
        let c = try components(raw)
        switch c.scheme {
        case "https": return c
        case "http":
            guard isPrivateHost(c.host ?? "") else { throw ConnectionError.insecureLocalHost }
            return c
        default: throw ConnectionError.invalidURL
        }
    }

    static func isPrivateHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h.hasSuffix(".local") || (!h.isEmpty && !h.contains(".") && !h.contains(":")) { return true }
        let p = h.split(separator: ".").compactMap { UInt8($0) }
        guard p.count == 4, h.split(separator: ".").count == 4 else { return false }
        return p[0] == 10 || p[0] == 127
            || (p[0] == 192 && p[1] == 168)
            || (p[0] == 172 && (16...31).contains(p[1]))
            || (p[0] == 169 && p[1] == 254)
    }

    private static func components(_ raw: String) throws -> URLComponents {
        guard let c = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = c.host, !host.isEmpty else { throw ConnectionError.invalidURL }
        return c
    }

    private static func webSocketURL(from base: URLComponents) throws -> URL {
        var c = base
        c.scheme = base.scheme == "https" ? "wss" : "ws"
        let path = c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path
        c.path = path + "/api/websocket"
        c.query = nil
        c.fragment = nil
        guard let url = c.url else { throw ConnectionError.invalidURL }
        return url
    }
}
