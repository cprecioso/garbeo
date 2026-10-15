import PaseoKit
import SwiftTerm
import SwiftUI

/// A self-contained live view of one daemon terminal: SwiftTerm emulator, keyboard input, resize handling,
/// and attach/exit status. Host it in any container; it attaches on appear and detaches on disappear.
///
/// Recreate it (e.g. with `.id`) when the `DaemonClient` changes, such as after a reconnect.
public struct GarbeoTerminalView: View {
    @State private var session: TerminalSession
    @Environment(\.colorScheme) private var colorScheme
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

    private var theme: TerminalTheme { colorScheme == .dark ? .dark : .light }

    public var body: some View {
        SwiftTermHost(session: session, theme: theme, focusOnAppear: focusOnAppear)
            // The host view has no intrinsic size; without this, containers that size content by
            // its ideal size (e.g. split panes in an NSHostingController) collapse it to nothing.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(theme.background))
            .overlay { statusOverlay }
    }

    @ViewBuilder private var statusOverlay: some View {
        switch session.phase {
        case .idle, .live:
            EmptyView()
        case .attaching:
            ProgressView().controlSize(.small).tint(Color(theme.foreground))
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

#if os(macOS)
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
#else
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
#endif

/// Terminal colors as 0xRRGGBB, ported from the upstream Paseo app's default light and dark themes.
struct TerminalTheme: Equatable {
    var backgroundRGB: UInt32
    var foregroundRGB: UInt32
    /// Upstream's translucent selection, pre-blended over the background.
    var selectionRGB: UInt32
    /// Black, red, green, yellow, blue, magenta, cyan, white, then their bright variants.
    var ansiRGB: [UInt32]

    static let dark = TerminalTheme(
        backgroundRGB: 0x181B1A, foregroundRGB: 0xFAFAFA, selectionRGB: 0x464948,
        ansiRGB: [
            0x141716, 0xE07070, 0x5DBA80, 0xD4A44A, 0x6A9DE0, 0xB07AD0, 0x4AABB8, 0xD4D4D8,
            0x434645, 0xE89090, 0x7ECF9A, 0xE0BE6E, 0x8AB4E8, 0xC49AE0, 0x6EC2CC, 0xF0F0F2,
        ])

    static let light = TerminalTheme(
        backgroundRGB: 0xFFFFFF, foregroundRGB: 0x1A1A1E, selectionRGB: 0xD9D9D9,
        ansiRGB: [
            0x1A1A1E, 0xDC2626, 0x16A34A, 0xCA8A04, 0x2563EB, 0x9333EA, 0x0891B2, 0xFFFFFF,
            0x3F3F46, 0xEF4444, 0x22C55E, 0xF59E0B, 0x3B82F6, 0xA855F7, 0x06B6D4, 0xFAFAFA,
        ])

    var background: PlatformColor { Self.native(backgroundRGB) }
    var foreground: PlatformColor { Self.native(foregroundRGB) }
    var selection: PlatformColor { Self.native(selectionRGB) }
    var ansi: [SwiftTerm.Color] {
        ansiRGB.map { SwiftTerm.Color(red8: UInt16($0 >> 16 & 0xFF), green8: UInt16($0 >> 8 & 0xFF), blue8: UInt16($0 & 0xFF)) }
    }

    @MainActor static var font: PlatformFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }

    private static func native(_ rgb: UInt32) -> PlatformColor {
        PlatformColor(
            red: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - SwiftTerm bridge

/// SwiftTerm's view, wired to a `TerminalSession`.
@MainActor
final class SessionTerminalView: TerminalView, TerminalOutputSink {
    let session: TerminalSession
    private var theme: TerminalTheme?

    init(session: TerminalSession) {
        self.session = session
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        font = TerminalTheme.font
        terminalDelegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ theme: TerminalTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        // Default colors first: SwiftTerm derives the 256-color palette from them.
        nativeBackgroundColor = theme.background
        nativeForegroundColor = theme.foreground
        #if os(iOS)
        // SwiftTerm paints the iOS background from its layer, resolved once at init.
        layer.backgroundColor = theme.background.cgColor
        #endif
        selectedTextBackgroundColor = theme.selection
        selectedTextForegroundColor = theme.foreground
        installColors(theme.ansi)
    }

    func restore(_ data: Data) {
        feed(byteArray: [0x1b, 0x63][...])
        feed(byteArray: ArraySlice(data))
    }

    func write(_ data: Data) {
        feed(byteArray: ArraySlice(data))
    }

    /// Bytes the emulator generates itself (query replies, mouse reports), as opposed to typed input,
    /// which arrives through `TerminalViewDelegate.send`.
    nonisolated override func send(source: Terminal, data: ArraySlice<UInt8>) {
        let data = Data(data)
        let session = session
        DispatchQueue.main.async {
            MainActor.assumeIsolated { session.reply(data) }
        }
    }

    #if DEBUG
    /// Development aid: `-GarbeoTerminalType 'echo hi\r'` types through the emulator's input path
    /// shortly after the terminal goes live (and after its restore).
    func typeDebugInputIfRequested() {
        guard let text = UserDefaults.standard.string(forKey: "GarbeoTerminalType") else { return }
        Task { [weak self] in
            while let self, self.session.phase != .live { try? await Task.sleep(for: .milliseconds(20)) }
            try? await Task.sleep(for: .milliseconds(300))
            self?.send(txt: text.replacingOccurrences(of: "\\r", with: "\r"))
        }
    }
    #endif

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

extension SessionTerminalView: TerminalViewDelegate {
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
    let theme: TerminalTheme
    let focusOnAppear: Bool

    func makeNSView(context: Context) -> TerminalContainerView {
        let terminal = SessionTerminalView(session: session)
        terminal.apply(theme)
        let container = TerminalContainerView(terminal: terminal)
        container.focusWhenMounted = focusOnAppear
        session.connect(sink: terminal)
        #if DEBUG
        terminal.typeDebugInputIfRequested()
        #endif
        return container
    }

    func updateNSView(_ view: TerminalContainerView, context: Context) {
        view.terminal.apply(theme)
    }

    static func dismantleNSView(_ view: TerminalContainerView, coordinator: ()) {
        view.terminal.session.disconnect()
    }
}
#else
private struct SwiftTermHost: UIViewRepresentable {
    let session: TerminalSession
    let theme: TerminalTheme
    let focusOnAppear: Bool

    func makeUIView(context: Context) -> SessionTerminalView {
        let terminal = SessionTerminalView(session: session)
        terminal.apply(theme)
        // SwiftTerm already shows its input accessory bar (esc, ctrl, tab, arrows, …) above the keyboard.
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        terminal.addGestureRecognizer(tap)
        terminal.focusWhenMounted = focusOnAppear
        session.connect(sink: terminal)
        #if DEBUG
        terminal.typeDebugInputIfRequested()
        #endif
        return terminal
    }

    func updateUIView(_ view: SessionTerminalView, context: Context) {
        view.apply(theme)
    }

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
