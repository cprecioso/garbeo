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

@MainActor @Suite struct NewAgentChatTests {
    @Test func opensChatInSelectedWorkspaceWithoutCreatingAgent() async throws {
        let (model, daemon) = try await connectedModel()
        model.selection = .workspace("ws_feature")

        model.startNewAgent()

        #expect(model.selection == .newAgent)
        let chat = try #require(model.newAgent)
        #expect(chat.destination == .workspace("ws_feature"))
        #expect(chat.worktree.projectId == "proj_garbeo")
        #expect(chat.cwd(in: model) == "/tmp/garbeo-fake/worktrees/feature")
        #expect(await daemon.createdAgents.isEmpty)
    }

    @Test func defaultsToMostRecentWorkspace() async throws {
        let (model, _) = try await connectedModel()
        model.startNewAgent()
        #expect(model.newAgent?.destination == .workspace("ws_main"))
    }

    @Test func keepsOpenChatUnlessGivenWorkspace() async throws {
        let (model, _) = try await connectedModel()
        model.startNewAgent()
        let chat = try #require(model.newAgent)
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

    @Test func loadsSettingsFromDaemon() async throws {
        let (model, _) = try await connectedModel()
        model.startNewAgent()
        let chat = try #require(model.newAgent)

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
        let chat = try #require(model.newAgent)
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
        #expect(model.newAgent == nil)
    }

    @Test func incompleteChatDoesNotCreateAgent() async throws {
        let (model, daemon) = try await connectedModel()
        model.startNewAgent()
        let chat = try #require(model.newAgent)
        chat.agent.provider = "claude"

        chat.agent.prompt = "   "
        await chat.send(in: model)
        chat.agent.prompt = "Do it"
        chat.destination = nil
        #expect(!chat.isComplete(in: model))
        await chat.send(in: model)

        #expect(await daemon.createdAgents.isEmpty)
        #expect(model.selection == .newAgent)
    }

    @Test func failedCreationKeepsMessage() async throws {
        let (model, daemon) = try await connectedModel()
        await daemon.failAgentCreation("Provider unavailable")
        model.startNewAgent()
        let chat = try #require(model.newAgent)
        chat.agent.provider = "claude"
        chat.agent.prompt = "Fix the login bug"

        await chat.send(in: model)

        #expect(chat.error?.contains("Provider unavailable") == true)
        #expect(chat.agent.prompt == "Fix the login bug")
        #expect(!chat.isCreating)
        #expect(chat.sentMessage == nil)
        #expect(model.selection == .newAgent)
    }

    @Test func newWorktreeIsCreatedWithTheAgent() async throws {
        let (model, daemon) = try await connectedModel()
        model.startNewAgent()
        let chat = try #require(model.newAgent)
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
    }
}
