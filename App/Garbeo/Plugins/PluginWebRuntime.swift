import Foundation
import UniformTypeIdentifiers
import OSLog
import PaseoKit
import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private let log = Logger(subsystem: "design.precioso.garbeo", category: "plugins")

/// Delegate for what a plugin page asks of the app (navigation, contributions, RPC).
@MainActor
protocol PluginRuntimeHost: AnyObject {
    var pluginClient: DaemonClient? { get }
    var pluginEndpoint: DaemonEndpoint? { get }
    func runtime(_ runtime: PluginWebRuntime, received message: [String: JSONValue])
}

/// One WKWebView running the plugin host page (PluginHost/, bundled as plugin-host.js).
///
/// Bridge contract (see PluginHost/src/bridge.ts):
/// - The page is served from `paseo-plugin://host/` by `PluginAssetSchemeHandler`; navigation
///   anywhere else is cancelled, and http(s) links open in the system browser.
/// - The init payload (mode, catalog bundles, target, theme, host, layout, snapshots) is
///   injected as `window.__paseoInit` by a WKUserScript before the page's own script runs.
/// - JS -> Swift: `webkit.messageHandlers.paseoHost.postMessage(msg)` returns a promise of the
///   reply. `rpc` maps to `plugin.rpc.invoke.request` on the app's own connection.
/// - Swift -> JS: `window.__paseoHost.receive(msg)` for theme/state updates, socket frames,
///   sidebar presses and Command Center selections.
/// - `socket.*` messages relay a second daemon session for the in-page `@getpaseo/client`
///   (`usePaseo()`), opened natively because the daemon rejects unknown WebSocket origins.
@MainActor
final class PluginWebRuntime: NSObject {
    enum Mode: Equatable {
        case registry
        case pane(PluginPaneTarget)
    }

    static let scheme = "paseo-plugin"
    static let origin = "paseo-plugin://host"

    let mode: Mode
    let webView: WKWebView
    private weak var host: PluginRuntimeHost?
    private var ready = false
    private var queued: [JSONValue] = []
    private var sockets: [String: any DaemonTransport] = [:]
    private let session = URLSession(configuration: .default)
    private(set) var rendered = false

    init(mode: Mode, initPayload: JSONValue, host: PluginRuntimeHost) {
        self.mode = mode
        self.host = host
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(PluginAssetSchemeHandler(), forURLScheme: Self.scheme)
        configuration.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: "window.__paseoInit = \(initPayload.jsonString);",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController = controller
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        #endif
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        controller.addScriptMessageHandler(WeakReplyHandler(self), contentWorld: .page, name: "paseoHost")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #endif
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.load(URLRequest(url: URL(string: "\(Self.origin)/index.html")!))
    }

    /// Stops sockets and the page. The runtime is unusable afterwards.
    func shutdown() {
        for transport in sockets.values { transport.close() }
        sockets.removeAll()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    // MARK: Swift -> JS

    func send(_ message: JSONValue) {
        guard ready else {
            queued.append(message)
            return
        }
        webView.evaluateJavaScript("window.__paseoHost && window.__paseoHost.receive(\(message.jsonString));") { _, error in
            if let error { log.error("plugin bridge send failed: \(error.localizedDescription)") }
        }
    }

    func updateTheme(_ scheme: ColorScheme) {
        send(["type": "theme", "theme": PluginHostValues.theme(for: scheme), "colorScheme": .string(scheme == .dark ? "dark" : "light")])
    }

    /// Clicks the first element whose accessibility label matches (DEBUG automation only).
    func press(accessibilityLabel label: String) async throws {
        _ = try await webView.callAsyncJavaScript(
            "const el = [...document.querySelectorAll('[aria-label]')].find(e => e.getAttribute('aria-label').startsWith(label)); if (!el) throw new Error('No element labelled ' + label); el.click(); return true;",
            arguments: ["label": label], contentWorld: .page)
    }

    // MARK: JS -> Swift

    fileprivate func handle(_ body: Any) async -> (Any?, String?) {
        guard case .object(let message) = JSONValue(foundation: body), let type = message["type"]?.stringValue else {
            return (nil, "Malformed bridge message")
        }
        switch type {
        case "ready":
            ready = true
            let pending = queued
            queued.removeAll()
            pending.forEach(send)
            return (nil, nil)
        case "log":
            let level = message["level"]?.stringValue ?? "log"
            let text = message["message"]?.stringValue ?? ""
            if level == "error" { log.error("[plugin] \(text, privacy: .public)") } else { log.info("[plugin] \(text, privacy: .public)") }
            return (nil, nil)
        case "rpc":
            guard let pluginId = message["pluginId"]?.stringValue, let method = message["method"]?.stringValue else {
                return (nil, "rpc needs pluginId and method")
            }
            // A page may only call its own plugin's RPCs; the registry hosts every plugin.
            if case .pane(let target) = mode, target.pluginId != pluginId {
                return (nil, "Plugin \(target.pluginId) cannot call \(pluginId) RPCs")
            }
            guard let client = host?.pluginClient else { return (nil, PaseoError.disconnected.localizedDescription) }
            do {
                let output = try await client.invokePluginRpc(pluginId: pluginId, method: method, input: message["input"] ?? .null)
                host?.runtime(self, received: message.merging(["output": output]) { $1 })
                return (output.foundationObject, nil)
            } catch {
                host?.runtime(self, received: message.merging(["error": .string(error.localizedDescription)]) { $1 })
                return (nil, error.localizedDescription)
            }
        case "socket.open":
            guard let socketId = message["socketId"]?.stringValue else { return (nil, "socket.open needs socketId") }
            return openSocket(socketId)
        case "socket.send":
            guard let socketId = message["socketId"]?.stringValue, let data = message["data"]?.stringValue,
                  let transport = sockets[socketId]
            else { return (nil, "Socket is closed") }
            do {
                try await transport.send(.text(data))
                return (nil, nil)
            } catch {
                return (nil, error.localizedDescription)
            }
        case "socket.close":
            if let socketId = message["socketId"]?.stringValue {
                sockets.removeValue(forKey: socketId)?.close()
            }
            return (nil, nil)
        case "openExternal":
            if let url = message["url"]?.stringValue.flatMap(URL.init(string:)) { Self.openExternally(url) }
            return (nil, nil)
        case "copy":
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message["text"]?.stringValue ?? "", forType: .string)
            #else
            UIPasteboard.general.string = message["text"]?.stringValue ?? ""
            #endif
            return (nil, nil)
        case "rendered":
            rendered = true
            host?.runtime(self, received: message)
            return (nil, nil)
        default:
            host?.runtime(self, received: message)
            return (nil, nil)
        }
    }

