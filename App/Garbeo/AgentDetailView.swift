import PaseoKit
import GarbeoSyntax
import SwiftUI

struct AgentDetailView: View {
    /// `.window` drives the window's title and toolbar; `.pane` (one of several workspace panes)
    /// draws its own compact header instead.
    enum Chrome { case window, pane }

    @Environment(AppModel.self) private var model
    let agent: Agent
    var chrome: Chrome = .window
    /// Identifies this view in the model's visible-agent set, so the same agent can be open in
    /// several panes and each mount/unmount is counted separately.
    @State private var viewerId = UUID()

    var body: some View {
        content
            .onAppear { model.showTimeline(agent.id, viewer: viewerId) }
            .onDisappear { model.hideTimeline(viewer: viewerId) }
            .onChange(of: agent.id) { _, agentId in model.showTimeline(agentId, viewer: viewerId) }
    }

    @ViewBuilder private var content: some View {
        switch chrome {
        case .window:
            main
                .navigationTitle(agent.displayTitle)
                #if os(macOS)
                .navigationSubtitle(subtitle)
                #else
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { AgentToolbar(agent: agent) }
                .toolbar { PluginAgentToolbar(agent: agent) }
        case .pane:
            VStack(spacing: 0) {
                AgentPaneHeader(agent: agent, subtitle: subtitle)
                Divider()
                main
            }
        }
    }

    private var main: some View {
        VStack(spacing: 0) {
            TimelineView(agent: agent)
            let permissions = model.pendingPermissions(for: agent.id)
            if !permissions.isEmpty {
                VStack(spacing: 8) {
                    ForEach(permissions) { PermissionCard(request: $0, agentId: agent.id) }
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            ComposerView(agent: agent)
        }
    }

    private var subtitle: String {
        [agent.status.label, agent.provider, agent.model, (agent.cwd as NSString).abbreviatingWithTildeInPath]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

private struct AgentToolbar: ToolbarContent {
    let agent: Agent

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            ModeMenu(agent: agent)
                .labelStyle(.titleAndIcon)
            ContextGauge(agent: agent)
            AgentMoreMenu(agent: agent)
        }
    }
}

/// Title row for an agent shown inside a workspace pane, where the window toolbar belongs to the
/// workspace rather than to any one agent.
private struct AgentPaneHeader: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    let subtitle: String
    /// Panes can be as narrow as 100pt; controls collapse so they never force the pane wider.
    @State private var width: CGFloat = 1000

    var body: some View {
        HStack(spacing: 8) {
            StatusIndicator(agent: agent, hasPermission: !model.pendingPermissions(for: agent.id).isEmpty)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.displayTitle).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if width >= 300 {
                ModeMenu(agent: agent)
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .modifier(CompactLabelStyle(compact: width < 460))
                    .fixedSize()
                ContextGauge(agent: agent)
            }
            AgentMoreMenu(agent: agent)
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .modifier(CompactLabelStyle(compact: width < 460))
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minWidth: 0, maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
    }
}

/// Switches between the built-in label styles via `.labelStyle(...)` so SwiftUI installs them
/// normally. Calling a built-in style's `makeBody` by hand reads its environment values outside
/// of a view, which always yields defaults and logs a runtime error.
private struct CompactLabelStyle: ViewModifier {
    let compact: Bool

    func body(content: Content) -> some View {
        if compact {
            content.labelStyle(.iconOnly)
        } else {
            content.labelStyle(.titleAndIcon)
        }
    }
}

private struct ModeMenu: View {
    @Environment(AppModel.self) private var model
    let agent: Agent

    var body: some View {
        if let modes = agent.availableModes, !modes.isEmpty {
            Menu {
                ForEach(modes) { mode in
                    Button {
                        Task { await model.setMode(mode.id, for: agent.id) }
                    } label: {
                        if mode.id == agent.currentModeId {
                            Label(mode.label, systemImage: "checkmark")
                        } else {
                            Text(mode.label)
                        }
                    }
                    .help(mode.description ?? "")
                }
            } label: {
                Label(agent.currentMode?.label ?? "Mode", systemImage: "shield.lefthalf.filled")
            }
            .help("Permission mode")
        }
    }
}

private struct ContextGauge: View {
    let agent: Agent

    var body: some View {
        if let usage = agent.lastUsage, let used = usage.contextWindowUsedTokens, let max = usage.contextWindowMaxTokens, max > 0 {
            Gauge(value: Double(used), in: 0...Double(max)) {
                Text("Context")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .scaleEffect(0.5)
            .frame(width: 28, height: 28)
            .help("Context: \(used.formatted()) / \(max.formatted()) tokens")
        }
    }
}

private struct AgentMoreMenu: View {
    @Environment(AppModel.self) private var model
    let agent: Agent

