import Foundation

/// Client side of the relay's end-to-end encrypted channel (`createClientChannel` in
/// `packages/relay/src/encrypted-channel.ts`), layered over a raw relay socket.
///
/// 1. Generates an ephemeral Curve25519 keypair and derives the `box.before` key with the daemon's
///    public key from the pairing offer.
/// 2. Sends plaintext `{"type":"e2ee_hello","key":…,"capabilities":{"binaryCiphertext":true}}`
///    every second until the daemon answers `{"type":"e2ee_ready",…}`.
/// 3. Afterwards every frame is a NaCl box bundle. With `binaryCiphertext` negotiated, application
///    text travels as a base64 text frame and application binary as a raw binary frame; otherwise
///    (legacy peers) both kinds travel as base64 text.
public actor RelayE2EETransport: DaemonTransport {
    public enum Failure: LocalizedError, Equatable {
        case plaintextOnEncryptedChannel
        case invalidUTF8
        case closed

        public var errorDescription: String? {
            switch self {
            case .plaintextOnEncryptedChannel: "Received plaintext frame on encrypted channel"
            case .invalidUTF8: "Decrypted text frame is not valid UTF-8"
            case .closed: "Encrypted channel closed"
            }
        }
    }

    static let handshakeRetry: Duration = .seconds(1)

    private let inner: any DaemonTransport
    private let keyPair: RelayCrypto.KeyPair
    private let sharedKey: RelayCrypto.SharedKey
    private var isOpen = false
    private var isClosed = false
    public private(set) var binaryCiphertext = false

    /// - Parameter keyPair: Override only in tests; connections use a fresh ephemeral keypair.
    public init(inner: any DaemonTransport, daemonPublicKeyB64: String, keyPair: RelayCrypto.KeyPair = .generate()) throws {
        let daemonPublicKey = try RelayCrypto.importPublicKey(daemonPublicKeyB64)
        self.inner = inner
        self.keyPair = keyPair
        sharedKey = try RelayCrypto.SharedKey(secretKey: keyPair.secretKey, peerPublicKey: daemonPublicKey)
    }

    nonisolated var helloText: String {
        let key = keyPair.publicKey.base64EncodedString()
        return #"{"type":"e2ee_hello","key":"\#(key)","capabilities":{"binaryCiphertext":true}}"#
    }

    public func open() async throws {
        try await inner.open()
        let inner = inner
        let hello = helloText
        try await inner.send(.text(hello))
        let retry = Task {
            while !Task.isCancelled {
                try await Task.sleep(for: Self.handshakeRetry)
                try await inner.send(.text(hello))
            }
        }
        defer { retry.cancel() }

        while true {
            // Binary and non-ready traffic is ignored until the handshake completes.
            guard case .text(let text) = try await inner.receive(),
                  let control = HandshakeFrame.parse(text), control.type == "e2ee_ready"
            else { continue }
            binaryCiphertext = control.capabilities?.binaryCiphertext == true
            isOpen = true
            return
        }
    }

    public func send(_ message: TransportMessage) async throws {
        guard isOpen, !isClosed else { throw Failure.closed }
        switch message {
        case .text(let text):
            try await inner.send(.text(sharedKey.seal(Data(text.utf8)).base64EncodedString()))
        case .binary(let data):
            let bundle = sharedKey.seal(data)
            // COMPAT(binaryCiphertext): peers that did not negotiate get base64 text frames.
            try await inner.send(binaryCiphertext ? .binary(bundle) : .text(bundle.base64EncodedString()))
        }
    }

    public func receive() async throws -> TransportMessage {
        guard isOpen, !isClosed else { throw Failure.closed }
        while true {
            let frame = try await inner.receive()
            do {
                if let message = try decode(frame) { return message }
            } catch {
                // Decryption or protocol errors are fatal so the client reconnects and re-handshakes.
                close()
                throw error
            }
        }
    }

    public nonisolated func close() {
        inner.close()
        Task { await markClosed() }
    }

    private func markClosed() { isClosed = true }

    /// Returns nil for stray handshake frames that should be skipped.
    func decode(_ frame: TransportMessage) throws -> TransportMessage? {
        if case .text(let text) = frame, text.drop(while: \.isWhitespace).first == "{" {
            if let control = HandshakeFrame.parse(text) {
                if control.type == "e2ee_hello" || control.type == "e2ee_ready" { return nil }
                throw Failure.plaintextOnEncryptedChannel
            }
            // Not JSON after all: fall through and treat it as ciphertext.
        }

        switch (frame, binaryCiphertext) {
        case (.binary(let bundle), true):
            return .binary(try sharedKey.open(bundle))
        case (.text(let text), true):
            let plaintext = try sharedKey.open(RelayCrypto.decodeCiphertextBase64(text))
            guard let string = String(data: plaintext, encoding: .utf8) else { throw Failure.invalidUTF8 }
            return .text(string)
        case (.text(let text), false):
            return Self.legacyPlaintext(try sharedKey.open(RelayCrypto.decodeCiphertextBase64(text)))
        case (.binary(let data), false):
            // Older adapters could lose the opcode; try base64 first, like upstream's legacy path.
            if let text = String(data: data, encoding: .utf8),
               let decoded = try? RelayCrypto.decodeCiphertextBase64(text),
               let plaintext = try? sharedKey.open(decoded)
            {
                return Self.legacyPlaintext(plaintext)
            }
            return Self.legacyPlaintext(try sharedKey.open(data))
        }
    }

    /// Without negotiation the frame kind is unknown: valid UTF-8 is text, anything else binary.
    private static func legacyPlaintext(_ data: Data) -> TransportMessage {
        if let text = String(data: data, encoding: .utf8) { return .text(text) }
        return .binary(data)
    }
}

/// Any plaintext JSON object frame; only `e2ee_hello` / `e2ee_ready` are legal after pairing.
struct HandshakeFrame: Decodable {
    var type: String?
    var capabilities: Capabilities?

    struct Capabilities: Decodable {
        var binaryCiphertext: Bool?
    }

    static func parse(_ text: String) -> HandshakeFrame? {
        try? JSONDecoder().decode(HandshakeFrame.self, from: Data(text.utf8))
    }
}
