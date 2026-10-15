import Foundation

/// A language tree-sitter can highlight, with a grammar in `Grammars`.
public enum SyntaxLanguage: String, CaseIterable, Sendable {
    case bash, c, cpp, csharp, css, elixir, go, haskell, html, java, javascript, json, julia, kotlin, lua, make, markdown
    case objc, ocaml, perl, php, python, r, ruby, rust, scala, swift, toml, tsx, typescript, xml, yaml, zig

    /// The language of a file, from its name or extension.
    public init?(path: String) {
        let name = (path as NSString).lastPathComponent
        if let language = Self.fileNames[name] ?? Self.extensions[(name as NSString).pathExtension.lowercased()] {
            self = language
        } else {
            return nil
        }
    }

    /// The language named by a markdown fence's info string (`ts`, `sh`, `c++`, `rust,ignore`, …).
    public init?(name: String) {
        let word = name.prefix { !$0.isWhitespace && $0 != "," && $0 != "{" }.lowercased()
        guard let language = Self(rawValue: word) ?? Self.aliases[word] ?? Self.extensions[word] else { return nil }
        self = language
    }

    private static let extensions: [String: SyntaxLanguage] = [
        "sh": .bash, "bash": .bash, "zsh": .bash, "ksh": .bash, "bats": .bash,
        "c": .c, "h": .c,
        "cc": .cpp, "cpp": .cpp, "cxx": .cpp, "c++": .cpp, "hh": .cpp, "hpp": .cpp, "hxx": .cpp, "ipp": .cpp,
        "cs": .csharp, "csx": .csharp,
        "css": .css,
        "ex": .elixir, "exs": .elixir,
        "go": .go,
        "hs": .haskell,
        "html": .html, "htm": .html, "xhtml": .html,
        "java": .java,
        "js": .javascript, "mjs": .javascript, "cjs": .javascript, "jsx": .javascript,
        "json": .json, "jsonc": .json, "webmanifest": .json,
        "jl": .julia,
        "kt": .kotlin, "kts": .kotlin,
        "lua": .lua,
        "mk": .make, "mak": .make,
        "md": .markdown, "markdown": .markdown,
        "m": .objc,
        "ml": .ocaml,
        "pl": .perl, "pm": .perl,
        "php": .php,
        "py": .python, "pyi": .python, "pyw": .python,
        "r": .r,
        "rb": .ruby, "rake": .ruby, "gemspec": .ruby, "ru": .ruby,
        "rs": .rust,
        "scala": .scala, "sbt": .scala, "sc": .scala,
        "swift": .swift,
        "toml": .toml,
        "tsx": .tsx,
        "ts": .typescript, "mts": .typescript, "cts": .typescript,
        "xml": .xml, "svg": .xml, "xsd": .xml, "xsl": .xml, "xslt": .xml,
        "plist": .xml, "entitlements": .xml, "storyboard": .xml, "xib": .xml,
        "yml": .yaml, "yaml": .yaml,
        "zig": .zig,
    ]

    private static let fileNames: [String: SyntaxLanguage] = [
        ".bashrc": .bash, ".bash_profile": .bash, ".profile": .bash, ".zshrc": .bash, ".zprofile": .bash, ".zshenv": .bash, ".envrc": .bash,
        "Gemfile": .ruby, "Rakefile": .ruby, "Podfile": .ruby, "Fastfile": .ruby, "Brewfile": .ruby, "Vagrantfile": .ruby,
        "Cargo.lock": .toml, "Pipfile": .toml, "uv.lock": .toml, "poetry.lock": .toml,
        "Makefile": .make, "makefile": .make, "GNUmakefile": .make,
    ]

    private static let aliases: [String: SyntaxLanguage] = [
        "shell": .bash, "shellscript": .bash,
        "c#": .csharp,
        "golang": .go,
        "javascriptreact": .javascript, "node": .javascript,
        "makefile": .make,
        "objective-c": .objc, "objectivec": .objc, "obj-c": .objc,
        "python3": .python,
        "typescriptreact": .tsx,
    ]
}