    var body: some View {
        Menu {
            Button("Reload Timeline", systemImage: "arrow.clockwise") { Task { await model.reloadTimeline(agent.id) } }
            Button("Archive Agent", systemImage: "archivebox") { Task { await model.archive(agent.id) } }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }
}

// MARK: - Timeline

private struct TimelineView: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    /// Expanded reasoning and tool rows. Kept here rather than in the rows, since the lazy stack
    /// may discard an off-screen row's state.
    @State private var expanded: Set<String> = []

    var body: some View {
        let live = model.timelines[agent.id]
        let timeline = live?.timeline ?? AgentTimeline()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if timeline.hasOlder {
                    Button {
                        Task { await model.loadOlder(agent.id) }
                    } label: {
                        if live?.isLoadingOlder == true { ProgressView().controlSize(.small) } else { Text("Load earlier messages") }
                    }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity)
                }
                if !timeline.isLoaded {
                    if let error = model.timelineError(for: agent.id) {
                        ContentUnavailableView {
                            Label("Couldn't load timeline", systemImage: "exclamationmark.bubble")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Retry") { Task { await model.reloadTimeline(agent.id) } }
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }
                } else if timeline.rows.isEmpty {
                    Text("No messages yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                }
                ForEach(timeline.rows) { row in
                    TimelineRowView(row: row, isExpanded: isExpanded(row.id))
                }
                if agent.status == .running {
                    WorkingIndicator(since: agent.activeTurn?.startedAt)
                }
            }
            .padding()
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        // Chat-style scrolling: open at the newest message and stay anchored to the bottom as
        // rows stream in. Manual `scrollTo` on a lazy stack can land in an unrendered region.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .id(timeline.isLoaded)
        .onChange(of: agent.id) { expanded = [] }
    }

    private func isExpanded(_ id: String) -> Binding<Bool> {
        Binding {
            expanded.contains(id)
        } set: {
            if $0 { expanded.insert(id) } else { expanded.remove(id) }
        }
    }
}

private struct WorkingIndicator: View {
    let since: String?

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            if let start = PaseoDate.parse(since) {
                Text("Working for \(Text(start, style: .timer))")
            } else {
                Text("Working…")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

struct TimelineRowView: View {
    let row: TimelineRow
    @Binding var isExpanded: Bool

    var body: some View {
        switch row.kind {
        case .user(let text, _, let pending):
            HStack {
                Spacer(minLength: 60)
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .opacity(pending ? 0.6 : 1)
            }
        case .assistant(let text, _):
            MarkdownText(text)
        case .reasoning(let text):
            CollapsibleRow(icon: "brain", title: "Thinking", subtitle: nil, tint: .secondary, isExpanded: $isExpanded) {
                Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        case .tool(let call):
            ToolCallRow(call: call, isExpanded: $isExpanded)
        case .todo(let items):
            VStack(alignment: .leading, spacing: 4) {
                Label("Tasks", systemImage: "checklist").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: item.completed ? "checkmark.circle.fill" : item.status == "in_progress" ? "circle.dotted" : "circle")
                            .foregroundStyle(item.completed ? .green : .secondary)
                        Text(item.text).strikethrough(item.completed).foregroundStyle(item.completed ? .secondary : .primary)
                    }
                    .font(.callout)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        case .error(let message):
            Label(message, systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .notification(let level, let message):
            Label(message, systemImage: level == "error" ? "exclamationmark.octagon" : level == "warning" ? "exclamationmark.triangle" : "info.circle")
                .font(.callout)
                .foregroundStyle(level == "error" ? .red : level == "warning" ? .orange : .secondary)
        case .compaction(let status):
            HStack {
                VStack { Divider() }
                Text(status == "loading" ? "Compacting context…" : "Context compacted").font(.caption).foregroundStyle(.secondary)
                VStack { Divider() }
            }
        }
    }
}

private struct ToolCallRow: View {
    let call: ToolCall
    @Binding var isExpanded: Bool

    var body: some View {
        CollapsibleRow(icon: icon, title: call.name, subtitle: call.detail.summary, tint: tint, trailing: statusView, isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                if let body = call.detail.body, !body.isEmpty {
                    CodeBlock(text: String(body.prefix(20_000)), isDiff: call.detail.type == "edit", language: language)
                }
                if let error = call.error, !error.isNull {
                    Text(error.displayString).font(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled)
                }
                if let exitCode = call.detail.exitCode, exitCode != 0 {
                    Text("Exit code \(exitCode)").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    /// Read, written and edited files are highlighted by their extension.
    private var language: SyntaxLanguage? {
        call.detail.filePath.flatMap(SyntaxLanguage.init(path:))
    }

    private var icon: String {
        switch call.detail.type {
        case "shell": "terminal"
        case "read": "doc.text"
        case "edit": "pencil"
        case "write": "square.and.pencil"
        case "search": "magnifyingglass"
        case "fetch": "globe"
        case "sub_agent": "person.2"
        case "plan": "list.bullet.clipboard"
        default: "wrench.and.screwdriver"
        }
    }

    private var tint: Color {
        switch call.status {
        case "failed": .red
        case "canceled": .orange
        default: .secondary
        }
    }

    @ViewBuilder private var statusView: some View {
        switch call.status {
        case "running": ProgressView().controlSize(.mini)
        case "failed": Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case "canceled": Image(systemName: "slash.circle").foregroundStyle(.orange)
        default: EmptyView()
        }
    }
}

private struct CollapsibleRow<Content: View, Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String?
    let tint: Color
    var trailing: Trailing
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    init(icon: String, title: String, subtitle: String?, tint: Color, trailing: Trailing = EmptyView(),
         isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content)
    {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
        self.trailing = trailing
        _isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon).frame(width: 16).foregroundStyle(tint)
                    Text(title).fontWeight(.medium)
                    if let subtitle {
                        Text(subtitle).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    trailing
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .font(.callout)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                content().padding(.leading, 22)
            }
        }
    }
}

// MARK: - Permissions

private struct PermissionCard: View {
    @Environment(AppModel.self) private var model
    let request: PermissionRequest
    let agentId: String
    @State private var isResponding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(request.title ?? "\(request.name) wants permission", systemImage: "hand.raised.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            if let description = request.description { Text(description).font(.callout) }
            if let detail = request.detail, let shown = shownText(of: detail) {
                CodeBlock(text: String(shown.prefix(4_000)), isDiff: detail.type == "edit", language: language(of: detail))
            } else if let input = request.input {
                CodeBlock(text: String(input.displayString.prefix(4_000)))
            }
            HStack {
                Spacer()
                if let actions = request.actions, !actions.isEmpty {
                    ForEach(actions) { action in
                        button(action.label, allow: action.behavior == "allow", actionId: action.id,
                               prominent: action.variant == "primary")
                    }
                } else {
                    button("Deny", allow: false, actionId: nil, prominent: false)
                    button("Allow", allow: true, actionId: nil, prominent: true)
                }
            }
            .disabled(isResponding)
        }
        .padding(12)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.orange.opacity(0.4)))
    }

