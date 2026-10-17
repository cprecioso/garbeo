// Generates the credits for artwork and third-party software the app uses, with their licenses: Credits.rtf, which
// macOS shows in the About panel, and Settings.bundle, which shows them in the app's page of the iOS Settings app.
//
// Lists the Swift packages linked into the app (build tools and packages SwiftTerm only links off Apple platforms are
// left out), what esbuild bundles into `plugin-host.js` (the inputs in its metafile), web-tree-sitter, and the grammars
// in `Grammars.swift`. Update it along with any of them.
//
// Usage (from App/): mise run credits

import AppKit

struct Credit {
    var name: String
    var url: URL
    var license: License
    /// The copyright lines of the project's license.
    var copyright: String
    /// Anything else its license file asks to keep with it.
    var note: String?


    init(_ name: String, _ url: String, _ license: License, _ copyright: String, note: String? = nil) {
        self.name = name
        self.url = URL(string: url)!
        self.license = license
        self.copyright = copyright
        self.note = note
    }

    var licenseText: String {
        [copyright, note, license.text].compactMap { $0 }.joined(separator: "\n\n")
    }
}

enum License {
    case mit, isc, bsd3, apache2, unlicense, ccBy3

    var name: String {
        switch self {
        case .mit: "MIT"
        case .isc: "ISC"
        case .bsd3: "BSD-3-Clause"
        case .apache2: "Apache-2.0"
        case .unlicense: "Public domain"
        case .ccBy3: "CC BY 3.0"
        }
    }

    var text: String {
        switch self {
        case .mit:
            """
            Permission is hereby granted, free of charge, to any person obtaining a copy of this software and \
            associated documentation files (the "Software"), to deal in the Software without restriction, including \
            without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
            copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the \
            following conditions:

            The above copyright notice and this permission notice shall be included in all copies or substantial \
            portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT \
            LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO \
            EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER \
            IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR \
            THE USE OR OTHER DEALINGS IN THE SOFTWARE.
            """
        case .isc:
            """
            Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is \
            hereby granted, provided that the above copyright notice and this permission notice appear in all copies.

            THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE \
            INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE \
            FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS \
            OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING \
            OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
            """
        case .bsd3:
            """
            Redistribution and use in source and binary forms, with or without modification, are permitted provided \
            that the following conditions are met:

            • Redistributions of source code must retain the above copyright notice, this list of conditions and the \
            following disclaimer.

            • Redistributions in binary form must reproduce the above copyright notice, this list of conditions and \
            the following disclaimer in the documentation and/or other materials provided with the distribution.

            • Neither the name of the copyright holder nor the names of its contributors may be used to endorse or \
            promote products derived from this software without specific prior written permission.

            THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED \
            WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A \
            PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR \
            ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED \
            TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) \
            HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING \
            NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE \
            POSSIBILITY OF SUCH DAMAGE.
            """
        case .apache2:
            """
            Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in \
            compliance with the License. You may obtain a copy of the License at

            https://www.apache.org/licenses/LICENSE-2.0

            Unless required by applicable law or agreed to in writing, software distributed under the License is \
            distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. \
            See the License for the specific language governing permissions and limitations under the License.
            """
        case .unlicense:
            """
            This is free and unencumbered software released into the public domain. See https://unlicense.org.
            """
        case .ccBy3:
            """
            Licensed under the Creative Commons Attribution 3.0 license: \
            https://creativecommons.org/licenses/by/3.0/
            """
        }
    }
}

struct Grammar {
    var repository: String
    var license: License

    init(_ repository: String, _ license: License) {
        self.repository = repository
        self.license = license
    }

    var name: String { repository.components(separatedBy: "/").last! }
    var url: URL { URL(string: "https://github.com/\(repository)")! }
}

enum Credits {
    struct Category {
        var title: String
        var footer: String?
        var credits: [Credit]

    }

    private static let meta = "Copyright (c) Meta Platforms, Inc. and affiliates."

