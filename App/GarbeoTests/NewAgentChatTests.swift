import Foundation
import PaseoKit
import Testing
@testable import Garbeo

/// An app model connected to a fresh `FakeDaemon`.
@MainActor
private func connectedModel() async throws -> (AppModel, FakeDaemon) {
    let daemon = FakeDaemon()
    let model = AppModel()
    model.transportFactory = { daemon }
    await model.connect(to: DaemonEndpoint(url: "fake.invalid:6767"))
    try #require(model.connection.isConnected)
    return (model, daemon)
}

/// The chat `startNewAgent` just opened: a workspace tab on macOS, the detail elsewhere.
@MainActor
private func openedChat(_ model: AppModel) throws -> NewAgentChat {
    #if os(macOS)
    let tab = try #require(model.newAgentTabRequest)
    return try #require(model.newAgentTabs[tab.chatId])
    #else
    return try #require(model.newAgent)
    #endif
}

/// Whether `chat` is still on screen.
@MainActor
private func isOpen(_ chat: NewAgentChat, in model: AppModel) -> Bool {
    #if os(macOS)
    model.newAgentTabs[chat.id] === chat
    #else
    model.selection == .newAgent && model.newAgent === chat
    #endif
}

/// Waits for `condition`, which the app model meets once a daemon message is handled.
@MainActor
private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

@MainActor @Suite struct NewAgentChatTests {
    @Test func opensChatInSelectedWorkspaceWithoutCreatingAgent() async throws {
        let (model, daemon) = try await connectedModel()
        model.selection = .workspace("ws_feature")

        model.startNewAgent()

        let chat = try openedChat(model)
        #expect(isOpen(chat, in: model))
        #expect(chat.destination == .workspace("ws_feature"))
        #expect(chat.worktree.projectId == "proj_garbeo")
        #expect(chat.cwd(in: model) == "/tmp/garbeo-fake/worktrees/feature")
        #expect(await daemon.createdAgents.isEmpty)
    }

    @Test func defaultsToMostRecentWorkspace() async throws {
        let (model, _) = try await connectedModel()
        model.startNewAgent()
        #expect(try openedChat(model).destination == .workspace("ws_main"))
    }

    #if os(macOS)
    @Test func opensAsTabOfItsWorkspace() async throws {
        let (model, _) = try await connectedModel()
        model.selection = .workspace("ws_main")
        let feature = try #require(model.workspaces["ws_feature"])

        model.startNewAgent(in: feature)

        let tab = try #require(model.newAgentTabRequest)
        #expect(tab.workspaceId == "ws_feature")
        #expect(model.selection == .workspace("ws_feature"))
        #expect(model.newAgent == nil)
    }

    @Test func eachNewAgentOpensAnotherTab() async throws {
        let (model, _) = try await connectedModel()
        model.selection = .workspace("ws_main")
        model.startNewAgent()
        let first = try openedChat(model)
        model.startNewAgent()
        let second = try openedChat(model)

        #expect(first !== second)
        #expect(isOpen(first, in: model) && isOpen(second, in: model))
    }

    @Test func closingTabDropsChat() async throws {
        let (model, _) = try await connectedModel()
        model.startNewAgent()
        let chat = try openedChat(model)
        let tab = NewAgentTab(chatId: chat.id, workspaceId: "ws_main")
        #expect(tab.label(in: model) != nil)

        var closed = false
        await tab.close(in: model) { closed = true }

        #expect(closed)
        #expect(!isOpen(chat, in: model))
        #expect(tab.label(in: model) == nil, "The tab closes, and a restored layout drops it")
    }

    @Test func discardingWrittenMessageAsksFirst() async throws {
        let (model, _) = try await connectedModel()
        model.startNewAgent()
        let chat = try openedChat(model)
        let tab = NewAgentTab(chatId: chat.id, workspaceId: "ws_main")
        #expect(tab.closeConfirmation(in: model) == nil)
        chat.agent.prompt = "Half-written"
        #expect(tab.closeConfirmation(in: model) != nil)
    }
    #else
    @Test func keepsOpenChatUnlessGivenWorkspace() async throws {
        let (model, _) = try await connectedModel()
        model.startNewAgent()
        let chat = try openedChat(model)
        chat.agent.prompt = "Half-written"

        model.startNewAgent()
        #expect(model.newAgent === chat)
        #expect(chat.agent.prompt == "Half-written")

        let feature = try #require(model.workspaces["ws_feature"])
        model.startNewAgent(in: feature)
        #expect(model.newAgent !== chat)
        #expect(model.newAgent?.destination == .workspace("ws_feature"))
    }

    @Test func leavingDropsChat() async throws {
        let (model, _) = try await connectedModel()
        model.startNewAgent()
        model.selection = .workspace("ws_main")
        #expect(model.newAgent == nil)
    }
    #endif

    @Test func loadsSettingsFromDaemon() async throws {
        let (model, _) = try await connectedModel()
        model.startNewAgent()
        let chat = try openedChat(model)

        await chat.agent.loadProviders(from: model)
        #expect(chat.agent.provider == "claude")
        await chat.agent.loadDetails(from: model, cwd: chat.cwd(in: model))
        #expect(chat.agent.models.map(\.id) == ["haiku-fake", "opus-fake"])
        #expect(chat.agent.modelId == "haiku-fake")
        #expect(chat.agent.modes.map(\.id) == ["default", "plan"])
    }

