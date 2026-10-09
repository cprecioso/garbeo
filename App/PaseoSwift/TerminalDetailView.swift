import PaseoKit
import PaseoTerminal
import SwiftUI

struct TerminalRow: View {
    static let tagPrefix = "terminal:"

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

/// Detail column for a terminal: the reusable `PaseoTerminalView` plus new/kill actions.
struct TerminalDetailView: View {
    @Environment(AppModel.self) private var model
    let terminal: TerminalInfo
    @State private var confirmingKill = false

    var body: some View {
        Group {
            if let client = model.client {
                PaseoTerminalView(client: client, terminalId: terminal.id)
                    // A reconnect replaces the client; a fresh view re-attaches and restores the screen.
                    .id(ObjectIdentifier(client))
            } else {
                ProgressView("Reconnecting…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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
        .confirmationDialog("Kill \(terminal.displayName)?", isPresented: $confirmingKill) {
            Button("Kill Terminal", role: .destructive) {
                Task { await model.terminals.kill(terminal) }
            }
        } message: {
            Text("The shell and anything running in it will be stopped.")
        }
    }

    private var workspace: Workspace? {
        model.terminals.workspaceId(of: terminal).flatMap { model.workspaces[$0] }
    }
}