    static let sections = [
        Category(title: "App icon", footer: "Garbeo's icon is based on “Running”, created by Cuputo from Noun Project.", credits: [
            Credit("Running", "https://thenounproject.com/icon/running-8375653/", .ccBy3, "Created by Cuputo from Noun Project"),
        ]),
        Category(title: "Paseo", credits: [
            Credit(
                "Paseo", "https://github.com/getpaseo/paseo", .apache2, "Copyright (c) 2025-present Mohamed Boudra",
                note: "The plugin host includes Paseo's client, plugin, protocol and relay packages."),
        ]),
        Category(title: "Swift packages", credits: [
            Credit("Bonsplit", "https://github.com/almonk/bonsplit", .mit, "Copyright (c) Alasdair Monk"),
            Credit("CommandPaletteKit", "https://github.com/adamtheturtle/CommandPaletteKit", .mit, "Copyright (c) 2026 Adam Dangoor"),
            Credit("libsodium", "https://github.com/jedisct1/libsodium", .isc, "Copyright (c) 2013-2026 Frank Denis <j at pureftpd dot org>"),
            Credit("swift-concurrency-extras", "https://github.com/pointfreeco/swift-concurrency-extras", .mit, "Copyright (c) 2023 Point-Free"),
            Credit("swift-sodium", "https://github.com/jedisct1/swift-sodium", .isc, "Copyright (c) 2014-2026, Frank Denis <j at pureftpd dot org>"),
            Credit(
                "SwiftTerm", "https://github.com/migueldeicaza/SwiftTerm", .mit,
                """
                Copyright (c) 2019-2026 Miguel de Icaza (https://github.com/migueldeicaza)
                Copyright (c) 2017-2019, The xterm.js authors (https://github.com/xtermjs/xterm.js)
                Copyright (c) 2014-2016, SourceLair Private Company (https://www.sourcelair.com)
                Copyright (c) 2012-2013, Christopher Jeffrey (https://github.com/chjj/)
                """),
            Credit(
                "SwiftUIMath", "https://github.com/gonzalezreal/swiftui-math", .mit,
                """
                Copyright (c) 2026 Guille Gonzalez
                Copyright (c) 2023 Computer Inspirations (SwiftMath)
                Copyright (c) 2013 MathChat (iosMath)
                """,
                note: "Its math fonts ship with their own licenses (SIL Open Font License, GUST Font License)."),
            Credit("Textual", "https://github.com/gonzalezreal/textual", .mit, "Copyright (c) 2024 Guille Gonzalez"),
        ]),
        Category(title: "Plugin host", footer: "Bundled into the JavaScript runtime that runs Paseo plugins.", credits: [
            Credit("@babel/runtime", "https://github.com/babel/babel", .mit, "Copyright (c) 2014-present Sebastian McKenzie and other contributors"),
            Credit("@react-native/normalize-colors", "https://github.com/facebook/react-native", .mit, meta),
            Credit("base64-js", "https://github.com/beatgammit/base64-js", .mit, "Copyright (c) 2014 Jameson Little"),
            Credit("css-in-js-utils", "https://github.com/robinweser/css-in-js-utils", .mit, "Copyright (c) 2017 Robin Frischmann"),
            Credit("fbjs", "https://github.com/facebook/fbjs", .mit, "Copyright (c) 2013-present, Facebook, Inc."),
            Credit("hyphenate-style-name", "https://github.com/rexxars/hyphenate-style-name", .bsd3, "Copyright (c) 2015, Espen Hovlandsdal\nAll rights reserved."),
            Credit("inline-style-prefixer", "https://github.com/robinweser/inline-style-prefixer", .mit, "Copyright (c) 2015 Robin Frischmann"),
            Credit(
                "Lucide", "https://github.com/lucide-icons/lucide", .isc, "Copyright (c) 2026 Lucide Icons and Contributors",
                note: "Icons derived from Feather (https://github.com/feathericons/feather) are licensed under the MIT License, Copyright (c) 2013-present Cole Bemis."),
            Credit("memoize-one", "https://github.com/alexreardon/memoize-one", .mit, "Copyright (c) 2019 Alexander Reardon"),
            Credit("nullthrows", "https://github.com/zertosh/nullthrows", .mit, "Copyright (c) 2016 Andres Suarez"),
            Credit("React", "https://github.com/facebook/react", .mit, meta, note: "Includes react, react-dom, scheduler and use-sync-external-store."),
            Credit("React Native for Web", "https://github.com/necolas/react-native-web", .mit, "Copyright (c) Nicolas Gallagher.\n\(meta)"),
            Credit("styleq", "https://github.com/necolas/styleq", .mit, "Copyright (c) Nicolas Gallagher"),
            Credit("TanStack Query", "https://github.com/TanStack/query", .mit, "Copyright (c) 2021-present Tanner Linsley"),
            Credit("TweetNaCl.js", "https://github.com/dchest/tweetnacl-js", .unlicense, "Written by the TweetNaCl.js contributors"),
            Credit("Zod", "https://github.com/colinhacks/zod", .mit, "Copyright (c) 2025 Colin McDonnell"),
        ]),
        Category(title: "Syntax highlighting", credits: [
            Credit("web-tree-sitter", "https://github.com/tree-sitter/tree-sitter", .mit, "Copyright (c) 2018 Max Brunsfeld"),
        ]),
    ]

