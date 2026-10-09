import PaseoSyntax
import SwiftUI

/// Monospaced code in a horizontally scrolling box, highlighted with tree-sitter when `language` is known. Diffs get
/// GitHub-style line backgrounds, and their code is highlighted too.
struct CodeBlock: View {
    let text: String
    var isDiff = false
    var language: SyntaxLanguage?
    @State private var highlighted: CodeRendering?
    @State private var width: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal) {
            Group {
                switch highlighted ?? CodeRendering(plain: request) {
                case .code(let code):
                    Text(code).padding(10)
                case .diff(let rows):
                    Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                Text(row.text)
                                    .padding(.horizontal, 10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(background(row.kind))
                            }
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .frame(minWidth: width, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .frame(maxHeight: 360)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: request) {
            // Without syntax colors after all, diff lines take their markers' colors.
            highlighted = await CodeRendering.highlighted(request) ?? CodeRendering(plain: .init(text: text, isDiff: isDiff))
        }
    }

    private var request: CodeRendering.Request {
        .init(text: text, isDiff: isDiff, language: language)
    }

    private func background(_ kind: SyntaxDiff.Line.Kind) -> Color {
        switch kind {
        case .added: SyntaxTheme.gitHub.addedBackground
        case .removed: SyntaxTheme.gitHub.removedBackground
        default: .clear
        }
    }
}

/// Code or a diff turned into styled text. Highlighting runs off the main actor and is cached by content, so
/// scrolling a timeline back over a block doesn't redo it.
enum CodeRendering: Sendable {
    case code(AttributedString)
    case diff([DiffRow])

    struct DiffRow: Sendable {
        var kind: SyntaxDiff.Line.Kind
        var text: AttributedString
    }

    struct Request: Hashable, Sendable {
        var text: String
        var isDiff = false
        var language: SyntaxLanguage?
    }

    /// Without syntax colors, for the moment before highlighting finishes (or if it fails).
    init(plain request: Request) {
        if request.isDiff {
            self.init(SyntaxDiff(request.text), coloringLines: request.language == nil)
        } else {
            self = .code(AttributedString(request.text))
        }
    }

    /// One string for the whole block (diff lines lose their backgrounds).
    var attributedString: AttributedString {
        switch self {
        case .code(let code): return code
        case .diff(let rows):
            var string = AttributedString()
            for (index, row) in rows.enumerated() {
                if index > 0 { string += "\n" }
                string += row.text
            }
            return string
        }
    }

    /// Nil if the language's grammar can't be loaded (a download failed, say). Not cached then, so a later attempt
    /// can succeed.
    @concurrent static func highlighted(_ request: Request) async -> CodeRendering? {
        guard let language = request.language else { return CodeRendering(plain: request) }
        let key = Key(request)
        if let cached = cache.object(forKey: key) { return cached.rendering }
        let rendering: CodeRendering
        do {
            if request.isDiff {
                rendering = CodeRendering(try await SyntaxDiff(request.text, language: language), coloringLines: false)
            } else {
                let spans = try await SyntaxHighlighter.spans(in: request.text, language: language)
                rendering = .code(SyntaxTheme.gitHub.attributedString(request.text, spans: spans))
            }
        } catch {
            return nil
        }
        cache.setObject(Entry(rendering), forKey: key)
        return rendering
    }

    /// `coloringLines` gives a whole line its marker's color, for diffs that won't get syntax colors.
    private init(_ diff: SyntaxDiff, coloringLines: Bool) {
        let theme = SyntaxTheme.gitHub
        self = .diff(diff.lines.map { line in
            var text: AttributedString
            switch line.kind {
            case .added, .removed, .context:
                let color = line.kind == .added ? theme.added : line.kind == .removed ? theme.removed : nil
                text = AttributedString(line.kind == .added ? "+" : line.kind == .removed ? "-" : " ")
                text.swiftUI.foregroundColor = color
                if coloringLines {
                    text += AttributedString(line.text)
                    text.swiftUI.foregroundColor = color
                } else {
                    text += theme.attributedString(line.text, spans: line.spans)
                }
            case .hunk:
                text = AttributedString(line.text)
                text.swiftUI.foregroundColor = theme.hunk
            case .header:
                text = AttributedString(line.text)
                text.swiftUI.foregroundColor = .secondary
            }
            return DiffRow(kind: line.kind, text: text)
        })
    }

    private final class Key: NSObject {
        let request: Request

        init(_ request: Request) {
            self.request = request
        }

        override var hash: Int { request.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? Key)?.request == request }
    }

    private final class Entry {
        let rendering: CodeRendering

        init(_ rendering: CodeRendering) {
            self.rendering = rendering
        }
    }

    private nonisolated(unsafe) static let cache: NSCache<Key, Entry> = {
        let cache = NSCache<Key, Entry>()
        cache.countLimit = 200
        return cache
    }()
}
