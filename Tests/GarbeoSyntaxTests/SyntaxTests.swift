import Foundation
import Testing
@testable import GarbeoSyntax

@Suite struct SyntaxTests {
    /// The text each span covers, with its capture.
    private func tokens(_ code: String, _ language: SyntaxLanguage) async throws -> [(text: String, capture: String)] {
        let utf16 = Array(code.utf16)
        return try await SyntaxHighlighter.spans(in: code, language: language).map {
            (String(decoding: utf16[$0.range], as: UTF16.self), $0.capture)
        }
    }

    private func capture(of text: String, in code: String, _ language: SyntaxLanguage) async throws -> String? {
        try await tokens(code, language).first { $0.text == text }?.capture
    }

    @Test func highlightsSwift() async throws {
        let code = #"func greet(name: String) -> String { return "Hi \(name)" } // done"#
        #expect(try await capture(of: "func", in: code, .swift)?.hasPrefix("keyword") == true)
        #expect(try await capture(of: "greet", in: code, .swift)?.hasPrefix("function") == true)
        #expect(try await capture(of: "String", in: code, .swift)?.hasPrefix("type") == true)
        #expect(try await capture(of: "// done", in: code, .swift)?.hasPrefix("comment") == true)
    }

    @Test func spansAreSortedAndDisjoint() async throws {
        let code = "const a = { b: [1, 'two', `t${3}`] }; // é 🎉\nfunction f() { return a }"
        let spans = try await SyntaxHighlighter.spans(in: code, language: .javascript)
        #expect(!spans.isEmpty)
        for (a, b) in zip(spans, spans.dropFirst()) { #expect(a.range.upperBound <= b.range.lowerBound) }
        #expect(spans.last.map { $0.range.upperBound <= code.utf16.count } == true)
    }

    /// `(identifier) @variable` comes first in the JavaScript query; the later, more specific patterns must win.
    @Test func laterPatternsWin() async throws {
        #expect(try await capture(of: "add", in: "function add(a, b) { return a + b }", .javascript) == "function")
        #expect(try await capture(of: "Thing", in: "new Thing()", .javascript) == "constructor")
    }

    @Test func composedQueries() async throws {
        // TypeScript runs its own query plus JavaScript's; C++ adds to C's.
        let ts = "interface User { id: number }\nconst f = (u: User) => u.id"
        #expect(try await capture(of: "number", in: ts, .typescript) == "type.builtin")
        #expect(try await capture(of: "const", in: ts, .typescript) == "keyword")
        #expect(try await capture(of: "class", in: "class A { int x; };", .cpp) == "keyword")
    }

    @Test func injectedLanguages() async throws {
        let markdown = "# Title\n\nSome *text*.\n\n```swift\nlet x = 1\n```\n"
        #expect(try await capture(of: "let", in: markdown, .markdown)?.hasPrefix("keyword") == true)
        #expect(try await capture(of: "text", in: markdown, .markdown) == "text.emphasis")
        // A closing fence at the very end, without a newline, still closes the block.
        #expect(try await capture(of: "```", in: "```sh\nls\n```", .markdown) == "punctuation.delimiter")
        #expect(try await !tokens("```sh\nls\n```", .markdown).contains { $0.text.contains("`") && $0.capture != "punctuation.delimiter" })
        let html = "<script>const y = 2</script><style>p { color: red }</style>"
        #expect(try await capture(of: "const", in: html, .html) == "keyword")
        #expect(try await capture(of: "color", in: html, .html) == "property")
        #expect(try await capture(of: "div", in: "const t = html`<div></div>`", .javascript) == "tag")
        // Macro bodies are reparsed as Rust: a token tree alone has no method calls.
        #expect(try await capture(of: "len", in: "fn f() { println!(\"{}\", v.len()); }", .rust) == "function.method")
    }

    @Test func detectsLanguages() {
        #expect(SyntaxLanguage(path: "/src/App/main.swift") == .swift)
        #expect(SyntaxLanguage(path: "web/index.TSX") == .tsx)
        #expect(SyntaxLanguage(path: "Gemfile") == .ruby)
        #expect(SyntaxLanguage(path: "~/.zshrc") == .bash)
        #expect(SyntaxLanguage(path: "Makefile") == .make)
        #expect(SyntaxLanguage(path: "Info.plist") == .xml)
        #expect(SyntaxLanguage(path: "notes.txt") == nil)
        #expect(SyntaxLanguage(name: "ts") == .typescript)
        #expect(SyntaxLanguage(name: "rust,ignore") == .rust)
        #expect(SyntaxLanguage(name: "Shell") == .bash)
        #expect(SyntaxLanguage(name: "python {.line-numbers}") == .python)
        #expect(SyntaxLanguage(name: "C#") == .csharp)
        #expect(SyntaxLanguage(name: "objective-c") == .objc)
        #expect(SyntaxLanguage(name: "brainfuck") == nil)
    }

    @Test func unifiedDiff() async throws {
        let diff = """
        --- a/x.py
        +++ b/x.py
        @@ -1,3 +1,3 @@
         def f():
        -    return "old"
        +    return 'new'
        \\ No newline at end of file
        """
        let lines = try await SyntaxDiff(diff, language: .python).lines
        #expect(lines.map(\.kind) == [.header, .header, .hunk, .context, .removed, .added, .header])
        #expect(lines[4].text == "    return \"old\"")
        // Each side parses as its own code: the removed line keeps its string highlight.
        let removed = lines[4].spans.first { $0.capture == "string" }
        #expect(removed.map { Array(lines[4].text.utf16)[$0.range].count } == 5)
        #expect(lines[3].spans.contains { $0.capture == "keyword" })
        #expect(lines[5].spans.contains { $0.capture == "string" })
    }

    @Test func lineDiffWithoutHunks() async throws {
        let lines = try await SyntaxDiff(" let a = 1\n-let b = 2\n+var b = 3", language: .swift).lines
        #expect(lines.map(\.kind) == [.context, .removed, .added])
        #expect(lines[2].text == "var b = 3")
        #expect(lines[2].spans.first?.range == 0..<3)
        #expect(SyntaxDiff("-a\n+b").lines.allSatisfy { $0.spans.isEmpty })
        // A trailing newline adds no line; text that isn't a diff line is kept whole.
        #expect(SyntaxDiff("+a\n").lines.count == 1)
        #expect(try await SyntaxDiff("src/a.swift", language: .swift).lines.map(\.text) == ["src/a.swift"])
    }

    @Test func themeFallsBackToParentCaptures() {
        let theme = SyntaxTheme.gitHub
        #expect(theme.style(for: "function.method.builtin") == theme.style(for: "function"))
        #expect(theme.style(for: "variable.parameter") == theme.style(for: "variable"))
        #expect(theme.style(for: "variable.builtin") != theme.style(for: "variable"))
        #expect(theme.style(for: "unknown") == nil)
    }

    @Test func attributedStringKeepsText() async throws {
        let code = "let s = \"é🎉\" // ok\nlet t = 2"
        let spans = try await SyntaxHighlighter.spans(in: code, language: .swift)
        let string = SyntaxTheme.gitHub.attributedString(code, spans: spans)
        #expect(String(string.characters) == code)
        #expect(string.runs.count > 3)
    }
}