    static let grammarsFooter = "Downloaded from each grammar's repository the first time a language is highlighted."

    static let grammars: [Grammar] = [
        Grammar("tree-sitter/tree-sitter-bash", .mit),
        Grammar("tree-sitter/tree-sitter-c", .mit),
        Grammar("tree-sitter/tree-sitter-c-sharp", .mit),
        Grammar("tree-sitter/tree-sitter-cpp", .mit),
        Grammar("tree-sitter/tree-sitter-css", .mit),
        Grammar("elixir-lang/tree-sitter-elixir", .apache2),
        Grammar("tree-sitter/tree-sitter-go", .mit),
        Grammar("tree-sitter/tree-sitter-haskell", .mit),
        Grammar("tree-sitter/tree-sitter-html", .mit),
        Grammar("tree-sitter/tree-sitter-java", .mit),
        Grammar("tree-sitter/tree-sitter-javascript", .mit),
        Grammar("tree-sitter/tree-sitter-json", .mit),
        Grammar("tree-sitter/tree-sitter-julia", .mit),
        Grammar("fwcd/tree-sitter-kotlin", .mit),
        Grammar("tree-sitter-grammars/tree-sitter-lua", .mit),
        Grammar("tree-sitter-grammars/tree-sitter-make", .mit),
        Grammar("tree-sitter-grammars/tree-sitter-markdown", .mit),
        Grammar("tree-sitter-grammars/tree-sitter-objc", .mit),
        Grammar("tree-sitter/tree-sitter-ocaml", .mit),
        Grammar("tree-sitter-perl/tree-sitter-perl", .mit),
        Grammar("tree-sitter/tree-sitter-php", .mit),
        Grammar("tree-sitter/tree-sitter-python", .mit),
        Grammar("r-lib/tree-sitter-r", .mit),
        Grammar("tree-sitter/tree-sitter-ruby", .mit),
        Grammar("tree-sitter/tree-sitter-rust", .mit),
        Grammar("tree-sitter/tree-sitter-scala", .mit),
        Grammar("alex-pinkus/tree-sitter-swift", .mit),
        Grammar("tree-sitter-grammars/tree-sitter-toml", .mit),
        Grammar("tree-sitter/tree-sitter-typescript", .mit),
        Grammar("tree-sitter-grammars/tree-sitter-xml", .mit),
        Grammar("tree-sitter-grammars/tree-sitter-yaml", .mit),
        Grammar("tree-sitter-grammars/tree-sitter-zig", .mit),
    ]
}

let resources = URL(fileURLWithPath: CommandLine.arguments[1])
let fileManager = FileManager.default

// MARK: Credits.rtf

let rtf = NSMutableAttributedString()