    /// An edit shows its diff; anything else its one-line summary (the command, path, query, …).
    private func shownText(of detail: ToolCallDetail) -> String? {
        detail.type == "edit" ? detail.body ?? detail.summary : detail.summary ?? detail.body
    }

    private func language(of detail: ToolCallDetail) -> SyntaxLanguage? {
        switch detail.type {
        case "shell": .bash
        case "edit": detail.filePath.flatMap(SyntaxLanguage.init(path:))
        default: nil
        }
    }

    @ViewBuilder
    private func button(_ title: String, allow: Bool, actionId: String?, prominent: Bool) -> some View {
        let action = {
            isResponding = true
            Task {
                await model.respond(to: request, agentId: agentId, allow: allow, actionId: actionId)
                isResponding = false
            }
        }
        if prominent {
            Button(title, action: action).buttonStyle(.borderedProminent)
        } else {
            Button(title, role: allow ? nil : .destructive, action: action).buttonStyle(.bordered)
        }
    }
}

// MARK: - Composer

private struct ComposerView: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message the agent…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...10)
                .focused($isFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.separator))
                .onSubmit(send)
                #if os(macOS)
                .onKeyPress(.return, phases: .down) { press in
                    // Shift-Return inserts a newline; Return sends.
                    if press.modifiers.contains(.shift) { return .ignored }
                    send()
                    return .handled
                }
                #endif

            if agent.status == .running {
                Button {
                    Task { await model.cancel(agent.id) }
                } label: {
                    Image(systemName: "stop.circle.fill").font(.title)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help("Stop the current turn (⌘.)")
            }
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.title)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
            .disabled(!canSend)
            .help("Send")
        }
        .padding()
        #if os(macOS)
        .onAppear { isFocused = true }
        #endif
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.connection.isConnected
    }

    private func send() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        text = ""
        Task { await model.send(message, to: agent.id) }
    }
}
