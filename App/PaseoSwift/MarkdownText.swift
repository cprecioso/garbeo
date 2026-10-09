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
            .textual.structuredTextStyle(.gitHub)
            .textual.textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