func paragraph(_ string: String, font: NSFont = .systemFont(ofSize: 11), link: URL? = nil,
               alignment: NSTextAlignment = .center, spacingBefore: CGFloat = 0)
{
    let style = NSMutableParagraphStyle()
    style.alignment = alignment
    style.paragraphSpacingBefore = spacingBefore
    var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style]
    if rtf.length > 0 { rtf.append(NSAttributedString(string: "\n", attributes: attributes)) }
    attributes[.link] = link
    rtf.append(NSAttributedString(string: string, attributes: attributes))
}

func heading(_ title: String, footer: String? = nil) {
    paragraph(title, font: .boldSystemFont(ofSize: 12), spacingBefore: rtf.length == 0 ? 0 : 14)
    if let footer { paragraph(footer) }
}

for section in Credits.sections {
    heading(section.title, footer: section.footer)
    for credit in section.credits {
        paragraph("\(credit.name) (\(credit.license.name))", font: .boldSystemFont(ofSize: 11), link: credit.url, spacingBefore: 6)
        paragraph(credit.copyright)
        if let note = credit.note { paragraph(note) }
    }
}

heading("Syntax grammars", footer: Credits.grammarsFooter)
for grammar in Credits.grammars {
    paragraph("\(grammar.name) (\(grammar.license.name))", link: grammar.url, spacingBefore: 2)
}

heading("Licenses")
var seen = Set<License>()
let licenses = (Credits.sections.flatMap { $0.credits.map(\.license) } + Credits.grammars.map(\.license))
    .filter { seen.insert($0).inserted }
for license in licenses {
    paragraph(license.name, font: .boldSystemFont(ofSize: 11), spacingBefore: 8)
    paragraph(license.text, font: .systemFont(ofSize: 10), alignment: .natural)
}

// The RTF writer swaps the system font for Helvetica Neue; name it the way TextEdit does so it stays the system font.
let rtfData = rtf.rtf(from: NSRange(location: 0, length: rtf.length))!
try String(decoding: rtfData, as: UTF8.self)
    .replacing(#/HelveticaNeue(-Bold)?;/#, with: ".AppleSystemUIFont;")
    .write(to: resources.appending(path: "Credits.rtf"), atomically: true, encoding: .utf8)

// MARK: Settings.bundle

let bundle = resources.appending(path: "Settings.bundle")
try? fileManager.removeItem(at: bundle)
try fileManager.createDirectory(at: bundle.appending(path: "Credits"), withIntermediateDirectories: true)

func writePane(_ name: String, title: String? = nil, _ specifiers: [[String: String]]) throws {
    var plist: [String: Any] = ["PreferenceSpecifiers": specifiers]
    plist["Title"] = title
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: bundle.appending(path: "\(name).plist"))
}

try writePane("Root", [
    ["Type": "PSGroupSpecifier"],
    ["Type": "PSChildPaneSpecifier", "Title": "Credits", "File": "Credits"],
])

var specifiers: [[String: String]] = []
for section in Credits.sections {
    var group = ["Type": "PSGroupSpecifier", "Title": section.title]
    group["FooterText"] = section.footer
    specifiers.append(group)
    for credit in section.credits {
        let file = "Credits/" + credit.name.lowercased()
            .replacing(#/[^a-z0-9]+/#, with: "-")
            .trimmingCharacters(in: ["-"])
        specifiers.append(["Type": "PSChildPaneSpecifier", "Title": credit.name, "File": file])
        try writePane(file, title: credit.name, [
            ["Type": "PSGroupSpecifier", "Title": credit.license.name, "FooterText": credit.licenseText],
        ])
    }
}

specifiers.append(["Type": "PSGroupSpecifier", "Title": "Syntax grammars", "FooterText": Credits.grammarsFooter])
for grammar in Credits.grammars {
    specifiers.append([
        "Type": "PSTitleValueSpecifier", "Key": "credits.grammar.\(grammar.repository)",
        "Title": grammar.name, "DefaultValue": grammar.license.name,
    ])
}
try writePane("Credits", title: "Credits", specifiers)
