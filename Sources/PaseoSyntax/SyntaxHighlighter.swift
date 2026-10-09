import Foundation

/// A highlighted run of source: UTF-16 offsets and the tree-sitter capture name (`keyword`, `function.method`, …).
public struct SyntaxSpan: Sendable, Hashable {
    public var range: Range<Int>
    public var capture: String

    public init(range: Range<Int>, capture: String) {
        self.range = range
        self.capture = capture
    }
}

public enum SyntaxHighlighter {
    /// Highlight spans for `code`, sorted and non-overlapping, including embedded languages (HTML scripts, markdown
    /// fences, …). Throws if the language's grammar can't be downloaded or loaded.
    @concurrent public static func spans(in code: String, language: SyntaxLanguage) async throws -> [SyntaxSpan] {
        let length = code.utf16.count
        guard length > 0 else { return [] }
        // Some grammars need the final line terminated: markdown otherwise reads a closing fence as code.
        let source = code.hasSuffix("\n") ? code : code + "\n"
        let captures = try await WebHighlighter.shared.captures(in: source, grammar: Grammars.grammar(for: language))
        return paint(captures.compactMap { capture in
            guard !ignoredCaptures.contains(capture.name), !capture.name.hasPrefix("_") else { return nil }
            var capture = capture
            capture.end = min(capture.end, length)
            return capture.start < capture.end ? capture : nil
        }, length: length)
    }

    /// Captures that mark regions for other editor features rather than colors.
    private static let ignoredCaptures: Set<String> = ["spell", "nospell", "conceal"]

    struct Capture {
        var start: Int
        var end: Int
        var name: String
        var pattern: Int
        var depth: Int
    }

    /// Flattens nested captures the way tree-sitter-highlight does: injected layers over their hosts, inner nodes over
    /// the nodes containing them, and on the same node the later pattern wins.
    static func paint(_ captures: [Capture], length: Int) -> [SyntaxSpan] {
        let ordered = captures.sorted { a, b in
            if a.depth != b.depth { return a.depth < b.depth }
            if a.end - a.start != b.end - b.start { return a.end - a.start > b.end - b.start }
            return a.pattern < b.pattern
        }
        var owner = [Int32](repeating: -1, count: length)
        for (index, capture) in ordered.enumerated() {
            for offset in capture.start..<capture.end { owner[offset] = Int32(index) }
        }
        var spans: [SyntaxSpan] = []
        var start = 0
        while start < length {
            let index = owner[start]
            var end = start + 1
            while end < length, owner[end] == index { end += 1 }
            if index >= 0 {
                let name = ordered[Int(index)].name
                if let last = spans.last, last.range.upperBound == start, last.capture == name {
                    spans[spans.count - 1].range = last.range.lowerBound..<end
                } else {
                    spans.append(SyntaxSpan(range: start..<end, capture: name))
                }
            }
            start = end
        }
        return spans
    }
}
