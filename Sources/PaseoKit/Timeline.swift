import Foundation

public struct TimelineRow: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case user(text: String, messageId: String?, pending: Bool)
        case assistant(text: String, messageId: String?)
        case reasoning(text: String)
        case tool(ToolCall)
        case todo([TaskItem])
        case error(String)
        case notification(level: String, message: String)
        case compaction(status: String)
    }

    public var id: String
    public var kind: Kind
    public var timestamp: Date?

    public init(id: String, kind: Kind, timestamp: Date?) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
    }
}

/// Client-side projection of an agent's timeline.
///
/// Mirrors the daemon's sync model (docs/timeline-sync.md): fetched pages are authoritative
/// projected items; live `agent_stream` events are deltas merged into the tail. Any sequence
/// discontinuity is reported so the caller can re-establish the tail from the daemon.
public struct AgentTimeline: Sendable {
    public private(set) var rows: [TimelineRow] = []
    public private(set) var epoch: String?
    public private(set) var lastSeq: Int?
    public private(set) var startCursor: TimelineCursor?
    public private(set) var hasOlder = false
    public private(set) var isLoaded = false
    private var nextLocalId = 0

    public enum ApplyResult: Equatable, Sendable {
        case applied
        case ignored
        /// The stream skipped sequence numbers or changed epoch; refetch the tail.
        case gap
    }

    public init() {}

    // MARK: Authoritative pages

    public mutating func replace(with page: TimelinePage) {
        let pendingUsers = rows.filter { if case .user(_, _, true) = $0.kind { true } else { false } }
        rows = page.entries.compactMap(Self.row(from:))
        epoch = page.endCursor?.epoch ?? page.epoch
        lastSeq = page.endCursor?.seq
        startCursor = page.startCursor
        hasOlder = page.hasOlder ?? false
        isLoaded = true
        // Keep optimistic submissions that the daemon has not echoed yet.
        let echoed = rows.compactMap { row -> (String, String?)? in
            if case .user(let text, let messageId, _) = row.kind { (text, messageId) } else { nil }
        }
        for pending in pendingUsers {
            guard case .user(let text, let messageId, _) = pending.kind else { continue }
            let delivered = echoed.contains { $0.1 != nil ? $0.1 == messageId : $0.0 == text }
            if !delivered { rows.append(pending) }
        }
    }

    public mutating func prepend(olderPage page: TimelinePage) {
        guard page.epoch == nil || page.epoch == epoch || epoch == nil else { return }
        let existing = Set(rows.map(\.id))
        let older = page.entries.compactMap(Self.row(from:)).filter { !existing.contains($0.id) }
        rows.insert(contentsOf: older, at: 0)
        startCursor = page.startCursor
        hasOlder = page.hasOlder ?? false
    }

    // MARK: Live stream

    public mutating func apply(_ payload: AgentStreamPayload) -> ApplyResult {
        guard case .timeline(let item, _) = payload.event else { return .ignored }
        if let seq = payload.seq {
            if let epoch, let incoming = payload.epoch, incoming != epoch { return .gap }
            if let lastSeq {
                if seq <= lastSeq { return .ignored }
                if seq > lastSeq + 1 { return .gap }
            } else if !isLoaded {
                // No authoritative tail yet; the pending fetch will cover this event.
                return .ignored
            }
            lastSeq = seq
            if epoch == nil { epoch = payload.epoch }
        }
        append(item, timestamp: PaseoDate.parse(payload.timestamp), seq: payload.seq)
        return .applied
    }

    /// Inserts an optimistic user message that is confirmed when the daemon echoes it.
    public mutating func addPendingUserMessage(text: String, messageId: String) {
        rows.append(TimelineRow(
            id: "local-\(messageId)", kind: .user(text: text, messageId: messageId, pending: true), timestamp: Date()))
    }

    public mutating func removePendingUserMessage(messageId: String) {
        rows.removeAll { $0.id == "local-\(messageId)" }
    }

    // MARK: Merging

    private mutating func append(_ item: TimelineItem, timestamp: Date?, seq: Int?) {
        let id = seq.map { "seq-\($0)" } ?? nextId()
        switch item {
        case .assistantMessage(let text, let messageId):
            if let index = rows.indices.last, case .assistant(let existing, let existingId) = rows[index].kind,
               messageId == nil || existingId == nil || existingId == messageId
            {
                rows[index].kind = .assistant(text: existing + text, messageId: existingId ?? messageId)
                rows[index].timestamp = timestamp ?? rows[index].timestamp
                return
            }
            guard !text.isEmpty else { return }
            rows.append(TimelineRow(id: id, kind: .assistant(text: text, messageId: messageId), timestamp: timestamp))

        case .reasoning(let text):
            if let index = rows.indices.last, case .reasoning(let existing) = rows[index].kind {
                rows[index].kind = .reasoning(text: existing + text)
                return
            }
            guard !text.isEmpty else { return }
            rows.append(TimelineRow(id: id, kind: .reasoning(text: text), timestamp: timestamp))

        case .toolCall(let call):
            if let index = rows.lastIndex(where: { if case .tool(let c) = $0.kind { c.callId == call.callId } else { false } }),
               case .tool(let existing) = rows[index].kind
            {
                rows[index].kind = .tool(Self.merge(existing, call))
                return
            }
            rows.append(TimelineRow(id: "tool-\(call.callId)", kind: .tool(call), timestamp: timestamp))

        case .userMessage(let text, let messageId):
            if confirmUser(text: text, messageId: messageId) { return }
            rows.append(TimelineRow(id: id, kind: .user(text: text, messageId: messageId, pending: false), timestamp: timestamp))

        default:
            if let row = Self.row(from: item, id: id, timestamp: timestamp) { rows.append(row) }
        }
    }

