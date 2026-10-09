import SwiftUI

/// Renders agent markdown: fenced code blocks as code, headings and lists line by line,
/// and inline markdown (bold, code, links) through `AttributedString`.
struct MarkdownText: View {
    let blocks: [Block]

    init(_ text: String) {
        blocks = Self.parse(text)
    }

    enum Block: Hashable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case code(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    Text(Self.inline(text)).textSelection(.enabled)
                case .heading(let level, let text):
                    Text(Self.inline(text))
                        .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                        .textSelection(.enabled)
                case .code(let code):
                    CodeBlock(text: code)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }
            if let match = trimmed.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
                flushParagraph()
                blocks.append(.heading(level: match.1.count, text: String(match.2)))
            } else if trimmed.isEmpty {
                flushParagraph()
            } else if let bullet = trimmed.firstMatch(of: /^[-*+]\s+(.*)$/) {
                paragraph.append(String(repeating: "  ", count: (line.count - line.drop(while: { $0 == " " }).count) / 2) + "• " + bullet.1)
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }
}
