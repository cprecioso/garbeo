import Foundation

/// A unified diff, or a bare `+`/`-`/` ` line diff, split into lines with their code highlighted. The old and new
/// sides are highlighted separately so each parses as the code it came from.
public struct SyntaxDiff: Sendable, Hashable {
    public struct Line: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            case context, added, removed
            /// `@@ -1,2 +1,3 @@`
            case hunk
            /// File headers (`diff --git`, `---`, `+++`, …), `\ No newline at end of file`, and lines that aren't diff
            /// lines at all.
            case header
        }

        public var kind: Kind
        /// The line without its `+`/`-`/` ` marker. Hunk and header lines are kept whole.
        public var text: String
        /// Highlight spans within `text`.
        public var spans: [SyntaxSpan] = []
    }

    public var lines: [Line]

    /// The diff's lines, without syntax highlighting.
    public init(_ diff: String) {
        var raw = diff.split(separator: "\n", omittingEmptySubsequences: false)
        if raw.count > 1, raw.last?.isEmpty == true { raw.removeLast() }
        // Without hunk headers every line is code; otherwise everything before the first hunk is a file header.
        var inHunk = !raw.contains { $0.hasPrefix("@@") }
        lines = raw.map { line in
            let kind: Line.Kind
            if line.hasPrefix("@@") {
                kind = .hunk
                inHunk = true
            } else if line.hasPrefix("diff ") {
                kind = .header
                inHunk = false
            } else if !inHunk {
                kind = .header
            } else if line.hasPrefix("+") {
                kind = .added
            } else if line.hasPrefix("-") {
                kind = .removed
            } else if line.hasPrefix(" ") || line.isEmpty {
                kind = .context
            } else {
                kind = .header
            }
            guard kind != .hunk, kind != .header else { return Line(kind: kind, text: String(line)) }
            return Line(kind: kind, text: String(line.dropFirst()))
        }
    }

    /// The diff's lines with their code highlighted. Throws if the language's grammar can't be loaded.
    public init(_ diff: String, language: SyntaxLanguage) async throws {
        self.init(diff)
        let old = Side(lines, keeping: [.context, .removed]), new = Side(lines, keeping: [.context, .added])
        async let newSpans = SyntaxHighlighter.spans(in: new.source, language: language)
        async let oldSpans = SyntaxHighlighter.spans(in: old.source, language: language)
        assign(try await newSpans, from: new)
        assign(try await oldSpans, from: old, skipping: .context)
    }

    /// The code on one side of the diff, and where each of its diff lines starts in it.
    private struct Side {
        var source = ""
        var length = 0
        var lines: [(index: Int, start: Int, length: Int)] = []

        init(_ diffLines: [Line], keeping kinds: Set<Line.Kind>) {
            for (index, line) in diffLines.enumerated() where kinds.contains(line.kind) {
                if !lines.isEmpty {
                    source += "\n"
                    length += 1
                }
                let count = line.text.utf16.count
                lines.append((index, length, count))
                source += line.text
                length += count
            }
        }
    }

    /// Splits spans of a side's source onto its lines.
    private mutating func assign(_ spans: [SyntaxSpan], from side: Side, skipping skipped: Line.Kind? = nil) {
        var first = 0
        for line in side.lines where lines[line.index].kind != skipped {
            let end = line.start + line.length
            while first < spans.count, spans[first].range.upperBound <= line.start { first += 1 }
            var lineSpans: [SyntaxSpan] = []
            var next = first
            while next < spans.count, spans[next].range.lowerBound < end {
                let span = spans[next]
                let lower = max(span.range.lowerBound, line.start), upper = min(span.range.upperBound, end)
                if lower < upper {
                    lineSpans.append(SyntaxSpan(range: (lower - line.start)..<(upper - line.start), capture: span.capture))
                }
                next += 1
            }
            lines[line.index].spans = lineSpans
        }
    }
}
