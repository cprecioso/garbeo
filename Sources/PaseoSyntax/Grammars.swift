import CryptoKit
import Foundation

/// A tree-sitter grammar: its parser compiled to wasm, from the grammar's GitHub release, plus its query files from
/// the repository. Downloaded on first use. Every file is pinned by SHA-256, so a moved tag or a tampered download
/// is rejected.
struct Grammar: Sendable {
    struct File: Sendable {
        var url: URL
        var sha256: String
    }

    /// A grammar repository at a release tag.
    struct Repository {
        var name: String
        var tag: String

        init(_ name: String, _ tag: String) {
            self.name = name
            self.tag = tag
        }

        func release(_ asset: String, _ sha256: String) -> File {
            File(url: URL(string: "https://github.com/\(name)/releases/download/\(tag)/\(asset)")!, sha256: sha256)
        }

        func file(_ path: String, _ sha256: String) -> File {
            File(url: URL(string: "https://raw.githubusercontent.com/\(name)/\(tag)/\(path)")!, sha256: sha256)
        }
    }

    /// The parser's name (`typescript`, `markdown_inline`, …).
    var name: String
    var wasm: File
    /// Query files, each kind concatenated in order. Later patterns win (see `SyntaxHighlighter.paint`), so queries
    /// inherited from a base grammar come first.
    var highlights: [File]
    var injections: [File] = []

    /// `tree-sitter-<name>.wasm` from `repository`'s release.
    init(_ repository: Repository, _ name: String, _ wasmHash: String, highlights: [File], injections: [File] = []) {
        self.name = name
        wasm = repository.release("tree-sitter-\(name).wasm", wasmHash)
        self.highlights = highlights
        self.injections = injections
    }

