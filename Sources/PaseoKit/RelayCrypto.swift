import Clibsodium
import Foundation

/// NaCl primitives used by the relay E2EE channel, byte-compatible with `packages/relay/src/crypto.ts`
/// (tweetnacl): Curve25519 key agreement (`box.before`) and XSalsa20-Poly1305 (`box.after`).
///
/// Bundle format: `[nonce (24)] [mac (16)] [ciphertext]`.
public enum RelayCrypto {
    public static let keyLength = 32
    public static let nonceLength = 24
    public static let macLength = 16

    public enum Failure: LocalizedError, Equatable, Sendable {
        case invalidPublicKey
        case invalidSecretKey
        case bundleTooShort
        case decryptionFailed
        case invalidBase64

        public var errorDescription: String? {
            switch self {
            case .invalidPublicKey: "Invalid daemon public key"
            case .invalidSecretKey: "Invalid secret key"
            case .bundleTooShort: "Ciphertext bundle too short"
            case .decryptionFailed: "Decryption failed"
            case .invalidBase64: "Invalid base64 ciphertext"
            }
        }
    }

    private static let initialized: Bool = sodium_init() >= 0

    private static func ensureInitialized() {
        precondition(initialized, "libsodium failed to initialize")
    }

    public struct KeyPair: Sendable {
        public let publicKey: Data
        public let secretKey: Data

        /// A fresh ephemeral keypair (the client side generates one per connection).
        public static func generate() -> KeyPair {
            ensureInitialized()
            var publicKey = [UInt8](repeating: 0, count: keyLength)
            var secretKey = [UInt8](repeating: 0, count: keyLength)
            crypto_box_keypair(&publicKey, &secretKey)
            return KeyPair(publicKey: Data(publicKey), secretKey: Data(secretKey))
        }

        /// Equivalent of `nacl.box.keyPair.fromSecretKey`.
        public init(secretKey: Data) throws {
            ensureInitialized()
            guard secretKey.count == keyLength else { throw Failure.invalidSecretKey }
            var publicKey = [UInt8](repeating: 0, count: keyLength)
            let secret = [UInt8](secretKey)
            crypto_scalarmult_base(&publicKey, secret)
            self.init(publicKey: Data(publicKey), secretKey: secretKey)
        }

        private init(publicKey: Data, secretKey: Data) {
            self.publicKey = publicKey
            self.secretKey = secretKey
        }
    }

    /// The precomputed `box.before` key shared by both peers.
    public struct SharedKey: Sendable, Equatable {
        public let bytes: Data

        /// Mirrors `deriveSharedKey`: rejects peer keys that yield an all-zero X25519 result.
        public init(secretKey: Data, peerPublicKey: Data) throws {
            ensureInitialized()
            guard secretKey.count == keyLength else { throw Failure.invalidSecretKey }
            guard peerPublicKey.count == keyLength else { throw Failure.invalidPublicKey }
            let secret = [UInt8](secretKey)
            let peer = [UInt8](peerPublicKey)
            var raw = [UInt8](repeating: 0, count: keyLength)
            // crypto_scalarmult returns -1 for an all-zero (low-order point) result.
            let status = crypto_scalarmult(&raw, secret, peer)
            sodium_memzero(&raw, raw.count)
            guard status == 0 else { throw Failure.invalidPublicKey }
            var key = [UInt8](repeating: 0, count: keyLength)
            guard crypto_box_beforenm(&key, peer, secret) == 0 else { throw Failure.invalidPublicKey }
            bytes = Data(key)
        }

        /// Encrypts `plaintext` into a `[nonce][mac][ciphertext]` bundle. `nonce` is random unless given.
        public func seal(_ plaintext: Data, nonce: Data? = nil) -> Data {
            let nonce = nonce.map([UInt8].init) ?? RelayCrypto.randomBytes(nonceLength)
            precondition(nonce.count == nonceLength, "nonce must be 24 bytes")
            let message = [UInt8](plaintext)
            let key = [UInt8](bytes)
            var output = [UInt8](repeating: 0, count: macLength + message.count)
            crypto_box_easy_afternm(&output, message, UInt64(message.count), nonce, key)
            return Data(nonce + output)
        }

        public func open(_ bundle: Data) throws -> Data {
            let bytes = [UInt8](bundle)
            guard bytes.count >= nonceLength + macLength else { throw Failure.bundleTooShort }
            let nonce = Array(bytes[..<nonceLength])
            let ciphertext = Array(bytes[nonceLength...])
            let key = [UInt8](self.bytes)
            var output = [UInt8](repeating: 0, count: ciphertext.count - macLength)
            guard crypto_box_open_easy_afternm(&output, ciphertext, UInt64(ciphertext.count), nonce, key) == 0 else {
                throw Failure.decryptionFailed
            }
            return Data(output)
        }
    }

    public static func randomBytes(_ count: Int) -> [UInt8] {
        ensureInitialized()
        var bytes = [UInt8](repeating: 0, count: count)
        randombytes_buf(&bytes, count)
        return bytes
    }

    /// Strict canonical base64 for a 32-byte public key, like `importPublicKey`.
    public static func importPublicKey(_ base64: String) throws -> Data {
        guard base64.count % 4 == 0,
              base64.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=") }),
              let data = Data(base64Encoded: base64),
              data.base64EncodedString() == base64,
              data.count == keyLength
        else { throw Failure.invalidPublicKey }
        return data
    }

    /// Lenient base64 used for ciphertext frames (`base64ToArrayBuffer`): trims, accepts URL-safe, pads.
    public static func decodeCiphertextBase64(_ text: String) throws -> Data {
        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let data = Data(base64Encoded: normalized) else { throw Failure.invalidBase64 }
        return data
    }
}
