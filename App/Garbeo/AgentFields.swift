import PaseoKit
import SwiftUI

/// Agent settings being filled in for a new agent (a new agent chat, the New Workspace sheet).
@MainActor @Observable
final class AgentDraft {
    var providers: [ProviderAvailability] = []
    var provider = ""
    var models: [ProviderModel] = []
    var modelId = ""
    var modes: [AgentMode] = []
    var modeId = ""
    var thinkingId = ""
    var prompt = ""
    /// Why providers, models or modes didn't load.
    var error: String?

    var selectedModel: ProviderModel? { models.first { $0.id == modelId } }
    var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isComplete: Bool { !provider.isEmpty && !trimmedPrompt.isEmpty }

    func loadProviders(from model: AppModel) async {
        do {
            providers = try await model.providers()
            if provider.isEmpty {
                provider = model.selectedAgent?.provider ?? providers.first(where: \.available)?.provider ?? ""
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadDetails(from model: AppModel, cwd: String?) async {
        guard !provider.isEmpty else { return }
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

    func options(cwd: String, workspaceId: String?) -> DaemonClient.CreateAgentOptions {
        DaemonClient.CreateAgentOptions(
            provider: provider,
            cwd: cwd,
            workspaceId: workspaceId,
            model: modelId.isEmpty ? nil : modelId,
            modeId: modeId.isEmpty ? nil : modeId,
            thinkingOptionId: thinkingId.isEmpty ? nil : thinkingId,
            prompt: trimmedPrompt)
    }
}

/// The "Agent" and "Prompt" form sections for an `AgentDraft`.
struct AgentFields: View {
    @Environment(AppModel.self) private var model
    @Bindable var draft: AgentDraft
    /// Where models and modes are looked up.
    var cwd: String?

    var body: some View {
        Section("Agent") {
            Picker("Provider", selection: $draft.provider) {
                ForEach(draft.providers.filter(\.available)) { Text($0.provider.capitalized).tag($0.provider) }
            }
            Picker("Model", selection: $draft.modelId) {
                Text("Default").tag("")
                ForEach(draft.models) { Text($0.label).tag($0.id) }
            }
            .disabled(draft.models.isEmpty)
            if let options = draft.selectedModel?.thinkingOptions, !options.isEmpty {
                Picker("Thinking", selection: $draft.thinkingId) {
                    Text("Default").tag("")
                    ForEach(options) { Text($0.label).tag($0.id) }
                }
            }
            if !draft.modes.isEmpty {
                Picker("Mode", selection: $draft.modeId) {
                    Text("Default").tag("")
                    ForEach(draft.modes) { Text($0.label).tag($0.id) }
                }
            }
        }
        .task { await draft.loadProviders(from: model) }
        .task(id: [draft.provider, cwd]) { await draft.loadDetails(from: model, cwd: cwd) }
        .onChange(of: draft.modelId) { draft.thinkingId = "" }

        Section("Prompt") {
            TextField("What should the agent do?", text: $draft.prompt, axis: .vertical)
                .lineLimit(4...12)
                .accessibilityIdentifier(AccessibilityID.AgentFields.prompt)
        }
    }
}