    @Test func firstMessageCreatesAgentWithChosenSettings() async throws {
        let (model, daemon) = try await connectedModel()
        model.startNewAgent()
        let chat = try openedChat(model)
        chat.agent.provider = "claude"
        chat.agent.modelId = "opus-fake"
        chat.agent.thinkingId = "high"
        chat.agent.modeId = "plan"
        chat.agent.prompt = "  Fix the login bug\n"
        #expect(chat.isComplete(in: model))

        await chat.send(in: model)

        let created = await daemon.createdAgents
        #expect(created.count == 1)
        #expect(created.first?["initialPrompt"] == "Fix the login bug")
        #expect(created.first?["workspaceId"] == "ws_main")
        #expect(created.first?["config"] == [
            "provider": "claude", "cwd": .string(FakeDaemon.projectRoot), "model": "opus-fake",
            "thinkingOptionId": "high", "modeId": "plan",
        ])
        #expect(model.selection == .agent("agent_1"))
        #expect(model.agents["agent_1"]?.title == "Fix the login bug")
        #expect(!isOpen(chat, in: model))
    }

    @Test func incompleteChatDoesNotCreateAgent() async throws {
        let (model, daemon) = try await connectedModel()
        model.startNewAgent()
        let chat = try openedChat(model)
        chat.agent.provider = "claude"

        chat.agent.prompt = "   "
        await chat.send(in: model)
        chat.agent.prompt = "Do it"
        chat.destination = nil
        #expect(!chat.isComplete(in: model))
        await chat.send(in: model)

        #expect(await daemon.createdAgents.isEmpty)
        #expect(isOpen(chat, in: model))
    }

    @Test func failedCreationKeepsMessage() async throws {
        let (model, daemon) = try await connectedModel()
        await daemon.failAgentCreation("Provider unavailable")
        model.startNewAgent()
        let chat = try openedChat(model)
        chat.agent.provider = "claude"
        chat.agent.prompt = "Fix the login bug"

        await chat.send(in: model)

        #expect(chat.error?.contains("Provider unavailable") == true)
        #expect(chat.agent.prompt == "Fix the login bug")
        #expect(!chat.isCreating)
        #expect(chat.sentMessage == nil)
        #expect(isOpen(chat, in: model))
    }

    @Test func newWorktreeIsCreatedWithTheAgent() async throws {
        let (model, daemon) = try await connectedModel()
        model.startNewAgent()
        let chat = try openedChat(model)
        chat.destination = .newWorktree
        chat.worktree.slug = "login-fix"
        chat.agent.provider = "claude"
        chat.agent.prompt = "Fix the login bug"

        await chat.send(in: model)

        let worktrees = await daemon.createdWorktrees
        #expect(worktrees.count == 1)
        #expect(worktrees.first?["cwd"] == .string(FakeDaemon.projectRoot))
        #expect(worktrees.first?["firstAgentContext"] == ["prompt": "Fix the login bug"])
        let agents = await daemon.createdAgents
        #expect(agents.first?["workspaceId"] == "ws_login-fix")
        #expect(agents.first?["config"]?["cwd"] == "/tmp/garbeo-fake/worktrees/login-fix")
        #expect(model.selection == .agent("agent_1"))
        #expect(!isOpen(chat, in: model))
    }

    @Test func loadsAgentProfilesAndFollowsChanges() async throws {
        let (model, daemon) = try await connectedModel()
        try await eventually { !model.agentProfiles.isEmpty }
        #expect(model.agentProfiles.map(\.id) == ["profile_deep", "profile_fast"])

        await daemon.setAgentProfiles([["id": "profile_new", "name": "New", "provider": "claude"]])

        try await eventually { model.agentProfiles.map(\.id) == ["profile_new"] }
    }

    @Test func profileSetsAgentSettings() async throws {
        let (model, daemon) = try await connectedModel()
        try await eventually { !model.agentProfiles.isEmpty }
        model.startNewAgent()
        let chat = try openedChat(model)
        await chat.agent.loadProviders(from: model)
        let deep = try #require(model.agentProfiles.first)

        chat.agent.apply(deep)
        await chat.agent.loadDetails(from: model, cwd: chat.cwd(in: model))
        chat.agent.dropUnavailableThinking()
        #expect(chat.agent.profile == deep)
        #expect(chat.agent.modelId == "opus-fake")
        #expect(chat.agent.thinkingId == "high")
        #expect(chat.agent.modeId == "plan")

        chat.agent.prompt = "Fix the login bug"
        await chat.send(in: model)

        #expect(await daemon.createdAgents.first?["config"] == [
            "provider": "claude", "cwd": .string(FakeDaemon.projectRoot), "model": "opus-fake",
            "thinkingOptionId": "high", "modeId": "plan",
        ])
    }

    @Test func changingASettingLeavesTheProfile() async throws {
        let (model, _) = try await connectedModel()
        try await eventually { !model.agentProfiles.isEmpty }
        let draft = AgentDraft()
        draft.apply(model.agentProfiles[0])
        await draft.loadDetails(from: model, cwd: FakeDaemon.projectRoot)

        draft.modeId = "default"

        #expect(draft.profile == nil)
        #expect(draft.modelId == "opus-fake")
    }

    @Test func profileFeaturesGoWithItsProvider() async throws {
        let (model, daemon) = try await connectedModel()
        try await eventually { !model.agentProfiles.isEmpty }
        model.startNewAgent()
        let chat = try openedChat(model)
        let fast = try #require(model.agentProfiles.last)

        chat.agent.apply(fast)
        await chat.agent.loadDetails(from: model, cwd: chat.cwd(in: model))
        #expect(chat.agent.profile == fast)
        #expect(chat.agent.modelId == "gpt-fake")
        chat.agent.prompt = "Quick fix"
        await chat.send(in: model)
        #expect(await daemon.createdAgents.last?["config"]?["featureValues"] == ["fast_mode": true])

        chat.agent.provider = "claude"
        chat.agent.prompt = "Another"
        await chat.send(in: model)
        #expect(await daemon.createdAgents.last?["config"]?["featureValues"] == nil)
    }
}
