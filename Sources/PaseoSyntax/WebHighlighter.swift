import Foundation
import os
import WebKit

private let log = Logger(subsystem: "dev.paseoswift.client", category: "syntax")

/// Highlights with tree-sitter grammars compiled to wasm, in web-tree-sitter (`Web/`) inside a `WebPage` that's never
/// shown. iOS doesn't allow JIT in the app process, but WebKit's own web content process has it, so the grammars run
/// at full speed there. The page starts with the first request; if its web content process dies (iOS reclaims them
/// in the background), the next request starts a new one.
@MainActor
final class WebHighlighter {
    static let shared = WebHighlighter(downloads: .shared)

    /// How deep injections nest (a markdown fence's HTML's script is 3).
    static let maximumDepth = 4

    private let downloads: GrammarDownloads
    private var page: Task<WebPage, any Error>?
    /// Grammars loaded into the current page. A grammar that fails to load stays failed for the page's lifetime.
    private var loaded: [String: Task<Void, any Error>] = [:]

    init(downloads: GrammarDownloads) {
        self.downloads = downloads
    }

    /// Raw captures for `code` and the languages injected into it, downloading grammars first if needed.
    func captures(in code: String, grammar: Grammar) async throws -> [SyntaxHighlighter.Capture] {
        let files = try await downloads.files(for: grammar)
        do {
            return try await layers(of: code, grammar: grammar, files: files)
        } catch {
            // A script error is the grammar's. Anything else most likely means the page is gone, with its web content
            // process, so retry once in a new one.
            if Self.isScriptError(error) { throw error }
            log.error("Web highlighting failed, restarting: \(String(describing: error), privacy: .public)")
            page = nil
            loaded = [:]
            return try await layers(of: code, grammar: grammar, files: files)
        }
    }

    /// Highlights `code`, then each injected language over its ranges, and so on. An injected language whose grammar
    /// can't be downloaded or loaded keeps its host's colors.
    private func layers(of code: String, grammar: Grammar, files: URL) async throws -> [SyntaxHighlighter.Capture] {
        var captures: [SyntaxHighlighter.Capture] = []
        var pending: [(grammar: Grammar, files: URL, ranges: [Any]?, depth: Int)] = [(grammar, files, nil, 0)]
        while !pending.isEmpty {
            let layer = pending.removeFirst()
            let result: Layer
            do {
                result = try await highlight(code, grammar: layer.grammar, files: layer.files, ranges: layer.ranges, depth: layer.depth)
            } catch where layer.depth > 0 && Self.isScriptError(error) {
                continue
            }
            captures += result.captures
            guard layer.depth < Self.maximumDepth else { continue }
            for (language, ranges) in result.injections {
                guard let injected = Grammars.injected(named: language),
                      let files = try? await downloads.files(for: injected) else { continue }
                pending.append((injected, files, ranges, layer.depth + 1))
            }
        }
        return captures
    }

    private struct Layer {
        var captures: [SyntaxHighlighter.Capture]
        /// Ranges as web-tree-sitter gives them, passed back as they are.
        var injections: [(language: String, ranges: [Any])]
    }

    private func highlight(_ code: String, grammar: Grammar, files: URL, ranges: [Any]?, depth: Int) async throws -> Layer {
        let page = try await currentPage()
        try await load(grammar, files: files, into: page)
        let result = try await page.callJavaScript(
            "return paseoSyntax.highlight(name, code, ranges)",
            arguments: ["name": grammar.name, "code": code, "ranges": ranges ?? NSNull()])
        guard let result, !(result is NSNull) else { throw GrammarNotLoaded() }
        guard let result = result as? [String: Any], let names = result["names"] as? [String],
              let flat = result["captures"] as? [Int], flat.count % 4 == 0,
              let injections = result["injections"] as? [[String: Any]] else {
            throw UnexpectedResult()
        }
        return Layer(
            captures: stride(from: 0, to: flat.count, by: 4).map {
                SyntaxHighlighter.Capture(start: flat[$0], end: flat[$0 + 1], name: names[flat[$0 + 2]], pattern: flat[$0 + 3], depth: depth)
            },
            injections: injections.compactMap { injection in
                guard let language = injection["language"] as? String, let ranges = injection["ranges"] as? [Any] else { return nil }
                return (language, ranges)
            }
        )
    }

    private struct UnexpectedResult: Error {}
    private struct GrammarNotLoaded: Error {}

    private static func isScriptError(_ error: any Error) -> Bool {
        error is UnexpectedResult || (error as? WKError)?.code == .javaScriptExceptionOccurred
    }

    private func currentPage() async throws -> WebPage {
        if let page { return try await page.value }
        let task = Task {
            var configuration = WebPage.Configuration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.urlSchemeHandlers[URLScheme(PageScheme.scheme)!] = PageScheme(grammars: downloads.directory)
            let page = WebPage(configuration: configuration)
            #if DEBUG
            page.isInspectable = true
            #endif
            for try await _ in page.load(URL(string: "\(PageScheme.scheme)://host/index.html")!) {}
            return page
        }
        page = task
        do {
            return try await task.value
        } catch {
            page = nil
            throw error
        }
    }

    private func load(_ grammar: Grammar, files: URL, into page: WebPage) async throws {
        if let load = loaded[grammar.name] { return try await load.value }
        let directory = files.lastPathComponent
        let task = Task {
            let highlights = try String(contentsOf: files.appending(path: "highlights.scm"), encoding: .utf8)
            let injections = try String(contentsOf: files.appending(path: "injections.scm"), encoding: .utf8)
            _ = try await page.callJavaScript(
                "await paseoSyntax.load(name, url, highlights, injections)",
                arguments: ["name": grammar.name, "url": "/grammars/\(directory)/parser.wasm",
                            "highlights": highlights, "injections": injections])
        }
        loaded[grammar.name] = task
        try await task.value
    }
}

/// Serves the page: web-tree-sitter and its glue from the package's resources, and downloaded grammars.
private struct PageScheme: URLSchemeHandler {
    static let scheme = "paseo-syntax"

    let grammars: URL

    private static let indexHTML = """
    <!doctype html>
    <meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src paseo-syntax: 'wasm-unsafe-eval'">
    <script type="module" src="highlighter.js"></script>
    """

    func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
        AsyncThrowingStream { continuation in
            guard let url = request.url, let (body, type) = resource(at: url.path) else {
                continuation.finish(throwing: URLError(.fileDoesNotExist))
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": type, "Content-Length": "\(body.count)"])!
            continuation.yield(.response(response))
            continuation.yield(.data(body))
            continuation.finish()
        }
    }

    private static let resources: Set = ["/highlighter.js", "/web-tree-sitter.js", "/web-tree-sitter.wasm"]

    private func resource(at path: String) -> (Data, String)? {
        if path == "/index.html" { return (Data(Self.indexHTML.utf8), "text/html; charset=utf-8") }
        let file: URL
        if path.hasPrefix("/grammars/") {
            let relative = path.dropFirst("/grammars/".count)
            file = grammars.appending(path: String(relative)).standardizedFileURL
            guard file.path.hasPrefix(grammars.standardizedFileURL.path + "/") else { return nil }
        } else if Self.resources.contains(path),
                  let resource = Bundle.module.url(forResource: String(path.dropFirst()), withExtension: nil, subdirectory: "Web") {
            file = resource
        } else {
            return nil
        }
        guard let body = try? Data(contentsOf: file) else { return nil }
        let type = switch file.pathExtension {
        case "js": "text/javascript; charset=utf-8"
        case "wasm": "application/wasm"
        default: "application/octet-stream"
        }
        return (body, type)
    }
}
