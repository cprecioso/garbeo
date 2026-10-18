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
    /// The profile last applied, see `apply(_:)`.
    private var appliedProfile: AgentProfile?

    var selectedModel: ProviderModel? { models.first { $0.id == modelId } }

    /// The profile last applied, while the settings it sets are unchanged.
    var profile: AgentProfile? {
        guard let profile = appliedProfile, profile.provider == provider else { return nil }
        let unchanged = (profile.model.map { $0 == modelId } ?? true)
            && (profile.modeId.map { $0 == modeId } ?? true)
            && (profile.thinkingOptionId.map { $0 == thinkingId } ?? true)
        return unchanged ? profile : nil
    }

    /// Takes the provider, model, mode, thinking level and features of `profile`. What it leaves out
    /// goes back to the provider's default.
    func apply(_ profile: AgentProfile) {
        appliedProfile = profile
        provider = profile.provider
        modelId = profile.model ?? ""
        modeId = profile.modeId ?? ""
        thinkingId = profile.thinkingOptionId ?? ""
    }

    /// Stops showing the applied profile; the settings stay.
    func clearProfile() {
        appliedProfile = nil
    }

    /// Resets the thinking level when the selected model doesn't offer it. Kept while models load, so
    /// a profile's model and thinking level can be set together.
    func dropUnavailableThinking() {
        guard !thinkingId.isEmpty, let model = selectedModel else { return }
        if !(model.thinkingOptions ?? []).contains(where: { $0.id == thinkingId }) { thinkingId = "" }
    }

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
            dropUnavailableThinking()
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
            // A profile's features are for its provider; other settings may have changed since.
            featureValues: appliedProfile.flatMap { $0.provider == provider ? $0.featureValues : nil },
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
            if !model.agentProfiles.isEmpty {
                AgentProfilePicker(draft: draft, profiles: model.agentProfiles, noneLabel: "None")
            }
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
        .onChange(of: draft.modelId) { draft.dropUnavailableThinking() }

        Section("Prompt") {
            TextField("What should the agent do?", text: $draft.prompt, axis: .vertical)
                .lineLimit(4...12)
                .accessibilityIdentifier(AccessibilityID.AgentFields.prompt)
        }
    }
}

/// Applies one of the daemon's agent profiles to `draft`, and shows the one its settings still match.
struct AgentProfilePicker: View {
    let draft: AgentDraft
    let profiles: [AgentProfile]
    /// The entry for settings that match no profile.
    var noneLabel: String

    var body: some View {
        Picker("Profile", selection: selection) {
            Text(noneLabel).tag(String?.none)
            Divider()
            ForEach(profiles) { profile in
                Label {
                    Text(profile.name)
                } icon: {
                    Image(systemName: profile.symbolName).foregroundStyle(profile.tint ?? .secondary)
                }
                .tag(Optional(profile.id))
            }
        }
        .help(draft.profile?.notes ?? "Start the agent from a saved profile")
        .accessibilityIdentifier(AccessibilityID.NewAgent.profile)
    }

    private var selection: Binding<String?> {
        Binding {
            draft.profile?.id
        } set: { id in
            if let profile = profiles.first(where: { $0.id == id }) { draft.apply(profile) } else { draft.clearProfile() }
        }
    }
}

extension AgentProfile {
    /// The SF Symbol closest to the profile's icon (Paseo's `AGENT_PROFILE_ICON_KEYS`).
    var symbolName: String {
        switch icon {
        case "wrench": "wrench.adjustable"
        case "square_terminal": "apple.terminal"
        case "eye": "eye"
        case "pencil": "pencil"
        case "search": "magnifyingglass"
        case "bot": "cpu"
        case "sparkles": "sparkles"
        case "brain": "brain"
        case "mic_vocal": "music.mic"
        default: "circle.fill"
        }
    }

    /// The profile's identity color (Paseo's `AGENT_PROFILE_COLORS`), nil when unset or unknown.
    var tint: Color? {
        switch color {
        case "violet": .purple
        case "sky": .cyan
        case "emerald": .green
        case "orange": .orange
        case "pink": .pink
        case "indigo": .indigo
        case "teal": .teal
        case "red": .red
        case "amber": .yellow
        case "blue": .blue
        default: nil
        }
    }
}