    /// Marks a matching optimistic user row as delivered. Returns true when one was found.
    private mutating func confirmUser(text: String, messageId: String?) -> Bool {
        let index = rows.lastIndex { row in
            guard case .user(let pendingText, let pendingId, true) = row.kind else { return false }
            if let messageId, let pendingId { return messageId == pendingId }
            return pendingText == text
        }
        guard let index, case .user(_, let pendingId, _) = rows[index].kind else { return false }
        rows[index].kind = .user(text: text, messageId: messageId ?? pendingId, pending: false)
        return true
    }

    static func merge(_ existing: ToolCall, _ incoming: ToolCall) -> ToolCall {
        var merged = incoming
        if incoming.detail.type == existing.detail.type || incoming.detail.type == "unknown" {
            var detail = existing.detail
            let new = incoming.detail
            if new.type != "unknown" { detail.type = new.type }
            detail.command = new.command ?? detail.command
            detail.cwd = new.cwd ?? detail.cwd
            detail.output = new.output ?? detail.output
            detail.exitCode = new.exitCode ?? detail.exitCode
            detail.filePath = new.filePath ?? detail.filePath
            detail.content = new.content ?? detail.content
            detail.oldString = new.oldString ?? detail.oldString
            detail.newString = new.newString ?? detail.newString
            detail.unifiedDiff = new.unifiedDiff ?? detail.unifiedDiff
            detail.query = new.query ?? detail.query
            detail.url = new.url ?? detail.url
            detail.result = new.result ?? detail.result
            detail.text = new.text ?? detail.text
            detail.label = new.label ?? detail.label
            detail.description = new.description ?? detail.description
            detail.subAgentType = new.subAgentType ?? detail.subAgentType
            detail.log = new.log ?? detail.log
            detail.input = new.input ?? detail.input
            merged.detail = detail
        }
        return merged
    }

    private mutating func nextId() -> String {
        nextLocalId += 1
        return "live-\(nextLocalId)"
    }

    static func row(from entry: TimelineEntry) -> TimelineRow? {
        let id = entry.seqStart.map { "seq-\($0)" } ?? UUID().uuidString
        return row(from: entry.item, id: id, timestamp: PaseoDate.parse(entry.timestamp))
    }

    static func row(from item: TimelineItem, id: String, timestamp: Date?) -> TimelineRow? {
        let kind: TimelineRow.Kind
        var id = id
        switch item {
        case .userMessage(let text, let messageId): kind = .user(text: text, messageId: messageId, pending: false)
        case .assistantMessage(let text, let messageId): kind = .assistant(text: text, messageId: messageId)
        case .reasoning(let text): kind = .reasoning(text: text)
        case .toolCall(let call):
            kind = .tool(call)
            id = "tool-\(call.callId)"
        case .todo(let items): kind = .todo(items)
        case .error(let message): kind = .error(message)
        case .notification(let level, let message): kind = .notification(level: level, message: message)
        case .compaction(let status): kind = .compaction(status: status)
        case .unknown: return nil
        }
        return TimelineRow(id: id, kind: kind, timestamp: timestamp)
    }
}

// MARK: - Sections

extension TimelineRow {
    /// Reasoning and tool calls: the agent's work towards its output rather than the output itself.
    public var isActivity: Bool {
        switch kind {
        case .reasoning, .tool: true
        default: false
        }
    }
}

/// What the timeline shows: a row, or a run of consecutive activity rows collapsed into one block.
public enum TimelineSection: Identifiable, Hashable, Sendable {
    case row(TimelineRow)
    case activity(id: String, rows: [TimelineRow])

    public var id: String {
        switch self {
        case .row(let row): row.id
        case .activity(let id, _): id
        }
    }

    /// Groups every run of two or more consecutive activity rows. A lone activity row stays a row.
    /// While `isLive`, the trailing run is still in progress, so its rows stay ungrouped until it ends.
    public static func sections(of rows: [TimelineRow], isLive: Bool = false) -> [TimelineSection] {
        var sections: [TimelineSection] = []
        var run: [TimelineRow] = []
        func flush(isFinished: Bool = true) {
            if run.count > 1, isFinished {
                sections.append(.activity(id: "activity-\(run[0].id)", rows: run))
            } else {
                sections += run.map(TimelineSection.row)
            }
            run = []
        }
        for row in rows {
            if row.isActivity {
                run.append(row)
            } else {
                flush()
                sections.append(.row(row))
            }
        }
        flush(isFinished: !isLive)
        return sections
    }
}

extension AgentTimeline {
    public var sections: [TimelineSection] { sections(isLive: false) }

    public func sections(isLive: Bool) -> [TimelineSection] { TimelineSection.sections(of: rows, isLive: isLive) }
}
