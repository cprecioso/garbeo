import Foundation
import Testing
@testable import PaseoKit

private func delta(_ agentId: String, _ seq: Int, _ text: String = "x") throws -> AgentStreamPayload {
    try JSONDecoder().decode(AgentStreamPayload.self, from: Data("""
    {"agentId":"\(agentId)","event":{"type":"timeline","provider":"claude","item":{"type":"reasoning","text":"\(text)"}},
     "timestamp":"2026-10-09T09:31:54.474Z","seq":\(seq),"epoch":"e1"}
    """.utf8))
}

private func tail(_ agentId: String, endSeq: Int) throws -> TimelinePage {
    try JSONDecoder().decode(TimelinePage.self, from: Data("""
    {"requestId":"r","agentId":"\(agentId)","epoch":"e1",
     "entries":[{"item":{"type":"user_message","text":"hi"},"seqStart":\(endSeq),"seqEnd":\(endSeq)}],
     "startCursor":{"epoch":"e1","seq":\(endSeq)},"endCursor":{"epoch":"e1","seq":\(endSeq)},
     "hasOlder":true,"hasNewer":false,"error":null}
    """.utf8))
}

@Suite struct TimelineRegistryTests {
    @Test func visibleSetIsSortedUnionOfViewers() {
        var registry = TimelineRegistry()
        let left = UUID(), right = UUID(), third = UUID()
        registry.show("b", viewer: left)
        registry.show("a", viewer: right)
        registry.show("b", viewer: third)
        #expect(registry.visibleAgentIds == ["a", "b"])
        registry.hide(viewer: left)
        #expect(registry.visibleAgentIds == ["a", "b"], "b is still shown by another viewer")
        registry.hide(viewer: third)
        #expect(registry.visibleAgentIds == ["a"])
        // A viewer switching agents replaces its entry.
        registry.show("c", viewer: right)
        #expect(registry.visibleAgentIds == ["c"])
    }

    @Test func fetchesTailOnlyOnceSubscribed() throws {
        var registry = TimelineRegistry()
        registry.show("a", viewer: UUID())
        #expect(registry.takeTailFetches().isEmpty, "no fetch before the daemon acknowledges the subscription")
        // Deltas before the tail are dropped; the fetch covers them.
        #expect(registry.apply(try delta("a", 4)) == false)

        registry.subscriptionAcknowledged(["a"])
        let fetches = registry.takeTailFetches()
        #expect(fetches.map(\.agentId) == ["a"])
        #expect(registry.takeTailFetches().isEmpty, "already fetching")

        registry.tailFetched(try tail("a", endSeq: 5), agentId: "a", token: fetches[0].token)
        #expect(registry["a"]?.needsTail == false)
        #expect(registry["a"]?.timeline.rows.count == 1)
        #expect(registry.apply(try delta("a", 6)) == false)
        #expect(registry["a"]?.timeline.rows.count == 2)
    }

    @Test func gapMarksTimelineForRefetch() throws {
        var registry = TimelineRegistry()
        registry.show("a", viewer: UUID())
        registry.subscriptionAcknowledged(["a"])
        let token = try #require(registry.takeTailFetches().first?.token)
        registry.tailFetched(try tail("a", endSeq: 5), agentId: "a", token: token)

        #expect(registry.apply(try delta("a", 9)) == true)
        #expect(registry["a"]?.needsTail == true)
        #expect(registry.apply(try delta("a", 10)) == false, "dropped until refetched")
        #expect(registry.takeTailFetches().map(\.agentId) == ["a"])
    }

    @Test func unsubscribedTimelinesGoStaleButStayCached() throws {
        var registry = TimelineRegistry()
        let viewer = UUID()
        registry.show("a", viewer: viewer)
        registry.subscriptionAcknowledged(["a"])
        let token = try #require(registry.takeTailFetches().first?.token)
        registry.tailFetched(try tail("a", endSeq: 5), agentId: "a", token: token)

        // Hidden but still subscribed: keeps applying deltas, no refetch needed when shown again.
        registry.hide(viewer: viewer)
        #expect(registry.apply(try delta("a", 6)) == false)
        registry.show("a", viewer: viewer)
        #expect(registry.takeTailFetches().isEmpty)

        // Dropped from the subscription: rows stay for an instant repaint, but need a new tail.
        registry.hide(viewer: viewer)
        registry.subscriptionAcknowledged([])
        #expect(registry["a"]?.timeline.rows.count == 2)
        #expect(registry["a"]?.needsTail == true)
        registry.show("a", viewer: viewer)
        registry.subscriptionAcknowledged(["a"])
        #expect(registry.takeTailFetches().map(\.agentId) == ["a"])
    }

    @Test func evictsLeastRecentlyShownStaleTimelines() {
        var registry = TimelineRegistry()
        registry.cacheLimit = 1
        let viewer = UUID()
        for agentId in ["a", "b", "c"] { registry.show(agentId, viewer: viewer) }
        registry.hide(viewer: viewer)
        registry.subscriptionAcknowledged([])
        #expect(Set(registry.timelines.keys) == ["c"])
    }

