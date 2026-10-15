import Foundation
import Observation
import PaseoKit

/// A daemon the user has connected to or paired with. Only non-secret fields live here
/// (UserDefaults); the daemon password and the relay daemon public key go to the Keychain.
struct SavedHost: Codable, Identifiable, Hashable {
    /// `direct:<address>` or `relay:<serverId>`.
    var id: String
    var name: String
    var kind: TransportKind
    /// Direct: the address as typed. Relay: the relay `host:port`.
    var address: String
    var serverId: String?
    var relayUseTls: Bool?
    var lastUsed: Date

    var subtitle: String {
        switch kind {
        case .direct: address
        case .relay: "Relay · \(address)"
        }
    }
}

/// Persists paired hosts and which one is current.
@MainActor @Observable
final class HostStore {
    static let shared = HostStore()

    private static let hostsKey = "savedHosts"
    private static let currentKey = "currentHostId"
    private static let legacyEndpointKey = "endpointURL"
    private static let relayKeyService = "Garbeo.relay-daemon-key"

    private(set) var hosts: [SavedHost] = []
    private(set) var currentId: String?

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.hostsKey),
           let decoded = try? JSONDecoder().decode([SavedHost].self, from: data)
        {
            hosts = decoded
        }
        currentId = defaults.string(forKey: Self.currentKey)
        migrateLegacyEndpoint()
    }

    var sortedHosts: [SavedHost] { hosts.sorted { $0.lastUsed > $1.lastUsed } }

    // MARK: Endpoint mapping

    func endpoint(for host: SavedHost) -> DaemonEndpoint? {
        let password = Keychain.password(for: host.id)
        switch host.kind {
        case .direct:
            return DaemonEndpoint(url: host.address, password: password)
        case .relay:
            guard let serverId = host.serverId,
                  let key = Keychain.secret(service: Self.relayKeyService, account: host.id),
                  let connection = try? RelayConnection(
                      endpoint: host.address, useTls: host.relayUseTls ?? true, serverId: serverId, daemonPublicKeyB64: key)
            else { return nil }
            return .relay(connection, password: password)
        }
    }

    var currentEndpoint: DaemonEndpoint? {
        currentId.flatMap { id in hosts.first { $0.id == id } }.flatMap(endpoint(for:))
    }

    /// Records `endpoint` as the current host (or clears the current host for `nil`).
    func setCurrent(_ endpoint: DaemonEndpoint?) {
        guard let endpoint else {
            currentId = nil
            persist()
            return
        }
        guard var host = Self.makeHost(from: endpoint) else { return }
        if let existing = hosts.first(where: { $0.id == host.id }) { host.name = existing.name }
        hosts.removeAll { $0.id == host.id }
        hosts.append(host)
        currentId = host.id
        Keychain.setPassword(endpoint.password, for: host.id)
        if let relay = try? endpoint.relayConnection() {
            Keychain.setSecret(relay.daemonPublicKeyB64, service: Self.relayKeyService, account: host.id)
        }
        persist()
    }

    /// Names the current host after the daemon's hostname once connected.
    func updateCurrentName(_ name: String?) {
        guard let name, !name.isEmpty, let index = hosts.firstIndex(where: { $0.id == currentId }),
              hosts[index].name != name
        else { return }
        hosts[index].name = name
        persist()
    }

    func remove(_ host: SavedHost) {
        hosts.removeAll { $0.id == host.id }
        if currentId == host.id { currentId = nil }
        Keychain.setPassword(nil, for: host.id)
        Keychain.setSecret(nil, service: Self.relayKeyService, account: host.id)
        persist()
    }

    private static func makeHost(from endpoint: DaemonEndpoint) -> SavedHost? {
        switch endpoint.transportKind {
        case .direct:
            let address = endpoint.url.trimmingCharacters(in: .whitespacesAndNewlines)
            return SavedHost(id: "direct:\(address)", name: address, kind: .direct, address: address, lastUsed: Date())
        case .relay:
            guard let relay = try? endpoint.relayConnection() else { return nil }
            return SavedHost(
                id: "relay:\(relay.serverId)", name: relay.serverId, kind: .relay, address: relay.endpoint,
                serverId: relay.serverId, relayUseTls: relay.useTls, lastUsed: Date())
        }
    }

    private func persist() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(hosts) { defaults.set(data, forKey: Self.hostsKey) }
        defaults.set(currentId, forKey: Self.currentKey)
    }

    /// Earlier builds stored a single direct URL, with its password keyed by that URL.
    private func migrateLegacyEndpoint() {
        let defaults = UserDefaults.standard
        guard let url = defaults.string(forKey: Self.legacyEndpointKey) else { return }
        let password = Keychain.password(for: url)
        Keychain.setPassword(nil, for: url)
        defaults.removeObject(forKey: Self.legacyEndpointKey)
        setCurrent(DaemonEndpoint(url: url, password: password))
    }
}
