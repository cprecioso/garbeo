import SwiftUI

/// Colors for tree-sitter captures, after GitHub's syntax palette (Primer "prettylights"), in light and dark.
public struct SyntaxTheme: Sendable {
    public struct Style: Sendable, Hashable {
        /// Nil keeps the surrounding text color.
        public var color: Color?
        public var bold = false
        public var italic = false
        public var underline = false
    }

    public var styles: [String: Style]
    /// Diff markers, line backgrounds and `@@` lines.
    public var added: Color
    public var removed: Color
    public var addedBackground: Color
    public var removedBackground: Color
    public var hunk: Color

    /// The style for a capture, falling back to its parents (`function.method.builtin` → `function.method` →
    /// `function`). Nil if no level is styled.
    public func style(for capture: String) -> Style? {
        var name = Substring(capture)
        while true {
            if let style = styles[String(name)] { return style }
            guard let dot = name.lastIndex(of: ".") else { return nil }
            name = name[..<dot]
        }
    }

    /// `text` with `spans` (UTF-16 offsets, sorted and non-overlapping) styled.
    public func attributedString(_ text: String, spans: [SyntaxSpan]) -> AttributedString {
        var result = AttributedString()
        let scalars = text.unicodeScalars
        var index = text.startIndex, offset = 0
        for span in spans {
            guard let style = style(for: span.capture) else { continue }
            let start = text.utf16.index(index, offsetBy: span.range.lowerBound - offset)
            let end = text.utf16.index(start, offsetBy: span.range.count)
            if index < start { result.append(AttributedString(String(scalars[index..<start]))) }
            var piece = AttributedString(String(scalars[start..<end]))
            if let color = style.color { piece.swiftUI.foregroundColor = color }
            var intent: InlinePresentationIntent = []
            if style.bold { intent.insert(.stronglyEmphasized) }
            if style.italic { intent.insert(.emphasized) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if style.underline { piece.swiftUI.underlineStyle = .single }
            result.append(piece)
            index = end
            offset = span.range.upperBound
        }
        if index < text.endIndex { result.append(AttributedString(String(scalars[index...]))) }
        return result
    }
}

extension SyntaxTheme {
    public static let gitHub: SyntaxTheme = {
        let keyword = Style(color: Color(light: 0xCF222E, dark: 0xFF7B72))
        let comment = Style(color: Color(light: 0x59636E, dark: 0x9198A1))
        let constant = Style(color: Color(light: 0x0550AE, dark: 0x79C0FF))
        let entity = Style(color: Color(light: 0x6639BA, dark: 0xD2A8FF))
        let tag = Style(color: Color(light: 0x116329, dark: 0x7EE787))
        let string = Style(color: Color(light: 0x0A3069, dark: 0xA5D6FF))
        let type = Style(color: Color(light: 0x953800, dark: 0xFFA657))
        let plain = Style()
        return SyntaxTheme(
            styles: [
                "keyword": keyword, "operator": keyword, "conditional": keyword, "repeat": keyword, "include": keyword,
                "exception": keyword, "storageclass": keyword, "punctuation.special": keyword,
                "charset": keyword, "import": keyword, "keyframes": keyword, "media": keyword, "supports": keyword,
                "comment": comment,
                "constant": constant, "number": constant, "float": constant, "boolean": constant,
                "escape": constant, "string.escape": constant, "character.special": constant,
                "string.special.symbol": constant, "variable.builtin": constant,
                "property": constant, "field": constant, "variable.member": constant,
                "function": entity, "method": entity, "attribute": entity, "tag.attribute": entity,
                "tag": tag, "string.regexp": tag, "string.regex": tag, "string.special.regex": tag,
                "string.special.key": tag,
                "string": string, "character": string,
                "type": type, "constructor": type, "namespace": type, "module": type,
                "variable": plain, "punctuation": plain, "label": plain, "embedded": plain, "none": plain,
                "tag.delimiter": plain, "tag.error": plain,
                // Markdown, in both the older `text.*` and current `markup.*` names.
                "text.title": Style(color: constant.color, bold: true),
                "markup.heading": Style(color: constant.color, bold: true),
                "text.literal": string, "markup.raw": string,
                "text.uri": Style(color: string.color, underline: true),
                "markup.link.url": Style(color: string.color, underline: true),
                "text.reference": constant, "markup.link": constant,
                "text.emphasis": Style(italic: true), "markup.italic": Style(italic: true),
                "text.strong": Style(bold: true), "markup.strong": Style(bold: true),
                "markup.list": keyword,
            ],
            added: Color(light: 0x1A7F37, dark: 0x3FB950),
            removed: Color(light: 0xCF222E, dark: 0xF85149),
            addedBackground: Color(light: 0x2DA44E, dark: 0x2EA043).opacity(0.15),
            removedBackground: Color(light: 0xCF222E, dark: 0xF85149).opacity(0.15),
            hunk: Color(light: 0x8250DF, dark: 0xD2A8FF)
        )
    }()
}

extension Color {
    /// A color that follows the light/dark appearance it's drawn in.
    init(light: UInt32, dark: UInt32) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(rgb: dark) : NSColor(rgb: light)
        })
        #endif
    }
}

#if canImport(UIKit)
private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#else
private extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#endif
