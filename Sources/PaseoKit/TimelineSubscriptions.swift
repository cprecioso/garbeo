import Foundation
import Observation

/// One agent's live timeline plus its loading state.
public struct LiveTimeline: Sendable {
    public internal(set) var timeline = AgentTimeline()
    public internal(set) var error: String?
    public internal(set) var isLoadingOlder = false
    /// The rows may have missed deltas (never fetched, unsubscribed for a while, or a sequence
    /// gap). Live deltas are dropped until a tail fetch re-establishes the timeline.
    public internal(set) var needsTail = true
    fileprivate var fetchToken: Int?
    fileprivate var lastShown = 0

    public init() {}
}

/// Per-agent live timelines for every agent on screen.
///
/// Views report what they show with `show`/`hide`, keyed by a viewer token so one agent can be
/// visible in several places at once. The union of shown agents is the set to pass to
/// `agent.timeline.set_subscription.request` (which replaces the daemon-side set on each call).
///
/// A timeline is trusted only after its tail was fetched while the daemon had acknowledged a
/// subscription covering it; before that, live deltas are dropped and the fetch fills the gap.
/// Timelines that are no longer shown stay cached (up to `cacheLimit`) so reopening one paints
/// immediately while its tail is refetched.
public struct TimelineRegistry: Sendable {
    public private(set) var timelines: [String: LiveTimeline] = [:]
    /// Agents the daemon has acknowledged streaming to this connection.
    public private(set) var subscribed: Set<String> = []
    private var viewers: [UUID: String] = [:]
    private var tick = 0
    private var nextFetchToken = 0
    public var cacheLimit = 12

    public init() {}

    public subscript(agentId: String) -> LiveTimeline? { timelines[agentId] }

    /// Sorted, de-duplicated IDs of every shown agent: the desired subscription set.
    public var visibleAgentIds: [String] { Set(viewers.values).sorted() }

    // MARK: Visibility

    public mutating func show(_ agentId: String, viewer: UUID) {
        viewers[viewer] = agentId
        tick += 1
        timelines[agentId, default: LiveTimeline()].lastShown = tick
    }

    public mutating func hide(viewer: UUID) {
        viewers[viewer] = nil
    }

    // MARK: Subscription

    /// The daemon acknowledged streaming exactly `agentIds`.
    public mutating func subscriptionAcknowledged(_ agentIds: [String]) {
        let now = Set(agentIds)
        for dropped in subscribed.subtracting(now) {
            timelines[dropped]?.needsTail = true
            timelines[dropped]?.fetchToken = nil
        }
        subscribed = now
        evictStale()
    }

    /// A new connection starts with no subscriptions, and in-flight fetches belong to the old one.
    public mutating func connectionReset() {
        subscribed = []
        for agentId in timelines.keys {
            timelines[agentId]?.needsTail = true
            timelines[agentId]?.fetchToken = nil
            timelines[agentId]?.isLoadingOlder = false
        }
    }

    // MARK: Tail fetches

    /// Visible, subscribed agents whose tail must be (re)fetched now, each with a token for
    /// `tailFetched`/`tailFailed`. Marks them as fetching so repeated calls don't duplicate work.
    /// Agents whose last fetch failed wait for `requestReload`.
    public mutating func takeTailFetches() -> [(agentId: String, token: Int)] {
        var fetches: [(agentId: String, token: Int)] = []
        for agentId in visibleAgentIds where subscribed.contains(agentId) {
            guard let live = timelines[agentId], live.needsTail, live.fetchToken == nil, live.error == nil
            else { continue }
            nextFetchToken += 1
            timelines[agentId]?.fetchToken = nextFetchToken
            fetches.append((agentId, nextFetchToken))
        }
        return fetches
    }

    public mutating func tailFetched(_ page: TimelinePage, agentId: String, token: Int) {
        guard timelines[agentId]?.fetchToken == token else { return }
        timelines[agentId]?.timeline.replace(with: page)
        timelines[agentId]?.needsTail = false
        timelines[agentId]?.fetchToken = nil
        timelines[agentId]?.error = nil
    }

