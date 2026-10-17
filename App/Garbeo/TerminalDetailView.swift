import PaseoKit
import GarbeoTerminal
import SwiftUI

struct TerminalRow: View {
    @Environment(AppModel.self) private var model
    let terminal: TerminalInfo

    var body: some View {
        HStack(spacing: 8) {
            TerminalActivityIndicator(activity: terminal.activity)
            Text(terminal.displayName).lineLimit(1)
            Spacer(minLength: 4)
        }
        .contextMenu {
            Button("Kill Terminal", systemImage: "xmark.circle", role: .destructive) {
                Task { await model.terminals.kill(terminal) }
            }
        }
        #if os(iOS)
        .swipeActions {
            Button("Kill", systemImage: "xmark.circle", role: .destructive) {
                Task { await model.terminals.kill(terminal) }
            }
        }
        #endif
    }
}

private struct TerminalActivityIndicator: View {
    let activity: TerminalActivity?

    var body: some View {
        ZStack {
            Image(systemName: "apple.terminal").font(.caption).foregroundStyle(.secondary)
            if let badge {
                Circle().fill(badge).frame(width: 6, height: 6).offset(x: 6, y: -5)
            }
        }
        .frame(width: 16, height: 16)
    }

    private var badge: Color? {
        switch (activity?.attentionReason, activity?.state) {
        case ("needs_input", _), (_, "attention"): .orange
        case ("finished", _): .accentColor
        case (_, "working"): .green
        default: nil
        }
    }
}

/// A terminal: the reusable `GarbeoTerminalView` plus new/kill actions. `.window` (detail column)
/// puts them in the toolbar; `.pane` (a macOS workspace tab) draws a compact header instead.
struct TerminalDetailView: View {
    enum Chrome { case window, pane }

    @Environment(AppModel.self) private var model
    let terminal: TerminalInfo
    var chrome: Chrome = .window
    /// Becoming first responder claims the PTY size (last-interacting-client-wins), so panes only
    /// do it for the terminal the user just picked, not for every restored tab.
    var focusOnAppear = true
    @State private var confirmingKill = false

    var body: some View {
        content
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.Terminal.view)
            .confirmationDialog("Kill \(terminal.displayName)?", isPresented: $confirmingKill) {
                Button("Kill Terminal", role: .destructive) {
                    Task { await model.terminals.kill(terminal) }
                }
            } message: {
                Text("The shell and anything running in it will be stopped.")
            }
    }

    @ViewBuilder private var content: some View {
        switch chrome {
        case .window:
            emulator
                .navigationTitle(terminal.displayName)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if let workspace = workspace {
                            Button("New Terminal", systemImage: "plus") {
                                Task { await model.terminals.create(in: workspace) }
                            }
                        }
                        Button("Kill Terminal", systemImage: "xmark.circle", role: .destructive) {
                            confirmingKill = true
                        }
                    }
                }
        case .pane:
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "apple.terminal").foregroundStyle(.secondary)
                    Text(terminal.displayName).font(.headline).lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Kill Terminal", systemImage: "xmark.circle", role: .destructive) {
                        confirmingKill = true
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Kill Terminal")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
                emulator
            }
        }
    }

    @ViewBuilder private var emulator: some View {
        if let client = model.client {
            GarbeoTerminalView(client: client, terminalId: terminal.id, focusOnAppear: focusOnAppear)
                // A reconnect replaces the client; a fresh view re-attaches and restores the screen.
                .id(ObjectIdentifier(client))
        } else {
            ProgressView("Reconnecting…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var workspace: Workspace? {
        model.terminals.workspaceId(of: terminal).flatMap { model.workspaces[$0] }
    }
}
