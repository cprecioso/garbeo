import Foundation

/// Relay pairing offer (`ConnectionOfferV2Schema` in `packages/protocol/src/connection-offer.ts`).
public struct ConnectionOffer: Codable, Hashable, Sendable {
    public var v: Int
    public var serverId: String
    public var daemonPublicKeyB64: String
    public var relay: Relay

    public struct Relay: Codable, Hashable, Sendable {
        public var endpoint: String
        public var useTls: Bool?

        public init(endpoint: String, useTls: Bool? = nil) {
            self.endpoint = endpoint
            self.useTls = useTls
        }
    }

    public init(serverId: String, daemonPublicKeyB64: String, relay: Relay) {
        v = 2
        self.serverId = serverId
        self.daemonPublicKeyB64 = daemonPublicKeyB64
        self.relay = relay
    }
}

/// A resolved relay connection: everything needed to reach a daemon through the relay.
public struct RelayConnection: Hashable, Sendable {
    public static let defaultEndpoint = "relay.paseo.sh:443"

    /// Normalized `host:port` (IPv6 hosts bracketed).
    public var endpoint: String
    public var useTls: Bool
    public var serverId: String
    public var daemonPublicKeyB64: String

    public init(endpoint: String, useTls: Bool, serverId: String, daemonPublicKeyB64: String) throws {
        self.endpoint = try HostPort.normalize(endpoint)
        self.useTls = useTls
        self.serverId = serverId
        self.daemonPublicKeyB64 = daemonPublicKeyB64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverId.isEmpty else { throw PairingError.invalid("Missing server id") }
        _ = try RelayCrypto.importPublicKey(self.daemonPublicKeyB64)
    }

    public init(offer: ConnectionOffer) throws {
        guard offer.v == 2 else { throw PairingError.invalid("Unsupported offer version \(offer.v)") }
        // COMPAT(oldRelayOfferTls): offers without useTls meant TLS on port 443, like the official app.
        let useTls = offer.relay.useTls ?? ((try? HostPort.parse(offer.relay.endpoint).port) == 443)
        try self.init(endpoint: offer.relay.endpoint, useTls: useTls, serverId: offer.serverId,
                      daemonPublicKeyB64: offer.daemonPublicKeyB64)
    }

    /// `ws(s)://host:port/ws?serverId=…&role=client&v=2` (`buildRelayWebSocketUrl`).
    public func webSocketURL() throws -> URL {
        let (host, port, isIPv6) = try HostPort.parse(endpoint)
        let scheme = useTls ? "wss" : "ws"
        let hostPart = isIPv6 ? "[\(host)]" : host
        let defaultPort = useTls ? 443 : 80
        let authority = port == defaultPort ? hostPart : "\(hostPart):\(port)"
        let query = [("serverId", serverId), ("role", "client"), ("v", "2")]
            .map { "\($0)=\(formEncode($1))" }.joined(separator: "&")
        guard let url = URL(string: "\(scheme)://\(authority)/ws?\(query)") else { throw PairingError.invalid(endpoint) }
        return url
    }

    /// `relay://host:port/<serverId>?key=…[&ssl=true][&password=…]` (`serializeRelayConnectionUri`).
    public func connectionURI(password: String? = nil) -> String {
        let path = serverId.addingPercentEncoding(withAllowedCharacters: .encodeURIComponentAllowed) ?? serverId
        var query = [("key", daemonPublicKeyB64)]
        if useTls { query.append(("ssl", "true")) }
        if let password, !password.isEmpty { query.append(("password", password)) }
        return "relay://\(endpoint)/\(path)?" + query.map { "\($0)=\(formEncode($1))" }.joined(separator: "&")
    }
}

public enum PairingError: LocalizedError, Equatable, Sendable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let detail): "Invalid pairing link: \(detail)"
        }
    }
}

public enum PairingLink {
    /// True if `input` looks like a relay pairing link rather than a direct address.
    public static func isPairingLink(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("#offer=") || trimmed.contains("#connect=") || trimmed.lowercased().hasPrefix("relay://")
    }

    /// Parses any form the official app accepts:
    /// - `https://app.paseo.sh/#offer=<base64url JSON>` (QR code / `paseo daemon pair`)
    /// - `relay://host:port/<serverId>?key=…&ssl=true[&password=…]`
    /// - `…#connect=<percent-encoded relay URI>`
    public static func parse(_ input: String) throws -> (connection: RelayConnection, password: String?) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("relay://") || trimmed.contains("#connect=") {
            return try parseRelayURI(trimmed)
        }
        guard let range = trimmed.range(of: "#offer=") else { throw PairingError.invalid("Missing #offer= fragment") }
        let encoded = trimmed[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !encoded.isEmpty else { throw PairingError.invalid("Offer payload is empty") }
        return (try RelayConnection(offer: decodeOffer(encoded)), nil)
    }

