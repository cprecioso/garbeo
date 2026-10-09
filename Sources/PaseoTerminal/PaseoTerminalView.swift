import PaseoKit
import SwiftTerm
import SwiftUI

/// A self-contained live view of one daemon terminal: SwiftTerm emulator, keyboard input, resize handling,
/// and attach/exit status. Host it in any container; it attaches on appear and detaches on disappear.
///
/// Recreate it (e.g. with `.id`) when the `DaemonClient` changes, such as after a reconnect.
public struct PaseoTerminalView: View {
    @State private var session: TerminalSession
    private let focusOnAppear: Bool

    /// - Parameter focusOnAppear: make the terminal first responder when it appears, which also claims the
    ///   PTY size. Pass `false` for terminals that are visible but not the user's current focus.
    public init(client: DaemonClient, terminalId: String, focusOnAppear: Bool = true) {
        _session = State(initialValue: TerminalSession(client: client, terminalId: terminalId))
        self.focusOnAppear = focusOnAppear
    }

    /// Hosts a session the container owns, for example to read `title` or `phase`.
    public init(session: TerminalSession, focusOnAppear: Bool = true) {
        _session = State(initialValue: session)
        self.focusOnAppear = focusOnAppear
    }

    public var body: some View {
        SwiftTermHost(session: session, focusOnAppear: focusOnAppear)
            // The host view has no intrinsic size; without this, containers that size content by
            // its ideal size (e.g. split panes in an NSHostingController) collapse it to nothing.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(TerminalTheme.background))
            .overlay { statusOverlay }
    }

    @ViewBuilder private var statusOverlay: some View {
        switch session.phase {
        case .idle, .live:
            EmptyView()
        case .attaching:
            ProgressView().controlSize(.small).tint(.white)
        case .exited(let error):
            TerminalStatusBanner(
                message: error.map { "Terminal stream ended: \($0)" } ?? "Terminal exited", retry: session.reattach)
        case .failed(let error):
            TerminalStatusBanner(message: error, retry: session.reattach)
        }
    }
}

private struct TerminalStatusBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(message).font(.callout).multilineTextAlignment(.center)
            Button("Reattach", action: retry)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding()
    }
}

@MainActor
enum TerminalTheme {
    #if os(macOS)
    static var background: NSColor { NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1) }
    static var foreground: NSColor { NSColor(white: 0.9, alpha: 1) }
    static var font: NSFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }
    #else
    static var background: UIColor { UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1) }
    static var foreground: UIColor { UIColor(white: 0.9, alpha: 1) }
    static var font: UIFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }
    #endif
}

// MARK: - SwiftTerm bridge

/// SwiftTerm's view, wired to a `TerminalSession`.
@MainActor
final class SessionTerminalView: TerminalView, TerminalOutputSink {
    let session: TerminalSession

    init(session: TerminalSession) {
        self.session = session
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        font = TerminalTheme.font
        nativeBackgroundColor = TerminalTheme.background
        nativeForegroundColor = TerminalTheme.foreground
        terminalDelegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func restore(_ data: Data) {
        feed(byteArray: [0x1b, 0x63][...])
        feed(byteArray: ArraySlice(data))
    }

    func write(_ data: Data) {
        feed(byteArray: ArraySlice(data))
    }

    #if os(iOS)
    /// Become first responder once in a window (SwiftUI creates the view before mounting it).
    var focusWhenMounted = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, focusWhenMounted else { return }
        focusWhenMounted = false
        DispatchQueue.main.async { _ = self.becomeFirstResponder() }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { session.userDidInteract() }
        return accepted
    }
    #endif
}

// SwiftTerm calls its delegate on the main thread but predates Swift concurrency annotations.
extension SessionTerminalView: @preconcurrency TerminalViewDelegate {
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        session.gridDidChange(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        session.titleDidChange(title)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        session.send(Data(data))
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    #if os(iOS)
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        UIApplication.shared.open(url)
    }
    #endif
}

#if os(macOS)
/// Hosts the emulator and reports focus and clicks inside it as size-claiming interaction.
final class TerminalContainerView: NSView {
    let terminal: SessionTerminalView
    /// Make the terminal first responder once in a window (SwiftUI creates the view before mounting it).
    var focusWhenMounted = false
    private var mouseMonitor: Any?
    private var keyObserver: NSObjectProtocol?

    init(terminal: SessionTerminalView) {
        self.terminal = terminal
        super.init(frame: terminal.frame)
        terminal.autoresizingMask = [.width, .height]
        terminal.frame = bounds
        addSubview(terminal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        mouseMonitor = nil
        keyObserver = nil
        guard let window else { return }
        if focusWhenMounted {
            focusWhenMounted = false
            DispatchQueue.main.async { self.focus() }
        }
        // Returning to the window with the terminal focused is user focus too.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.firstResponder === self.terminal else { return }
                self.terminal.session.userDidInteract()
            }
        }
        // SwiftTerm's mouse handlers aren't overridable, so watch clicks without consuming them.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, event.window === self.window,
               self.terminal.bounds.contains(self.terminal.convert(event.locationInWindow, from: nil))
            {
                self.terminal.session.userDidInteract()
            }
            return event
        }
    }

    func focus() {
        guard let window, window.makeFirstResponder(terminal) else { return }
        terminal.session.userDidInteract()
    }
}

private struct SwiftTermHost: NSViewRepresentable {
    let session: TerminalSession
    let focusOnAppear: Bool

    func makeNSView(context: Context) -> TerminalContainerView {
        let terminal = SessionTerminalView(session: session)
        let container = TerminalContainerView(terminal: terminal)
        container.focusWhenMounted = focusOnAppear
        session.connect(sink: terminal)
        return container
    }

    func updateNSView(_ view: TerminalContainerView, context: Context) {}

    static func dismantleNSView(_ view: TerminalContainerView, coordinator: ()) {
        view.terminal.session.disconnect()
    }
}
#else
private struct SwiftTermHost: UIViewRepresentable {
    let session: TerminalSession
    let focusOnAppear: Bool

    func makeUIView(context: Context) -> SessionTerminalView {
        let terminal = SessionTerminalView(session: session)
        // SwiftTerm already shows its input accessory bar (esc, ctrl, tab, arrows, …) above the keyboard.
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        terminal.addGestureRecognizer(tap)
        terminal.focusWhenMounted = focusOnAppear
        session.connect(sink: terminal)
        return terminal
    }

    func updateUIView(_ view: SessionTerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    static func dismantleUIView(_ view: SessionTerminalView, coordinator: Coordinator) {
        view.session.disconnect()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let session: TerminalSession

        init(session: TerminalSession) { self.session = session }

        @objc func tapped() { session.userDidInteract() }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}
#endif
