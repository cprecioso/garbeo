import PaseoKit
import SwiftUI

extension WorkspaceSetupSnapshot {
    /// Whether to show this setup at all: a setup that finished without running anything isn't news.
    var isWorthShowing: Bool { status != .completed || !commands.isEmpty }

    var title: String {
        switch status {
        case .running: "Setting up workspace…"
        case .completed: "Setup finished"
        case .failed: "Setup failed"
        case .blocked: "Setup needs approval"
        case .other(let raw): "Setup \(raw)"
        }
    }

    var subtitle: String? {
        switch status {
        case .running: commands.last { $0.status == .running }?.command
        case .completed: commands.count == 1 ? "Ran 1 command" : "Ran \(commands.count) commands"
        case .failed: error ?? commands.last { $0.status == .failed }?.command
        case .blocked:
            blockedSource.map { "Pull request #\($0.number) is from \($0.headRepository ?? "a fork")" }
        case .other: error
        }
    }
}

struct SetupStatusIcon: View {
    let status: WorkspaceSetupSnapshot.Status

    var body: some View {
        switch status {
        case .running: ProgressView().controlSize(.small)
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .blocked: Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        case .other: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
    }
}

/// The setup's status icon, title and subtitle.
struct WorkspaceSetupSummary: View {
    let setup: WorkspaceSetupSnapshot

    var body: some View {
        HStack(spacing: 10) {
            SetupStatusIcon(status: setup.status).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(setup.title).font(.callout.weight(.medium))
                if let subtitle = setup.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

#if os(macOS)
/// A bar above a workspace's tabs while its setup is worth showing.
struct WorkspaceSetupBanner: View {
    @Environment(AppModel.self) private var model
    let workspace: Workspace
    @State private var showingDetails = false

    var body: some View {
        if let setup = model.setups[workspace.id], setup.isWorthShowing {
            HStack(spacing: 10) {
                WorkspaceSetupSummary(setup: setup)
                Spacer()
                Button("Details") { showingDetails = true }
                if setup.status != .running {
                    Button("Dismiss", systemImage: "xmark") { model.dismissSetupStatus(for: workspace.id) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .sheet(isPresented: $showingDetails) { WorkspaceSetupView(workspace: workspace) }
        }
    }
}
#endif

/// A workspace's setup commands and their output.
struct WorkspaceSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let workspace: Workspace
    /// Commands whose disclosure the user flipped; unfinished and failed ones start expanded.
    @State private var toggled: Set<Int> = []
    @State private var isApproving = false

    var body: some View {
        NavigationStack {
            Group {
                if let setup = model.setups[workspace.id] {
                    details(setup)
                } else {
                    ContentUnavailableView(
                        "No setup", systemImage: "wrench.and.screwdriver",
                        description: Text("This workspace's setup hasn't run since the daemon started."))
                }
            }
            .navigationTitle("Setup · \(workspace.displayName)")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 440)
        #endif
    }

    private func details(_ setup: WorkspaceSetupSnapshot) -> some View {
        Form {
            Section {
                WorkspaceSetupSummary(setup: setup)
                if let branch = setup.detail?.branchName, !branch.isEmpty {
                    LabeledContent("Branch", value: branch)
                }
                if let error = setup.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                if setup.status == .blocked {
                    Text("The setup scripts come from the pull request's code, so they only run once you approve it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button(isApproving ? "Starting…" : "Approve and Run Setup") {
                        isApproving = true
                        Task {
                            await model.runSetup(for: workspace.id)
                            isApproving = false
                        }
                    }
                    .disabled(isApproving)
                }
            }

            if setup.commands.isEmpty, let log = setup.detail?.log, !log.isEmpty {
                Section("Output") { SetupLog(text: log) }
            }

            ForEach(setup.commands) { command in
                Section {
                    DisclosureGroup(isExpanded: isExpanded(command)) {
                        if let log = command.log, !log.isEmpty {
                            SetupLog(text: log)
                        } else {
                            Text("No output").font(.caption).foregroundStyle(.tertiary)
                        }
                    } label: {
                        CommandLabel(command: command)
                    }
                }
            }

            if setup.detail?.truncated == true {
                Text("Earlier output was truncated.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func isExpanded(_ command: WorkspaceSetupSnapshot.Command) -> Binding<Bool> {
        let byDefault = command.status != .completed
        return Binding(
            get: { byDefault != toggled.contains(command.id) },
            set: { if $0 != byDefault { toggled.insert(command.id) } else { toggled.remove(command.id) } })
    }
}

private struct CommandLabel: View {
    let command: WorkspaceSetupSnapshot.Command

    var body: some View {
        HStack(spacing: 8) {
            SetupStatusIcon(status: command.status).frame(width: 18)
            Text(command.command).font(.callout.monospaced()).lineLimit(2)
            Spacer(minLength: 8)
            if command.status == .failed, let exitCode = command.exitCode {
                Text("exit \(exitCode)").font(.caption.monospaced()).foregroundStyle(.red)
            }
            if let ms = command.durationMs {
                Text(Duration.milliseconds(ms).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SetupLog: View {
    let text: String

    var body: some View {
        Text(Self.stripANSI(text).trimmingCharacters(in: .newlines))
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Drops terminal escape sequences (colors, cursor movement) from command output.
    private static func stripANSI(_ text: String) -> String {
        text.replacing(/\u{1B}\[[0-9;?]*[ -\/]*[@-~]/, with: "")
    }
}
