import Foundation
import Observation
import PaseoKit

/// Where a session writes daemon output. Implemented by the emulator view.
@MainActor
protocol TerminalOutputSink: AnyObject {
    /// Clears the emulator (RIS) and paints `data`; input the emulator generates meanwhile must be dropped.
    func restore(_ data: Data)
    func write(_ data: Data)
}

/// Drives one attached daemon terminal: output streaming, input, and PTY size ownership.
///
/// Size follows the daemon's last-interacting-client-wins rule: attaching and passive layout never send a
/// resize. Focus, clicks/taps and typing send a `claim` with the local grid size; later genuine grid
/// changes send an `update`, which the daemon ignores unless this connection still owns the size.
@MainActor @Observable
public final class TerminalSession {
    public enum Phase: Equatable {
        case idle
        case attaching
        case live
        case exited(String?)
        case failed(String)
    }

    public let terminalId: String
    public private(set) var phase: Phase = .idle
    /// Title set by the running program (OSC 0/2), if any.
    public private(set) var title: String?

    private let client: DaemonClient
    @ObservationIgnored private weak var sink: TerminalOutputSink?
    @ObservationIgnored private var attachment: TerminalAttachment?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var outbound: Task<Void, Never>?
    @ObservationIgnored private var gridSize: TerminalSize?
    @ObservationIgnored private var sentSize: TerminalSize?
    @ObservationIgnored private var hasClaimed = false
    @ObservationIgnored private var claimPending = false
    @ObservationIgnored private var lastClaim = ContinuousClock.now
    @ObservationIgnored private var restoring = false

    public init(client: DaemonClient, terminalId: String) {
        self.client = client
        self.terminalId = terminalId
    }

    // MARK: Lifecycle

    func connect(sink: TerminalOutputSink) {
        self.sink = sink
        guard phase == .idle else { return }
        attach()
    }

    /// Re-attaches after an exit or failure. The restore frame repaints the screen.
    public func reattach() {
        guard attachment == nil, phase != .attaching else { return }
        attach()
    }

    public func disconnect() {
        pump?.cancel()
        pump = nil
        if let attachment {
            self.attachment = nil
            let client = client
            Task { await client.detachTerminal(attachment) }
        }
        phase = .idle
    }

    private func attach() {
        phase = .attaching
        pump?.cancel()
        pump = Task { [weak self, client, terminalId] in
            let attachment: TerminalAttachment
            do {
                attachment = try await client.attachTerminal(terminalId)
            } catch {
                self?.phase = .failed(error.localizedDescription)
                return
            }
            guard let self, !Task.isCancelled else {
                await client.detachTerminal(attachment)
                return
            }
            self.attachment = attachment
            self.phase = .live
            if claimPending { claimSize() }
            for await event in attachment.events {
                switch event {
                case .restore(let data, _):
                    restoring = true
                    sink?.restore(data)
                    restoring = false
                case .output(let data):
                    sink?.write(data)
                }
            }
            guard !Task.isCancelled, self.attachment?.slot == attachment.slot else { return }
            self.attachment = nil
            switch await client.endReason(of: attachment) {
            case .exited(let error): phase = .exited(error)
            case .detached: phase = .idle
            case .disconnected: phase = .failed(PaseoError.disconnected.localizedDescription)
            }
        }
    }

    // MARK: Emulator callbacks

    /// Bytes the emulator produced from keyboard input, paste, or terminal query replies.
    func send(_ data: Data) {
        guard !restoring, !data.isEmpty, let attachment else { return }
        // Typing is direct interaction: re-claim if another client may have taken the size since.
        if ContinuousClock.now - lastClaim > .seconds(5) { claimSize() }
        enqueue { try await $0.sendTerminalInput(attachment, data: data) }
    }

    /// The user focused, clicked, or tapped the terminal.
    func userDidInteract() {
        claimSize()
    }

    /// The emulator's grid changed size (layout, window resize, keyboard inset, font change).
    func gridDidChange(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        let size = TerminalSize(rows: rows, cols: cols)
        guard size != gridSize else { return }
        gridSize = size
        if claimPending {
            claimSize()
        } else if hasClaimed, size != sentSize, let attachment {
            sentSize = size
            enqueue { try await $0.resizeTerminal(attachment, size: size, intent: .update) }
        }
    }

    func titleDidChange(_ title: String) {
        self.title = title.isEmpty ? nil : title
    }

    private func claimSize() {
        guard let size = gridSize, let attachment else {
            claimPending = true
            return
        }
        claimPending = false
        hasClaimed = true
        sentSize = size
        lastClaim = .now
        enqueue { try await $0.resizeTerminal(attachment, size: size, intent: .claim) }
    }

    /// Serializes outbound frames so input and resizes reach the daemon in order.
    private func enqueue(_ operation: @escaping @Sendable (DaemonClient) async throws -> Void) {
        let previous = outbound
        let client = client
        outbound = Task {
            await previous?.value
            try? await operation(client)
        }
    }
}