    // MARK: Socket relay

    /// Uses the same transport as the app's own connection, so relay (E2EE) hosts work too.
    private func openSocket(_ socketId: String) -> (Any?, String?) {
        guard let endpoint = host?.pluginEndpoint, let transport = try? endpoint.makeTransport(session: session) else {
            return (nil, PaseoError.disconnected.localizedDescription)
        }
        sockets[socketId] = transport
        Task { [weak self] in
            do {
                try await transport.open()
                // The page sends its `hello` on open, so only report it once frames can flow.
                self?.sendSocketEvent(socketId, "open")
            } catch {
                guard let self, self.sockets.removeValue(forKey: socketId) != nil else { return }
                self.sendSocketEvent(socketId, "close", reason: error.localizedDescription)
                return
            }
            while true {
                do {
                    let frame = try await transport.receive()
                    guard let self else { return }
                    if case .text(let text) = frame { self.sendSocketEvent(socketId, "message", data: text) }
                } catch {
                    guard let self, self.sockets.removeValue(forKey: socketId) != nil else { return }
                    self.sendSocketEvent(socketId, "close", reason: error.localizedDescription)
                    return
                }
            }
        }
        return (nil, nil)
    }

    private func sendSocketEvent(_ socketId: String, _ event: String, data: String? = nil, reason: String? = nil) {
        var message: [String: JSONValue] = ["type": "socket", "socketId": .string(socketId), "event": .string(event)]
        if let data { message["data"] = .string(data) }
        if let reason { message["reason"] = .string(reason) }
        send(.object(message))
    }

    static func openExternally(_ url: URL) {
        guard ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

// MARK: - Navigation policy

extension PluginWebRuntime: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if url.scheme == Self.scheme, url.host == "host" { return .allow }
        if url.absoluteString == "about:blank" { return .allow }
        // Plugins render React Native views, but a raw <a href> can still navigate: send it out.
        if navigationAction.navigationType == .linkActivated { Self.openExternally(url) }
        return .cancel
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url { Self.openExternally(url) }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.error("plugin web content process terminated; reloading")
        ready = false
        for transport in sockets.values { transport.close() }
        sockets.removeAll()
        webView.reload()
    }
}

/// WKUserContentController retains its handlers; this breaks the cycle with the runtime.
private final class WeakReplyHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var runtime: PluginWebRuntime?

    init(_ runtime: PluginWebRuntime) {
        self.runtime = runtime
    }

    @MainActor
    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        // Only the host page itself may talk to the app.
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == PluginWebRuntime.scheme,
              let runtime
        else { return (nil, "Not allowed") }
        return await runtime.handle(message.body)
    }
}

// MARK: - Assets

/// Serves the host page and its script from the app bundle at `paseo-plugin://host/`.
final class PluginAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static var indexPage = NSDataAsset(name: "PluginHostIndex")!
    static var pluginHostScript = NSDataAsset(name: "PluginHostScript")!
    
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        
        let asset: NSDataAsset
        switch url.path {
        case "/", "/index.html": asset = Self.indexPage
        case "/plugin-host.js": asset = Self.pluginHostScript
        default:
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        
        let body = asset.data
        guard let mime = UTType(asset.typeIdentifier)?.preferredMIMEType else {
            urlSchemeTask.didFailWithError(URLError(.cannotDecodeRawData))
            return
        }
        
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "\(mime); charset=utf-8", "Content-Length": "\(body.count)", "Cache-Control": "no-store"])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(body)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
