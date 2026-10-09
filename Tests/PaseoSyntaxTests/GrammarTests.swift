import Foundation
import Testing
@testable import PaseoSyntax

/// Highlights a snippet with every grammar. The first run downloads them all (into the caches directory), so it
/// catches moved tags (hash mismatches), wasm the vendored web-tree-sitter can't load, and queries that don't compile.
@Suite struct GrammarTests {
    /// A snippet per language, a token in it, and the capture it should get (or a parent of it).
    static let samples: [SyntaxLanguage: (code: String, token: String, capture: String)] = [
        .bash: ("echo \"$HOME\" # home", "# home", "comment"),
        .c: ("int main(void) { return 0; }", "return", "keyword"),
        .cpp: ("class A { public: int x; };", "class", "keyword"),
        .csharp: ("public class A { void M() { var x = 1; } }", "class", "keyword"),
        .css: ("p { color: red; }", "color", "property"),
        .elixir: ("defmodule A do\n  def f(x), do: x + 1\nend", "defmodule", "keyword"),
        .go: ("func main() { fmt.Println(\"hi\") }", "func", "keyword"),
        .haskell: ("main :: IO ()\nmain = putStrLn \"hi\"", "\"hi\"", "string"),
        .html: ("<p class=\"a\">hi</p>", "p", "tag"),
        .java: ("class A { void f() { return; } }", "class", "keyword"),
        .javascript: ("const a = 1", "const", "keyword"),
        .json: ("{\"a\": true}", "true", "constant"),
        .julia: ("function f(x)\n  return x + 1\nend", "function", "keyword"),
        .kotlin: ("fun main() { val x = 1 }", "fun", "keyword"),
        .lua: ("local function f(x) return x end", "local", "keyword"),
        .make: ("# build\nall: main.o\n\tcc -o app main.o", "# build", "comment"),
        .markdown: ("# Title\n", "Title", "text.title"),
        // `return` comes from the inherited C query.
        .objc: ("@interface A : NSObject\n@end\nint main(void) { return 0; }", "return", "keyword"),
        .ocaml: ("let x = 1 in x", "let", "keyword"),
        .perl: ("my $x = \"hi\";", "my", "keyword"),
        .php: ("<?php function f() { return 1; }", "function", "keyword"),
        .python: ("def f(): pass", "def", "keyword"),
        .r: ("f <- function(x) x + 1", "function", "keyword"),
        .ruby: ("def f; end", "def", "keyword"),
        .rust: ("fn main() {}", "fn", "keyword"),
        .scala: ("object A { def f(x: Int) = x }", "object", "keyword"),
        .swift: ("let x = 1", "let", "keyword"),
        .toml: ("[a]\nb = 1", "1", "number"),
        .tsx: ("const a = <div />", "div", "tag"),
        .typescript: ("let a: number = 1", "number", "type.builtin"),
        .xml: ("<a href=\"x\">t</a>", "a", "tag"),
        .yaml: ("a: true", "true", "boolean"),
        .zig: ("fn f() void {}", "fn", "keyword"),
    ]

    @Test func everyLanguageHasASample() {
        #expect(Set(SyntaxLanguage.allCases) == Set(Self.samples.keys))
    }

    @Test(arguments: SyntaxLanguage.allCases)
    func highlights(_ language: SyntaxLanguage) async throws {
        let sample = try #require(Self.samples[language])
        let utf16 = Array(sample.code.utf16)
        let spans = try await SyntaxHighlighter.spans(in: sample.code, language: language)
        let capture = spans.first { String(decoding: utf16[$0.range], as: UTF16.self) == sample.token }?.capture
        #expect(capture == sample.capture || capture?.hasPrefix(sample.capture + ".") == true,
                "\(sample.token) is \(capture ?? "not captured"); all: \(spans)")
        for (a, b) in zip(spans, spans.dropFirst()) { #expect(a.range.upperBound <= b.range.lowerBound) }
    }

    @Test func rejectsFilesThatDontMatchTheirHash() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "PaseoSyntaxTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wasm = directory.appending(path: "tree-sitter-x.wasm")
        try Data("not wasm".utf8).write(to: wasm)
        var grammar = Grammars.grammar(for: .xml)
        grammar.wasm = Grammar.File(url: wasm, sha256: String(repeating: "0", count: 64))
        let downloads = GrammarDownloads(directory: directory.appending(path: "Grammars"))
        await #expect(throws: GrammarDownloads.HashMismatch.self) { try await downloads.files(for: grammar) }
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "Grammars/\(grammar.cacheKey)").path))
    }
}