    /// Changes with any of the files, so an updated grammar is downloaded afresh.
    var cacheKey: String {
        let hashes = [wasm.sha256] + highlights.map(\.sha256) + ["|"] + injections.map(\.sha256)
        let digest = SHA256.hash(data: Data(hashes.joined(separator: " ").utf8))
        return "\(name)-" + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

enum Grammars {
    /// The grammar for a language. Only grammars whose releases include a `.wasm` qualify.
    static func grammar(for language: SyntaxLanguage) -> Grammar {
        let highlights = "queries/highlights.scm", injections = "queries/injections.scm"
        let c = Repository("tree-sitter/tree-sitter-c", "v0.24.2")
        let cHighlights = c.file(highlights, "3378d854dda695b2b282b9468247524ed4271ef74af691033d2e36883379409c")
        // TypeScript builds on JavaScript's queries (it expects 0.23.1's, which are the same files).
        let js = Repository("tree-sitter/tree-sitter-javascript", "v0.25.0")
        let jsHighlights = js.file(highlights, "d3630ae6dc9b2b27b230b5f8bb92b05cd491fb12bff353dae62a0a6d780461ee")
        let jsxHighlights = js.file("queries/highlights-jsx.scm", "0cad1712acaf40804bc5dc7c8476858752c1f549cdf7d8c63c747317be0f8fa6")
        let jsInjections = js.file(injections, "bea345407ce1f24bccf2b3c1a128acc14e19301327074285368586e793dcb86d")
        let ts = Repository("tree-sitter/tree-sitter-typescript", "v0.23.2")
        let tsHighlights = ts.file(highlights, "e0c35adb819127bfd4f853fac5419e7d8ba44760246201d04a4a5ce0228a10c5")
        switch language {
        case .bash:
            let repository = Repository("tree-sitter/tree-sitter-bash", "v0.25.1")
            return Grammar(repository, "bash", "8292919c88a0f7d3fb31d0cd0253ca5a9531bc1ede82b0537f2c63dd8abe6a7a",
                           highlights: [repository.file(highlights, "b74220d954f485b7626d2b2b61f37b522e12eb1830803e388e57dd797dc99f11")])
        case .c:
            return Grammar(c, "c", "83e8d7902b9d7f8c7c5cd4bd9acb5c7eb5faf42c09f85546b183964d3b5f48f9", highlights: [cHighlights])
        case .cpp:
            let repository = Repository("tree-sitter/tree-sitter-cpp", "v0.23.4")
            return Grammar(repository, "cpp", "174eb0deb75b2ec7881bcacda9f995648d8e683956e5c2267e69ab6dc503fcbf",
                           highlights: [cHighlights, repository.file(highlights, "52136576a9a9dacd9e95a8de0f351689bf46140738572ab4e9f24c9278e6b458")])
        case .csharp:
            let repository = Repository("tree-sitter/tree-sitter-c-sharp", "v0.23.5")
            return Grammar(repository, "c_sharp", "6f69e1cae44e1c32c1eccc170dc5a9778fb94ff716f71113fe1f8c4299aa2f40",
                           highlights: [repository.file(highlights, "ab8a9930aeeee70fa2dbfde82e4763170b7e826bc642338ad0683772c20c060f")])
        case .css:
            let repository = Repository("tree-sitter/tree-sitter-css", "v0.25.0")
            return Grammar(repository, "css", "8a23977fe271357cce6f254ef88c9bebf3854602d8046605aef6a45c02135c59",
                           highlights: [repository.file(highlights, "23f7948a3817a0d06d7120158c3bee4ec5b58daa77e524985a4738b364db17b2")])
        case .elixir:
            let repository = Repository("elixir-lang/tree-sitter-elixir", "v0.3.5")
            return Grammar(repository, "elixir", "1818ae0d7343f880abb0b7932c9a815f09896ca67b3e126096a2dd7677d1477b",
                           highlights: [repository.file(highlights, "5ee9952a99ce2f0c3dcdf4478daf38f259dd8df4e7f9a892e9f1c03ccdf61ea6")])
        case .go:
            let repository = Repository("tree-sitter/tree-sitter-go", "v0.25.0")
            return Grammar(repository, "go", "9504573f352b20be7f2f1911754d710622aedc15afff16d5ed8fb5645681aee7",
                           highlights: [repository.file(highlights, "81182c986547eba7fa6316e82dfd621fb13b8fc89efac85432aee51a48ed0896")])
        case .haskell:
            let repository = Repository("tree-sitter/tree-sitter-haskell", "v0.24.1")
            return Grammar(repository, "haskell", "ea89cb1199b1ca2102e273b27239e795baff17248128a9bcd3c3825ac17d8cc0",
                           highlights: [repository.file(highlights, "fbce7eeb38a24999958a54e8ea3c086d36467f4b34c919772fa6abc9747e8adf")])
        case .html:
            let repository = Repository("tree-sitter/tree-sitter-html", "v0.23.2")
            return Grammar(repository, "html", "c48fcd82c7ea8bf943180088ba7f28c48b2bb5287874179168bf9d31e394cf85",
                           highlights: [repository.file(highlights, "1ebb3811a8cdc054385b847a3aac6fbf7079faefd5b3dfab5bbad256cd5afdcf")],
                           injections: [repository.file(injections, "6faa29537e952ee444aaa6ac00f72956d13f65616aade74bd665f5ac405f9c32")])
        case .java:
            let repository = Repository("tree-sitter/tree-sitter-java", "v0.23.5")
            return Grammar(repository, "java", "4fdeac4ca6ca089f06c6f7e562abcac1733cd465728cc7031ebb73c2019122c4",
                           highlights: [repository.file(highlights, "576c0df8df0b116cd642140ddc508c01f9d3283582afd8581c1f35caf4d71386")])
        case .javascript:
            return Grammar(js, "javascript", "5fb488d0cabb4775a594bab85682de5ad6ce83c0d6ac997a9f82dd084d571240",
                           highlights: [jsHighlights, jsxHighlights,
                                        js.file("queries/highlights-params.scm", "bbe7a58cacfb1c954cb0eab44779fd80421ed59b762b975723447207635de50d")],
                           injections: [jsInjections])
        case .json:
            let repository = Repository("tree-sitter/tree-sitter-json", "v0.24.8")
            return Grammar(repository, "json", "d2119fb98d5912719b13f9458574f8608d2d29dfbe45f6be1f860ea1fe2a2405",
                           highlights: [repository.file(highlights, "0511524465b56aed122580792254e68b6abbbfde7119f1d02b135acbe278233f")])
        case .julia:
            let repository = Repository("tree-sitter/tree-sitter-julia", "v0.25.0")
            return Grammar(repository, "julia", "b20da9dc7d7334e2cae034ca4974dd09c94be8c0a524df1fc194b545bc2f49f5",
                           highlights: [repository.file(highlights, "b46bbba6ecf4c4278a38fdd9e397e0ded4ff2127c9a333a7b0e3eb359e2147fd")])
        case .kotlin:
            let repository = Repository("fwcd/tree-sitter-kotlin", "0.3.8")
            return Grammar(repository, "kotlin", "c624e7443b371c28adc5d81674e73067564c12555ebe3ed96a6c8db814b7602d",
                           highlights: [repository.file(highlights, "2d74bb308bc589c2dadd9a599613f750f51470a8974190e09e24ec4786bab987")])
        case .lua:
            let repository = Repository("tree-sitter-grammars/tree-sitter-lua", "v0.5.0")
            return Grammar(repository, "lua", "df08a1704e504c70b8dba4a3e6f8e0c99a4fb94e1b1693d2969f53141d09f0d4",
                           highlights: [repository.file(highlights, "d2625fb712357f86386878602d18845f9f3e90fee81f02a5ecd87be6512918d1")])
        case .make:
            let repository = Repository("tree-sitter-grammars/tree-sitter-make", "v1.1.1")
            return Grammar(repository, "make", "1254d1e5787be8bb944d55d1f6552b6b2b7908272ed498013bfdc07bd7d042dd",
                           highlights: [repository.file(highlights, "295045cf653f02bdca99f86bd34667eabbc474939056209655505fae3c8c83f4")])
        case .markdown:
            let repository = Repository("tree-sitter-grammars/tree-sitter-markdown", "v0.5.3")
            return Grammar(repository, "markdown", "dd9fc12ac2804d7c7da787e4774125b32e4fb3c244e5e7031a77cb7dd8036020",
                           highlights: [repository.file("tree-sitter-markdown/queries/highlights.scm",
                                                        "2eb06e766ccd672d49599d14f398f07f4f5f7f2208262993d3cd9207c1078e2f")],
                           injections: [repository.file("tree-sitter-markdown/queries/injections.scm",
                                                        "64b1a6006b40176d8db986cc41350e4f9b292fd06bfedb0abfcdb1fb989aca3e")])
        case .objc:
            // The grammar extends C's, and its query starts where C's leaves off (`; inherits: c`).
            let repository = Repository("tree-sitter-grammars/tree-sitter-objc", "v3.0.2")
            return Grammar(repository, "objc", "155bf61fc94941fa9d07c86cd46895f14dfb2549fb7f646faeb83765af05c970",
                           highlights: [cHighlights, repository.file(highlights, "ce7e30b5aab3d659a096812d8c227e83cd9bbb60470eb44def45bd5cb7737386")])
        case .ocaml:
            let repository = Repository("tree-sitter/tree-sitter-ocaml", "v0.26.0")
            return Grammar(repository, "ocaml", "bfa3eef92b9d3cc1117aa486d46ecb06c98a3a28c1747660aaa5851df5e4530c",
                           highlights: [repository.file(highlights, "0e4e33416c72feca0b9c797bf9615a85dc31bd83bc3361e1c8adb124b0eeb54e")])
        case .perl:
            let repository = Repository("tree-sitter-perl/tree-sitter-perl", "v2.0.0")
            return Grammar(repository, "perl", "7d4ad86813db08e2edc69b42d18d7a6c52a0770cba61365b7932f7d6b56ee36f",
                           highlights: [repository.file(highlights, "715dfb71507662f0af43665370eadfacc811054b33db9d3d946c9bacf8420959")])
        case .php:
            // `php_only`: code without the surrounding HTML, which is what snippets and fences usually are.
            let repository = Repository("tree-sitter/tree-sitter-php", "v0.25.1")
            return Grammar(repository, "php_only", "605c2b17407985e708a5a01e7ad67acbe6de8fc6c75f3ec82d9b4c70bc6a915f",
                           highlights: [repository.file(highlights, "a2a7367659cff3b4be09961c8117d69a9b8703bfc266f8092e089b1760f197e9")])
        case .python:
            let repository = Repository("tree-sitter/tree-sitter-python", "v0.25.0")
            return Grammar(repository, "python", "16108b50df4ee9a30168794252ab55e7c93bfc5765d7fa0aa3e335752c515f47",
                           highlights: [repository.file(highlights, "a6708f209381618e2b398972c8f1ccd892f0c064eab35a2a3f911c3e22e79a7e")])
        case .r:
            let repository = Repository("r-lib/tree-sitter-r", "v1.3.0")
            return Grammar(repository, "r", "3e406e27cec05a60ba3281e2da021187200b83d152d9eb0dcf0a731cbfbcc28d",
                           highlights: [repository.file(highlights, "7fd08df9b6529a3b38507aac14da883025779f81c255a896ba961900cf0b4cd6")])
        case .ruby:
            let repository = Repository("tree-sitter/tree-sitter-ruby", "v0.23.1")
            return Grammar(repository, "ruby", "09a96427d7c72f0613ed470cd9812223fc4a91d6a9c025c0235cc6bd59ff96f4",
                           highlights: [repository.file(highlights, "0858de9feece6dcd3408a541f995a34918d587ac2c552096026b0e47e2b332e6")])
        case .rust:
            let repository = Repository("tree-sitter/tree-sitter-rust", "v0.24.2")
            return Grammar(repository, "rust", "24c89bd9252255e4aebbcbd7d2d308bd92c86dd95a130fdc80efa49577b8d738",
                           highlights: [repository.file(highlights, "0f0343107f14a7690157f51090a979eb8f8bfe4eada7c61763ddb4c54b1311d1")],
                           injections: [repository.file(injections, "723146f179bc0edfba2f51731c99afce8bed3b677dfb4435c303859fae299ba5")])
        case .scala:
            let repository = Repository("tree-sitter/tree-sitter-scala", "v0.26.2")
            return Grammar(repository, "scala", "37d7fe5a91ca98941dc05493b0c05a0df0f36df5035890fa00b02497c68aaac3",
                           highlights: [repository.file(highlights, "c6e2d65c4f84b5484af3e1edc3451850fe8d878ce11f79550e426f8ac6e2df4a")])
        case .swift:
            let repository = Repository("alex-pinkus/tree-sitter-swift", "0.7.3")
            return Grammar(repository, "swift", "0258a7ef17303a8079ffe0748b3583d59656b5c3e8653fca7b6451b3e6689eb2",
                           highlights: [repository.file(highlights, "b0bbeb918904b252e8bd361f4afb4756647232391110a67deecbf7227464aff8")])
        case .toml:
            let repository = Repository("tree-sitter-grammars/tree-sitter-toml", "v0.7.0")
            return Grammar(repository, "toml", "1ac6a83826c35a68857f8325e00c78f6bcbef4eb6db3931a6cf3041f76e5e09f",
                           highlights: [repository.file(highlights, "2fb5c61d33a70389312254c9c392e2c5dd6313d958d6e5f8f74cadd5e0811707")])
        case .tsx:
            return Grammar(ts, "tsx", "79e5da75ea62855a0cd67177685f0164eac87d5f630b3cbe1e0a099751ad30f8",
                           highlights: [jsHighlights, jsxHighlights, tsHighlights], injections: [jsInjections])
        case .typescript:
            return Grammar(ts, "typescript", "778025db5a8be0e70f8ccc3671e486dfeddd048c25d9e8a70c26de2e1bf6f97d",
                           highlights: [jsHighlights, tsHighlights], injections: [jsInjections])
        case .xml:
            let repository = Repository("tree-sitter-grammars/tree-sitter-xml", "v0.7.0")
            return Grammar(repository, "xml", "9950327f8542a3d563fe4192aa05986a53e6fd6adca518cbb1a1699cbc8970ad",
                           highlights: [repository.file("queries/xml/highlights.scm", "aa4a561c846928c3a4d885acbe690a60689661a45684babe16cf8b7a1509b610")])
        case .yaml:
            let repository = Repository("tree-sitter-grammars/tree-sitter-yaml", "v0.7.2")
            return Grammar(repository, "yaml", "0a0e5ebcfeb0b2bf272d071396eeed107b2c4b2617b69d5959b13f78b357a4d6",
                           highlights: [repository.file(highlights, "2fbfbbd5ca0928d0a7e09e59f8f2964b14a328a7ee0ce799270d9013dcce49a0")])
        case .zig:
            let repository = Repository("tree-sitter-grammars/tree-sitter-zig", "v1.1.2")
            return Grammar(repository, "zig", "54b3b83dd9c62da5815f06132bc3fc914d9dcc780370b32416446a0b7969e8c6",
                           highlights: [repository.file(highlights, "27a7ffc77086ec6394c04e59b42f0da4c9d3c294a0225bc155c80305ee54ca86")])
        }
    }

    /// Markdown's inline syntax, a grammar of its own that markdown reaches only through injections.
    static let markdownInline: Grammar = {
        let repository = Grammar.Repository("tree-sitter-grammars/tree-sitter-markdown", "v0.5.3")
        return Grammar(repository, "markdown_inline", "d47e5c43683c39b645ced8720ab90c3b3f467e715d3426b29ef3f69984d88c15",
                       highlights: [repository.file("tree-sitter-markdown-inline/queries/highlights.scm",
                                                    "9a88072f0ce54972c32fe7952ccb2d29254b6a7228bda1c7babc18df15cba797")],
                       injections: [repository.file("tree-sitter-markdown-inline/queries/injections.scm",
                                                    "97bf17b9a973db8ee6868f543dd1eabdd81f19b8751a4fcf92db45f74462f4c5")])
    }()

    /// The grammar an injection names: `markdown_inline`, or a language (`javascript`, a fence's `ts`, `sh`, …).
    static func injected(named name: String) -> Grammar? {
        name == markdownInline.name ? markdownInline : SyntaxLanguage(name: name).map(grammar(for:))
    }

    private typealias Repository = Grammar.Repository
}

/// Downloads grammars into a directory, one subdirectory per grammar version (`parser.wasm`, `highlights.scm`,
/// `injections.scm`), so each is fetched once.
actor GrammarDownloads {
    static let shared = GrammarDownloads(directory: URL.cachesDirectory
        .appending(path: Bundle.main.bundleIdentifier ?? "PaseoSyntax")
        .appending(path: "Grammars"))

    /// How long a failed download is remembered before it's tried again.
    static let retryDelay: Duration = .seconds(60)

    let directory: URL
    private var downloads: [String: Task<URL, any Error>] = [:]
    private var failures: [String: (error: any Error, at: ContinuousClock.Instant)] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    /// The grammar's directory, downloading it first if needed.
    func files(for grammar: Grammar) async throws -> URL {
        let key = grammar.cacheKey
        let destination = directory.appending(path: key, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        if let failure = failures[key], failure.at.duration(to: .now) < Self.retryDelay { throw failure.error }
        if let download = downloads[key] { return try await download.value }
        let download = Task { try await Self.download(grammar, to: destination) }
        downloads[key] = download
        defer { downloads[key] = nil }
        do {
            return try await download.value
        } catch {
            failures[key] = (error, .now)
            throw error
        }
    }

    struct HashMismatch: Error, CustomStringConvertible {
        var url: URL
        var expected: String
        var actual: String

        var description: String { "\(url): expected SHA-256 \(expected), got \(actual)" }
    }

    private static func download(_ grammar: Grammar, to destination: URL) async throws -> URL {
        async let wasm = fetch(grammar.wasm)
        let highlights = try await fetch(grammar.highlights)
        let injections = try await fetch(grammar.injections)
        // Written beside the destination and moved into place, so a half-written grammar is never picked up.
        let manager = FileManager.default
        let staging = destination.deletingLastPathComponent().appending(path: ".\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        try await wasm.write(to: staging.appending(path: "parser.wasm"))
        try highlights.write(to: staging.appending(path: "highlights.scm"))
        try injections.write(to: staging.appending(path: "injections.scm"))
        do {
            try manager.moveItem(at: staging, to: destination)
        } catch where manager.fileExists(atPath: destination.path) {
            // Another process got there first.
        }
        return destination
    }

    /// The files concatenated, each ending in a newline.
    private static func fetch(_ files: [Grammar.File]) async throws -> Data {
        var data = Data()
        for file in files {
            data.append(try await fetch(file))
            data.append(0x0A)
        }
        return data
    }

    private static func fetch(_ file: Grammar.File) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: file.url)
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw URLError(.badServerResponse, userInfo: [NSURLErrorFailingURLErrorKey: file.url])
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == file.sha256 else { throw HashMismatch(url: file.url, expected: file.sha256, actual: hash) }
        return data
    }
}