    @Test func connectionResetInvalidatesInFlightFetches() throws {
        var registry = TimelineRegistry()
        registry.show("a", viewer: UUID())
        registry.subscriptionAcknowledged(["a"])
        let stale = try #require(registry.takeTailFetches().first?.token)

        registry.connectionReset()
        #expect(registry.subscribed.isEmpty)
        registry.tailFetched(try tail("a", endSeq: 5), agentId: "a", token: stale)
        #expect(registry["a"]?.needsTail == true, "a response from the old connection is ignored")

        registry.subscriptionAcknowledged(["a"])
        #expect(registry.takeTailFetches().count == 1)
    }

    @Test func failedFetchWaitsForExplicitReload() throws {
        var registry = TimelineRegistry()
        registry.show("a", viewer: UUID())
        registry.subscriptionAcknowledged(["a"])
        let token = try #require(registry.takeTailFetches().first?.token)
        registry.tailFailed(agentId: "a", token: token, error: "boom")
        #expect(registry["a"]?.error == "boom")
        #expect(registry.takeTailFetches().isEmpty)
        registry.requestReload("a")
        #expect(registry.takeTailFetches().count == 1)
    }

    @Test func loadOlderIsSingleFlight() throws {
        var registry = TimelineRegistry()
        registry.show("a", viewer: UUID())
        registry.subscriptionAcknowledged(["a"])
        let token = try #require(registry.takeTailFetches().first?.token)
        registry.tailFetched(try tail("a", endSeq: 5), agentId: "a", token: token)
        #expect(registry.beginLoadingOlder("a")?.seq == 5)
        #expect(registry.beginLoadingOlder("a") == nil)
        registry.finishLoadingOlder("a", page: nil)
        #expect(registry["a"]?.isLoadingOlder == false)
    }
}

/// Records `set_subscription` requests; optionally holds each one until released.
@MainActor
private final class FakeDaemon {
    var sent: [[String]] = []
    var acknowledged: [[String]] = []
    var hold = false
    var failNext = false
    private var gates: [CheckedContinuation<Void, Never>] = []

    func send(_ agentIds: [String]) async throws {
        sent.append(agentIds)
        if hold { await withCheckedContinuation { gates.append($0) } }
        if failNext {
            failNext = false
            throw PaseoError.disconnected
        }
    }

    func releaseOne() { gates.removeFirst().resume() }

    func waitForRequests(_ count: Int) async {
        while sent.count < count { await Task.yield() }
    }
}

@MainActor @Suite struct TimelineSubscriptionSyncTests {
    private func makeSync(_ daemon: FakeDaemon) -> TimelineSubscriptionSync {
        TimelineSubscriptionSync(
            send: { try await daemon.send($0) },
            acknowledged: { daemon.acknowledged.append($0) })
    }

    @Test func sendsFullSetAndSkipsNoOps() async {
        let daemon = FakeDaemon()
        let sync = makeSync(daemon)
        sync.desired = ["a", "b"]
        await sync.flush()
        await sync.flush()
        #expect(daemon.sent == [["a", "b"]])
        #expect(daemon.acknowledged == [["a", "b"]])
        sync.desired = []
        await sync.flush()
        #expect(daemon.sent == [["a", "b"], []], "an empty set clears the subscription")
    }

    @Test func coalescesChangesWhileARequestIsInFlight() async {
        let daemon = FakeDaemon()
        daemon.hold = true
        let sync = makeSync(daemon)
        sync.desired = ["a"]
        let first = Task { await sync.flush() }
        await daemon.waitForRequests(1)

        sync.desired = ["a", "b"]
        await sync.flush()  // returns at once; the running flush picks it up
        sync.desired = ["a", "c"]
        await sync.flush()
        daemon.hold = false
        daemon.releaseOne()
        await first.value

        #expect(daemon.sent == [["a"], ["a", "c"]], "intermediate sets are never sent")
        #expect(daemon.acknowledged == [["a"], ["a", "c"]])
        #expect(sync.applied == ["a", "c"])
    }

    @Test func resetResendsOnTheNewConnection() async {
        let daemon = FakeDaemon()
        daemon.hold = true
        let sync = makeSync(daemon)
        sync.desired = ["a"]
        let first = Task { await sync.flush() }
        await daemon.waitForRequests(1)

        sync.reset()  // the socket dropped while the request was in flight
        daemon.hold = false
        daemon.releaseOne()
        await first.value

        #expect(daemon.sent == [["a"], ["a"]], "the acknowledgement from the old socket doesn't count")
        #expect(daemon.acknowledged == [["a"]])
    }

    @Test func failureStopsUntilNextFlush() async {
        let daemon = FakeDaemon()
        daemon.failNext = true
        let sync = makeSync(daemon)
        sync.desired = ["a"]
        await sync.flush()
        #expect(sync.lastError != nil)
        #expect(daemon.acknowledged.isEmpty)
        await sync.flush()
        #expect(sync.lastError == nil)
        #expect(daemon.acknowledged == [["a"]])
    }
}
