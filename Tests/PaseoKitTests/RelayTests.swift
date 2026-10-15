import Foundation
import Testing
@testable import PaseoKit

// Known-answer vectors produced by Scripts/generate-relay-vectors.mjs from the upstream TypeScript
// relay (tweetnacl) and protocol packages.
private struct Vectors: Decodable {
    var daemonSecretKeyHex: String
    var daemonPublicKeyB64: String
    var clientSecretKeyHex: String
    var clientPublicKeyB64: String
    var sharedKeyHex: String
    var boxes: [Box]
    var channelBinaryCapable: Transcript
    var channelLegacy: Transcript
    var offer: ConnectionOffer
    var offerUrl: String
    var relayUri: String
    var relayUriParsed: ParsedURI
    var relayWebSocketUrls: [WebSocketURL]

    struct Plaintext: Decodable {
        var kind: String
        var text: String?
        var hex: String?

        var message: TransportMessage {
            kind == "text" ? .text(text!) : .binary(Data(hex: hex!))
        }
    }

    struct Box: Decodable {
        var kind: String
        var text: String?
        var hex: String?
        var nonceHex: String
        var bundleHex: String

        var plaintext: Data { kind == "text" ? Data(text!.utf8) : Data(hex: hex!) }
    }

    struct Frame: Decodable {
        var text: String?
        var binaryHex: String?

        var message: TransportMessage { text.map(TransportMessage.text) ?? .binary(Data(hex: binaryHex!)) }
    }

    struct Transcript: Decodable {
        var hello: String
        var frames: [Frame]
        var plaintexts: [Plaintext]
    }

    struct ParsedURI: Decodable {
        var offer: ConnectionOffer
        var password: String?
    }

    struct WebSocketURL: Decodable {
        var endpoint: String
        var useTls: Bool
        var serverId: String
        var url: String
    }

    static func load() throws -> Vectors {
        let url = try #require(Bundle.module.url(forResource: "relay-vectors", withExtension: "json", subdirectory: "Resources"))
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    func daemonKeyPair() throws -> RelayCrypto.KeyPair { try .init(secretKey: Data(hex: daemonSecretKeyHex)) }
    func clientKeyPair() throws -> RelayCrypto.KeyPair { try .init(secretKey: Data(hex: clientSecretKeyHex)) }
    func sharedKey() throws -> RelayCrypto.SharedKey {
        try .init(secretKey: Data(hex: clientSecretKeyHex), peerPublicKey: try daemonKeyPair().publicKey)
    }
}

extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

@Suite struct RelayCryptoTests {
    @Test func keyAgreementMatchesTweetnacl() throws {
        let v = try Vectors.load()
        #expect(try v.daemonKeyPair().publicKey.base64EncodedString() == v.daemonPublicKeyB64)
        #expect(try v.clientKeyPair().publicKey.base64EncodedString() == v.clientPublicKeyB64)
        #expect(try v.sharedKey().bytes.hex == v.sharedKeyHex)
        let daemonSide = try RelayCrypto.SharedKey(
            secretKey: Data(hex: v.daemonSecretKeyHex), peerPublicKey: RelayCrypto.importPublicKey(v.clientPublicKeyB64))
        #expect(daemonSide.bytes.hex == v.sharedKeyHex)
    }

    @Test func boxMatchesTweetnaclByteForByte() throws {
        let v = try Vectors.load()
        let key = try v.sharedKey()
        for box in v.boxes {
            #expect(key.seal(box.plaintext, nonce: Data(hex: box.nonceHex)).hex == box.bundleHex)
            #expect(try key.open(Data(hex: box.bundleHex)) == box.plaintext)
        }
    }

    @Test func randomNoncesRoundTrip() throws {
        let key = try Vectors.load().sharedKey()
        let a = key.seal(Data("hi".utf8))
        let b = key.seal(Data("hi".utf8))
        #expect(a != b)
        #expect(a.count == RelayCrypto.nonceLength + RelayCrypto.macLength + 2)
        #expect(try key.open(a) == Data("hi".utf8))
    }

    @Test func rejectsTamperingAndShortBundles() throws {
        let v = try Vectors.load()
        let key = try v.sharedKey()
        var tampered = Data(hex: v.boxes[1].bundleHex)
        tampered[tampered.count - 1] ^= 0x01
        #expect(throws: RelayCrypto.Failure.decryptionFailed) { try key.open(tampered) }
        #expect(throws: RelayCrypto.Failure.bundleTooShort) { try key.open(Data(count: 30)) }
    }

