import PaseoKit
import SwiftUI

struct NewAgentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var workspaceId: String?
    @State private var providers: [ProviderAvailability] = []
    @State private var provider = ""
    @State private var models: [ProviderModel] = []
    @State private var modelId = ""
    @State private var modes: [AgentMode] = []
    @State private var modeId = ""
    @State private var thinkingId = ""
    @State private var prompt = ""
    @State private var isCreating = false
    @State private var error: String?

    private var workspaces: [Workspace] {
        model.projects.flatMap(\.workspaces)
    }

    private var selectedWorkspace: Workspace? {
        workspaceId.flatMap { model.workspaces[$0] }
    }

    private var selectedModel: ProviderModel? {
        models.first { $0.id == modelId }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Where") {
                    Picker("Workspace", selection: $workspaceId) {
                        Text("Choose…").tag(String?.none)
                        ForEach(model.projects) { project in
                            Section(project.name) {
                                ForEach(project.workspaces) { workspace in
                                    Text(workspace.displayName).tag(Optional(workspace.id))
                                }
                            }
                        }
                    }
                    if let workspace = selectedWorkspace {
                        Text((workspace.workspaceDirectory as NSString).abbreviatingWithTildeInPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Agent") {
                    Picker("Provider", selection: $provider) {
                        ForEach(providers.filter(\.available)) { Text($0.provider.capitalized).tag($0.provider) }
                    }
                    Picker("Model", selection: $modelId) {
                        Text("Default").tag("")
                        ForEach(models) { Text($0.label).tag($0.id) }
                    }
                    .disabled(models.isEmpty)
                    if let options = selectedModel?.thinkingOptions, !options.isEmpty {
                        Picker("Thinking", selection: $thinkingId) {
                            Text("Default").tag("")
                            ForEach(options) { Text($0.label).tag($0.id) }
                        }
                    }
                    if !modes.isEmpty {
                        Picker("Mode", selection: $modeId) {
                            Text("Default").tag("")
                            ForEach(modes) { Text($0.label).tag($0.id) }
                        }
                    }
                }

                Section("Prompt") {
                    TextField("What should the agent do?", text: $prompt, axis: .vertical)
                        .lineLimit(4...12)
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Agent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Create", action: create).disabled(!canCreate)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
        .task { await loadProviders() }
        .onChange(of: provider) { Task { await loadProviderDetails() } }
        .onChange(of: workspaceId) { Task { await loadProviderDetails() } }
        .onChange(of: modelId) { thinkingId = "" }
    }

    private var canCreate: Bool {
        selectedWorkspace != nil && !provider.isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadProviders() async {
        if workspaceId == nil {
            workspaceId = model.selectedAgent?.workspaceId.flatMap { model.workspaces[$0]?.id } ?? workspaces.first?.id
        }
        do {
            providers = try await model.providers()
            if provider.isEmpty {
                provider = model.selectedAgent?.provider ?? providers.first(where: \.available)?.provider ?? ""
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadProviderDetails() async {
        guard !provider.isEmpty else { return }
        let cwd = selectedWorkspace?.workspaceDirectory
        let requested = provider
        async let fetchedModels = model.models(provider: requested, cwd: cwd)
        async let fetchedModes = model.modes(provider: requested, cwd: cwd)
        do {
            let (newModels, newModes) = try await (fetchedModels, fetchedModes)
            guard requested == provider else { return }
            models = newModels
            modes = newModes
            if !models.contains(where: { $0.id == modelId }) { modelId = newModels.first(where: { $0.isDefault == true })?.id ?? "" }
            if !modes.contains(where: { $0.id == modeId }) { modeId = "" }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func create() {
        guard let workspace = selectedWorkspace else { return }
        isCreating = true
        error = nil
        let options = DaemonClient.CreateAgentOptions(
            provider: provider,
            cwd: workspace.workspaceDirectory,
            workspaceId: workspace.id,
            model: modelId.isEmpty ? nil : modelId,
            modeId: modeId.isEmpty ? nil : modeId,
            thinkingOptionId: thinkingId.isEmpty ? nil : thinkingId,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        Task {
            do {
                try await model.createAgent(options)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isCreating = false
        }
    }
}
