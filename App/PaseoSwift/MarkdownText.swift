import PaseoSyntax
import SwiftUI
import Textual

/// Renders agent markdown with Textual: full CommonMark + GFM tables, syntax-highlighted
/// code blocks, and native text selection.
struct MarkdownText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        StructuredText(markdown: text)
            // Closer to the view than the GitHub style, so it replaces that style's code blocks.
            .textual.codeBlockStyle(SyntaxCodeBlockStyle())
            .textual.structuredTextStyle(.gitHub)
            .textual.textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Textual's GitHub code block, highlighted with tree-sitter (`diff` fences get the tool call diff colors). Fences in
/// languages without a grammar here, or whose grammar can't be downloaded, keep Textual's own (Prism) highlighting.
private struct SyntaxCodeBlockStyle: StructuredText.CodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        SyntaxCodeBlock(configuration: configuration)
    }
}

private struct SyntaxCodeBlock: View {
    let configuration: StructuredText.CodeBlockStyleConfiguration
    @State private var highlighted: AttributedString?
    @State private var unavailable = false

    var body: some View {
        Overflow {
            label
                .textual.lineSpacing(.fontScaled(0.225))
                .textual.fontScale(0.85)
                .fixedSize(horizontal: false, vertical: true)
                .monospaced()
                .padding(16)
        }
        .background(DynamicColor(
            light: Color(red: 247 / 255, green: 247 / 255, blue: 249 / 255),
            dark: Color(red: 37 / 255, green: 38 / 255, blue: 42 / 255)
        ))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .textual.blockSpacing(.init(top: 0, bottom: 16))
        .task(id: request) {
            guard let request else { return }
            let rendering = await CodeRendering.highlighted(request)
            highlighted = rendering?.attributedString
            unavailable = rendering == nil
        }
    }

    @ViewBuilder private var label: some View {
        if let request, !unavailable {
            // Rendered through Textual so it takes part in the document's text selection.
            InlineText(request.text, parser: Prehighlighted(string: highlighted))
                .id(highlighted != nil)
        } else {
            configuration.label
        }
    }

    private var request: CodeRendering.Request? {
        guard let hint = configuration.languageHint, let code = configuration.codeBlock.code else { return nil }
        if hint == "diff" || hint == "patch" { return CodeRendering.Request(text: code, isDiff: true) }
        guard let language = SyntaxLanguage(name: hint) else { return nil }
        return CodeRendering.Request(text: code, language: language)
    }
}

/// Hands `InlineText` text that's already styled, or the plain code until it is.
private struct Prehighlighted: MarkupParser {
    let string: AttributedString?

    func attributedString(for input: String) throws -> AttributedString {
        string ?? AttributedString(input)
    }
}

extension StructuredText.CodeBlockProxy {
    /// The block's code. Textual keeps it private, so this reads it reflectively; nil if a Textual update renames it,
    /// which leaves Textual's own highlighting in place.
    fileprivate var code: String? {
        (Mirror(reflecting: self).descendant("content") as? AttributedSubstring).map { String($0.characters) }
    }
}
