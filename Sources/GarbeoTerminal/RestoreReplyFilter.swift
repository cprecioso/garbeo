import Foundation

/// Drops the bytes an emulator generates in response to restore output (query replies and the like),
/// so repainting a screen never types into the shell.
///
/// SwiftTerm delivers replies asynchronously, in order. After feeding a restore, the session feeds
/// `barrierQuery` (DSR 5); everything up to its `barrierReply` came from the restore.
struct RestoreReplyFilter {
    static let barrierQuery = Data("\u{1b}[5n".utf8)
    static let barrierReply = Data("\u{1b}[0n".utf8)

    private(set) var isSuppressing = false

    mutating func beginRestore() {
        isSuppressing = true
    }

    /// Lifts suppression without seeing the barrier, in case the emulator never answers it.
    mutating func timeOut() {
        isSuppressing = false
    }

    /// Returns the bytes to forward to the daemon, or nil to drop them.
    mutating func filter(_ data: Data) -> Data? {
        guard isSuppressing else { return data }
        guard let range = data.range(of: Self.barrierReply) else { return nil }
        isSuppressing = false
        let rest = data[range.upperBound...]
        return rest.isEmpty ? nil : Data(rest)
    }
}