    @Test func validatesPublicKeys() throws {
        let v = try Vectors.load()
        #expect(throws: RelayCrypto.Failure.invalidPublicKey) { try RelayCrypto.importPublicKey("abc") }
        #expect(throws: RelayCrypto.Failure.invalidPublicKey) {
            try RelayCrypto.importPublicKey(v.daemonPublicKeyB64.replacingOccurrences(of: "=", with: ""))
        }
        #expect(throws: RelayCrypto.Failure.invalidPublicKey) {
            try RelayCrypto.importPublicKey(Data(count: 16).base64EncodedString())
        }
        // A low-order point yields an all-zero X25519 result and must be refused.
        #expect(throws: RelayCrypto.Failure.invalidPublicKey) {
            try RelayCrypto.SharedKey(secretKey: Data(hex: v.clientSecretKeyHex), peerPublicKey: Data(count: 32))
        }
    }
}

// MARK: - Channel

/// In-memory socket: records what the client sends and lets a script reply.
actor ScriptedSocket: DaemonTransport {
    private(set) var sent: [TransportMessage] = []
    private var inbox: [TransportMessage] = []
    private var waiters: [CheckedContinuation<TransportMessage, Error>] = []
    private(set) var closed = false
    private let reply: @Sendable (TransportMessage) -> [TransportMessage]

    init(reply: @escaping @Sendable (TransportMessage) -> [TransportMessage] = { _ in [] }) {
        self.reply = reply
    }

    func open() async throws {}

    func send(_ message: TransportMessage) async throws {
        guard !closed else { throw PaseoError.disconnected }
        sent.append(message)
        for response in reply(message) { deliver(response) }
    }

    func deliver(_ message: TransportMessage) {
        if waiters.isEmpty { inbox.append(message) } else { waiters.removeFirst().resume(returning: message) }
    }

    func receive() async throws -> TransportMessage {
        if !inbox.isEmpty { return inbox.removeFirst() }
        guard !closed else { throw PaseoError.disconnected }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    nonisolated func close() { Task { await markClosed() } }

    private func markClosed() {
        closed = true
        for waiter in waiters { waiter.resume(throwing: PaseoError.disconnected) }
        waiters.removeAll()
    }
}

@Suite struct RelayChannelTests {
    private func channel(_ transcript: Vectors.Transcript, _ v: Vectors) async throws -> (RelayE2EETransport, ScriptedSocket) {
        let ready = try #require(transcript.frames.first?.text)
        let socket = ScriptedSocket { message in
            if case .text(let text) = message, text.contains("e2ee_hello") { [.text(ready)] } else { [] }
        }
        let transport = try RelayE2EETransport(inner: socket, daemonPublicKeyB64: v.daemonPublicKeyB64, keyPair: v.clientKeyPair())
        try await transport.open()
        return (transport, socket)
    }

    @Test func helloMatchesUpstreamAndNegotiatesBinary() async throws {
        let v = try Vectors.load()
        let (transport, socket) = try await channel(v.channelBinaryCapable, v)
        #expect(await socket.sent.first == .text(v.channelBinaryCapable.hello))
        #expect(await transport.binaryCiphertext)
        for frame in v.channelBinaryCapable.frames.dropFirst() { await socket.deliver(frame.message) }
        for expected in v.channelBinaryCapable.plaintexts {
            #expect(try await transport.receive() == expected.message)
        }
    }

    @Test func legacyPeerUsesBase64ForEverything() async throws {
        let v = try Vectors.load()
        let (transport, socket) = try await channel(v.channelLegacy, v)
        #expect(await !transport.binaryCiphertext)
        for frame in v.channelLegacy.frames.dropFirst() { await socket.deliver(frame.message) }
        for expected in v.channelLegacy.plaintexts {
            #expect(try await transport.receive() == expected.message)
        }

        try await transport.send(.binary(Data([1, 2, 3])))
        guard case .text(let base64) = await socket.sent.last else { Issue.record("expected base64 text"); return }
        let daemonKey = try RelayCrypto.SharedKey(
            secretKey: Data(hex: v.daemonSecretKeyHex), peerPublicKey: RelayCrypto.importPublicKey(v.clientPublicKeyB64))
        #expect(try daemonKey.open(RelayCrypto.decodeCiphertextBase64(base64)) == Data([1, 2, 3]))
    }

    @Test func outboundFramesPreserveKind() async throws {
        let v = try Vectors.load()
        let (transport, socket) = try await channel(v.channelBinaryCapable, v)
        let daemonKey = try RelayCrypto.SharedKey(
            secretKey: Data(hex: v.daemonSecretKeyHex), peerPublicKey: RelayCrypto.importPublicKey(v.clientPublicKeyB64))

        try await transport.send(.text(#"{"type":"ping"}"#))
        guard case .text(let base64) = await socket.sent.last else { Issue.record("expected text frame"); return }
        #expect(try daemonKey.open(RelayCrypto.decodeCiphertextBase64(base64)) == Data(#"{"type":"ping"}"#.utf8))

        try await transport.send(.binary(Data([9, 8, 7])))
        guard case .binary(let bundle) = await socket.sent.last else { Issue.record("expected binary frame"); return }
        #expect(try daemonKey.open(bundle) == Data([9, 8, 7]))
    }

    @Test func skipsStrayHandshakeAndRejectsPlaintext() async throws {
        let v = try Vectors.load()
        let (transport, socket) = try await channel(v.channelBinaryCapable, v)
        await socket.deliver(.text(#"{"type":"e2ee_ready"}"#))
        await socket.deliver(v.channelBinaryCapable.frames[1].message)
        #expect(try await transport.receive() == v.channelBinaryCapable.plaintexts[0].message)

        await socket.deliver(.text(#"{"type":"session","message":{}}"#))
        await #expect(throws: RelayE2EETransport.Failure.plaintextOnEncryptedChannel) { try await transport.receive() }
    }

    @Test func closesOnUndecryptableFrame() async throws {
        let v = try Vectors.load()
        let (transport, socket) = try await channel(v.channelBinaryCapable, v)
        await socket.deliver(.binary(Data(count: 64)))
        await #expect(throws: RelayCrypto.Failure.decryptionFailed) { try await transport.receive() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await socket.closed)
    }

    @Test func retriesHelloUntilReady() async throws {
        let v = try Vectors.load()
        let socket = ScriptedSocket()
        let transport = try RelayE2EETransport(inner: socket, daemonPublicKeyB64: v.daemonPublicKeyB64, keyPair: v.clientKeyPair())
        let opening = Task { try await transport.open() }
        try await Task.sleep(for: .milliseconds(1300))
        #expect(await socket.sent.count == 2)
        await socket.deliver(.binary(Data(count: 10))) // ignored during the handshake
        await socket.deliver(.text(v.channelBinaryCapable.frames[0].text!))
        try await opening.value
        #expect(await transport.binaryCiphertext)
    }
}

// MARK: - Pairing

@Suite struct PairingTests {
    @Test func parsesOfferURL() throws {
        let v = try Vectors.load()
        let (connection, password) = try PairingLink.parse(v.offerUrl)
        #expect(password == nil)
        #expect(connection.serverId == v.offer.serverId)
        #expect(connection.daemonPublicKeyB64 == v.offer.daemonPublicKeyB64)
        #expect(connection.endpoint == "relay.paseo.sh:443")
        #expect(connection.useTls)
        #expect(PairingLink.isPairingLink(v.offerUrl))
        #expect(!PairingLink.isPairingLink("127.0.0.1:6767"))
    }

    @Test func relayURIRoundTripsWithUpstream() throws {
        let v = try Vectors.load()
        let (connection, password) = try PairingLink.parse(v.relayUri)
        #expect(password == v.relayUriParsed.password)
        #expect(try connection == RelayConnection(offer: v.relayUriParsed.offer))
        #expect(connection.connectionURI(password: password) == v.relayUri)

        let wrapped = "https://app.paseo.sh/#connect=" + v.relayUri.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        #expect(try PairingLink.parse(wrapped).connection == connection)
    }

    @Test func buildsRelayWebSocketURLsLikeUpstream() throws {
        let v = try Vectors.load()
        for entry in v.relayWebSocketUrls {
            let connection = try RelayConnection(
                endpoint: entry.endpoint, useTls: entry.useTls, serverId: entry.serverId,
                daemonPublicKeyB64: v.daemonPublicKeyB64)
            #expect(try connection.webSocketURL().absoluteString == entry.url)
        }
    }

    @Test func legacyOfferWithoutTlsFlagInfersFromPort() throws {
        let v = try Vectors.load()
        var offer = v.offer
        offer.relay.useTls = nil
        #expect(try RelayConnection(offer: offer).useTls)
        offer.relay.endpoint = "relay.example.com:8080"
        #expect(try !RelayConnection(offer: offer).useTls)
    }

    @Test func rejectsMalformedLinks() {
        #expect(throws: PairingError.self) { try PairingLink.parse("https://app.paseo.sh/") }
        #expect(throws: PairingError.self) { try PairingLink.parse("https://app.paseo.sh/#offer=") }
        #expect(throws: PairingError.self) { try PairingLink.parse("https://app.paseo.sh/#offer=bm90IGpzb24") }
        #expect(throws: PairingError.self) { try PairingLink.parse("relay://relay.paseo.sh/srv?key=abc") }
        #expect(throws: (any Error).self) { try PairingLink.parse("relay://relay.paseo.sh:443/srv?key=abc") }
    }

    @Test func endpointPicksTransport() throws {
        let v = try Vectors.load()
        let endpoint = try DaemonEndpoint.fromPairingLink(v.relayUri)
        #expect(endpoint.transportKind == .relay)
        #expect(endpoint.password == "p@ss word")
        #expect(!endpoint.url.contains("password"))
        #expect(try endpoint.relayConnection()?.serverId == "srv_test_123")
        #expect(DaemonEndpoint(url: "127.0.0.1:6767").transportKind == .direct)
        #expect(try DaemonEndpoint(url: v.offerUrl).relayConnection() != nil)
    }
}

// MARK: - DaemonClient over the encrypted channel

/// A fake daemon behind the relay: completes the E2EE handshake, then answers `hello` with
/// an encrypted `server_info` and echoes `ping` requests as `pong`.
private final class FakeRelayDaemon: @unchecked Sendable {
    private let lock = NSLock()
    private let daemon: RelayCrypto.KeyPair
    private var key: RelayCrypto.SharedKey?
    private(set) var decryptedFromClient: [String] = []

    init(daemon: RelayCrypto.KeyPair) { self.daemon = daemon }

    func handle(_ message: TransportMessage) -> [TransportMessage] {
        lock.lock()
        defer { lock.unlock() }
        guard case .text(let text) = message else { return [] }
        if let frame = HandshakeFrame.parse(text), frame.type == "e2ee_hello",
           let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
           let clientKey = (object["key"] as? String).flatMap({ try? RelayCrypto.importPublicKey($0) })
        {
            key = try? RelayCrypto.SharedKey(secretKey: daemon.secretKey, peerPublicKey: clientKey)
            return [.text(#"{"type":"e2ee_ready","capabilities":{"binaryCiphertext":true}}"#)]
        }
        guard let key, let plain = try? key.open(RelayCrypto.decodeCiphertextBase64(text)) else { return [] }
        let json = String(decoding: plain, as: UTF8.self)
        decryptedFromClient.append(json)
        func encrypted(_ reply: String) -> TransportMessage { .text(key.seal(Data(reply.utf8)).base64EncodedString()) }
        if json.contains(#""type":"hello""#) {
            return [encrypted("""
            {"type":"session","message":{"type":"status","payload":{"status":"server_info","protocolVersion":1,\
            "serverId":"srv_fake","hostname":"Relay Box","version":"0.11.1"}}}
            """)]
        }
        return []
    }
}

@Suite struct RelayDaemonClientTests {
    @Test func handshakeRunsInsideTheEncryptedChannel() async throws {
        let v = try Vectors.load()
        let daemon = FakeRelayDaemon(daemon: try v.daemonKeyPair())
        let socket = ScriptedSocket { daemon.handle($0) }
        let endpoint = try DaemonEndpoint.fromPairingLink(v.offerUrl, password: "secret")
        let relay = try #require(try endpoint.relayConnection())
        let client = DaemonClient(endpoint: endpoint, clientId: "cid_test") {
            try RelayE2EETransport(inner: socket, daemonPublicKeyB64: relay.daemonPublicKeyB64)
        }
        #expect(client.transportKind == .relay)
        let info = try await client.connect(timeout: .seconds(5))
        #expect(info.serverId == "srv_fake")
        #expect(info.hostname == "Relay Box")

        // Only the handshake travelled in plaintext; the password stayed inside the box.
        for case .text(let frame) in await socket.sent {
            #expect(!frame.contains("secret"))
            #expect(!frame.contains("cid_test"))
        }
        let hello = try #require(daemon.decryptedFromClient.first)
        #expect(hello.contains(#""password":"secret""#))
        #expect(hello.contains(#""clientId":"cid_test""#))
        await client.disconnect()
    }
}

/// Runs against a real daemon through the real relay when `PASEO_LIVE_PAIRING_URL` is set to the
/// output of `paseo daemon pair` (use an isolated daemon home, see README).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PASEO_LIVE_PAIRING_URL"] != nil))
struct LiveRelayTests {
    @Test(.timeLimit(.minutes(1))) func connectsThroughRelay() async throws {
        let env = ProcessInfo.processInfo.environment
        let endpoint = try DaemonEndpoint.fromPairingLink(env["PASEO_LIVE_PAIRING_URL"]!, password: env["PASEO_PASSWORD"])
        let client = DaemonClient(endpoint: endpoint, clientId: "garbeo-relay-tests")
        let info = try await client.connect()
        let relay = try #require(try endpoint.relayConnection())
        #expect(info.serverId == relay.serverId)
        let workspaces = try await client.fetchWorkspaces()
        let agents = try await client.fetchAgents()
        let providers = try await client.listProviders()
        print("live relay: server \(info.serverId) \(info.version ?? "?"), \(workspaces.entries.count) workspaces, \(agents.entries.count) agents, \(providers.count) providers")
        // Stay connected past one ping interval to exercise the encrypted liveness lease.
        try await Task.sleep(for: .seconds(12))
        _ = try await client.fetchAgents(subscribe: false)
        await client.disconnect()
    }
}