    public mutating func tailFailed(agentId: String, token: Int, error: String) {
        guard timelines[agentId]?.fetchToken == token else { return }
        timelines[agentId]?.fetchToken = nil
        timelines[agentId]?.error = error
    }

    /// Forces a refetch of the tail (clears a previous fetch error).
    public mutating func requestReload(_ agentId: String) {
        timelines[agentId]?.needsTail = true
        timelines[agentId]?.error = nil
    }

    // MARK: Live stream

    /// Merges a live delta. Returns true when the timeline fell out of sync and needs a tail fetch.
    @discardableResult
    public mutating func apply(_ payload: AgentStreamPayload) -> Bool {
        guard subscribed.contains(payload.agentId), let live = timelines[payload.agentId], !live.needsTail
        else { return false }
        guard timelines[payload.agentId]?.timeline.apply(payload) == .gap else { return false }
        timelines[payload.agentId]?.needsTail = true
        return true
    }

    // MARK: Local edits

    public mutating func addPendingUserMessage(text: String, messageId: String, agentId: String) {
        timelines[agentId]?.timeline.addPendingUserMessage(text: text, messageId: messageId)
    }

    public mutating func removePendingUserMessage(messageId: String, agentId: String) {
        timelines[agentId]?.timeline.removePendingUserMessage(messageId: messageId)
    }

    /// Starts a "load earlier" page. Returns its cursor, or nil when nothing should be loaded.
    public mutating func beginLoadingOlder(_ agentId: String) -> TimelineCursor? {
        guard let live = timelines[agentId], live.timeline.hasOlder, !live.isLoadingOlder,
              let cursor = live.timeline.startCursor
        else { return nil }
        timelines[agentId]?.isLoadingOlder = true
        return cursor
    }

    public mutating func finishLoadingOlder(_ agentId: String, page: TimelinePage?) {
        timelines[agentId]?.isLoadingOlder = false
        if let page { timelines[agentId]?.timeline.prepend(olderPage: page) }
    }

    public mutating func removeAgent(_ agentId: String) {
        timelines[agentId] = nil
    }

    // MARK: Cache

    private mutating func evictStale() {
        let shown = Set(viewers.values)
        let stale = timelines
            .filter { !shown.contains($0.key) && !subscribed.contains($0.key) }
            .sorted { $0.value.lastShown > $1.value.lastShown }
        for (agentId, _) in stale.dropFirst(max(0, cacheLimit)) {
            timelines[agentId] = nil
        }
    }
}

/// Keeps the daemon's timeline subscription equal to `desired`.
///
/// `agent.timeline.set_subscription.request` replaces the whole set, so requests must not
/// overlap: a slow earlier request finishing last would leave the daemon on a stale set. Requests
/// are serialized and coalesced (only the latest desired set is sent once the in-flight one
/// returns), and every acknowledged set is reported so the caller can fetch newly covered tails.
@MainActor @Observable
public final class TimelineSubscriptionSync {
    public typealias Send = @MainActor ([String]) async throws -> Void

    /// The agent IDs the daemon should stream. Call `flush()` after changing it.
    public var desired: [String] = []
    /// The set the daemon acknowledged on the current connection.
    public private(set) var applied: [String] = []
    public private(set) var lastError: String?

    @ObservationIgnored private let send: Send
    @ObservationIgnored private let acknowledged: @MainActor ([String]) -> Void
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isRunning = false

    public init(send: @escaping Send, acknowledged: @escaping @MainActor ([String]) -> Void) {
        self.send = send
        self.acknowledged = acknowledged
    }

    /// The connection changed; the new socket starts with no timeline subscriptions.
    public func reset() {
        generation += 1
        applied = []
        lastError = nil
    }

    /// Sends `desired` until the daemon has acknowledged it. Returns immediately when another
    /// flush is already running (that one picks up the new desired set).
    public func flush() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        while desired != applied {
            let target = desired
            let requestGeneration = generation
            do {
                try await send(target)
            } catch {
                if requestGeneration != generation { continue }
                lastError = error.localizedDescription
                return
            }
            guard requestGeneration == generation else { continue }
            applied = target
            lastError = nil
            acknowledged(target)
        }
    }
}