    public static func decodeOffer(_ encoded: String) throws -> ConnectionOffer {
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { throw PairingError.invalid("Offer is not base64url") }
        do {
            let offer = try JSONDecoder().decode(ConnectionOffer.self, from: data)
            guard !offer.serverId.isEmpty, !offer.daemonPublicKeyB64.isEmpty, !offer.relay.endpoint.isEmpty else {
                throw PairingError.invalid("Offer is missing fields")
            }
            return offer
        } catch let error as PairingError {
            throw error
        } catch {
            throw PairingError.invalid("Offer is not a valid connection offer")
        }
    }

    static func parseRelayURI(_ input: String) throws -> (connection: RelayConnection, password: String?) {
        var uri = input
        if let range = input.range(of: "#connect=") {
            uri = String(input[range.upperBound...]).removingPercentEncoding ?? ""
        }
        guard let components = URLComponents(string: uri), components.scheme?.lowercased() == "relay",
              let host = components.percentEncodedHost, !host.isEmpty, let port = components.port,
              components.user == nil, components.password == nil
        else { throw PairingError.invalid("Invalid relay connection URI") }
        let items = formDecodedQuery(components.percentEncodedQuery)
        let serverId = String(components.percentEncodedPath.dropFirst()).removingPercentEncoding ?? ""
        guard !serverId.isEmpty, !serverId.contains("/"), let key = items["key"], !key.isEmpty else {
            throw PairingError.invalid("Relay connection URI requires a server id and key")
        }
        let password = items["password"].flatMap { $0.isEmpty ? nil : $0 }
        let hostPart = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let connection = try RelayConnection(
            endpoint: "\(hostPart):\(port)", useTls: items["ssl"] == "true", serverId: serverId, daemonPublicKeyB64: key)
        return (connection, password)
    }
}

// MARK: - Helpers

enum HostPort {
    /// Parses `host:port` or `[v6]:port` (`parseHostPort`).
    static func parse(_ input: String) throws -> (host: String, port: Int, isIPv6: Bool) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: Substring
        let portString: Substring
        let isIPv6 = trimmed.hasPrefix("[")
        if isIPv6 {
            guard let close = trimmed.firstIndex(of: "]"), trimmed[trimmed.index(after: close)...].hasPrefix(":") else {
                throw PairingError.invalid("Invalid host:port (expected [::1]:6767)")
            }
            host = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
            portString = trimmed[trimmed.index(close, offsetBy: 2)...]
        } else {
            guard let colon = trimmed.lastIndex(of: ":") else { throw PairingError.invalid("Invalid host:port \(trimmed)") }
            host = trimmed[..<colon]
            portString = trimmed[trimmed.index(after: colon)...]
        }
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty else { throw PairingError.invalid("Host is required") }
        guard portString.count <= 5, portString.allSatisfy(\.isASCII), let port = Int(portString), (1...65535).contains(port) else {
            throw PairingError.invalid("Port must be between 1 and 65535")
        }
        return (host.trimmingCharacters(in: .whitespaces), port, isIPv6)
    }

    static func normalize(_ input: String) throws -> String {
        let (host, port, isIPv6) = try parse(input)
        return isIPv6 ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

extension CharacterSet {
    /// Characters `encodeURIComponent` leaves alone.
    static let encodeURIComponentAllowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    /// `application/x-www-form-urlencoded` (URLSearchParams) unreserved set; space becomes `+`.
    static let formUnreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.*")
}

/// URLSearchParams serialization.
func formEncode(_ value: String) -> String {
    value.split(separator: " ", omittingEmptySubsequences: false)
        .map { $0.addingPercentEncoding(withAllowedCharacters: .formUnreserved) ?? String($0) }
        .joined(separator: "+")
}

/// URLSearchParams parsing (first value wins, like `searchParams.get`).
func formDecodedQuery(_ query: String?) -> [String: String] {
    var result: [String: String] = [:]
    for pair in (query ?? "").split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let decode = { (s: Substring) in s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(s) }
        let key = decode(parts[0])
        if result[key] == nil { result[key] = parts.count > 1 ? decode(parts[1]) : "" }
    }
    return result
}
