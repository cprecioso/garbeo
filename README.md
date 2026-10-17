# Garbeo

A native SwiftUI client (macOS + iOS) for [Paseo](https://paseo.sh), the agentic development environment. It connects to a Paseo daemon over its WebSocket protocol, either directly or through the Paseo relay with end-to-end encryption.

## Features

- Connect to a daemon by address (`127.0.0.1:6767`, `host:port`, `ws(s)://…`), with an optional password stored in the Keychain. When a daemon answers on `127.0.0.1:6767` (`/api/health`, polled while the connect screen is up) and isn't saved yet, the connect screen offers a one-click Connect
- Pair through the Paseo relay: scan the QR code from `paseo daemon pair` / Paseo Desktop (iOS), or paste the pairing link (both platforms). Traffic is end-to-end encrypted (Curve25519 + XSalsa20-Poly1305, wire-compatible with the official apps)
- Saved hosts list; relay daemon keys and passwords live in the Keychain. The sidebar footer shows whether the connection is direct or relayed
- Live sidebar: projects → workspaces (iOS: → agents and terminals), with status, diff stats, and permission badges, kept in sync through daemon subscriptions
- macOS workspaces as tabs (one per agent and terminal) that drag into nested horizontal/vertical split panes ([Bonsplit](https://bonsplit.alasdairmonk.com/)), each pane with its own live timeline. Layouts persist per workspace across launches
- Agent timeline: markdown replies ([Textual](https://github.com/gonzalezreal/textual): tables, code blocks, text selection), collapsible reasoning, tool calls (shell, read, edit diffs, search, fetch, sub-agents), task lists, errors. Consecutive reasoning and tool calls fold into one collapsed row that keeps the latest step visible while the agent works. Streams live, with "load earlier" paging
- Syntax highlighting with [tree-sitter](https://tree-sitter.github.io) grammars, downloaded on first use, for markdown code blocks, read/written files, edit diffs (old and new sides parsed separately) and shell commands in permission requests (see [Syntax highlighting](#syntax-highlighting))
- Send messages (optimistic, confirmed when the daemon echoes them), stop a running turn, change permission mode, archive
- Answer permission requests inline (provider-supplied actions or Allow/Deny)
- Create agents: New Agent opens a chat for the agent right away, with its workspace (or a new worktree), provider, model, thinking level and mode as menus above the focused composer. The agent is created on the daemon when its first message is sent
- Create projects from a directory on the daemon's machine (sidebar toolbar, File ▸ New Project…, ⌥⌘N), with an optional name. The path field suggests the daemon's directories; a daemon on this Mac also offers a folder picker
- Create workspaces: a new worktree branching off a ref (default: the project's default branch), or checking out an existing branch or pull request, optionally named and with a first agent. Branch fields suggest the repository's branches. A new agent chat can also create its worktree
- Workspace setup progress: live status of the project's setup scripts above the workspace's tabs (macOS) or in its sidebar section (iOS), with per-command output, and approval for setups blocked on a fork pull request's code
- Workspace terminals: tabs of their workspace on macOS, listed per workspace in the sidebar on iOS (live via `terminals_changed`), opened in a real terminal emulator ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)) with keyboard input, screen restore on attach, resize, new and kill. ⌘T opens a new terminal in the focused workspace (File > New Terminal Tab on macOS; on iPad with a hardware keyboard, once one of its agents or terminals is selected). On iOS, SwiftTerm's accessory bar provides esc, ctrl, tab, and arrow keys
- Automatic reconnect with backoff; ping/pong liveness lease
- Plugin UI: screens, workspace/agent panels, sidebar items and Command Center items from [Paseo plugins](https://paseo.sh/docs/plugins) run unmodified in WKWebView panes (see [Plugins](#plugins))

## Layout

```
Package.swift            PaseoKit + GarbeoTerminal + GarbeoSyntax libraries (PaseoKit depends on swift-sodium, GarbeoTerminal on SwiftTerm,
                         GarbeoSyntax on WebKit only)
Sources/PaseoKit/
  DaemonClient.swift     hello handshake, requestId correlation, subscriptions, ping, binary frames
  DaemonTransport.swift  transport protocol + plain WebSocket transport; endpoint → transport selection
  RelayE2EETransport.swift  relay client channel: e2ee_hello/e2ee_ready, capability negotiation, framing
  RelayCrypto.swift      NaCl box (libsodium) matching packages/relay/src/crypto.ts
  Pairing.swift          pairing offers (#offer=), relay:// connection URIs, relay WebSocket URLs
  Models.swift           tolerant Decodable wire models (unknown fields and enum values are fine)
  Timeline.swift         merges live agent_stream deltas into projected pages; detects seq gaps
  TimelineSubscriptions.swift  per-agent live timelines for every visible agent; serialized set_subscription
  TerminalFrames.swift   terminal binary frame codec, snapshot → ANSI renderer
  Terminals.swift        terminal requests, slot-routed output streams
  Plugins.swift          plugin list/catalog/RPC requests and catalog-change events
  PluginContributions.swift  contributions plugin hosts report, and which ones each workspace menu lists
  Worktrees.swift        worktree creation, setup progress, branch suggestions
  Projects.swift         adding and renaming projects, directory suggestions
Sources/GarbeoTerminal/  GarbeoTerminalView: self-contained SwiftUI terminal (SwiftTerm), hostable in any container
Sources/GarbeoSyntax/
  SyntaxLanguage.swift   languages; detection from file paths and markdown fence names
  Grammars.swift         grammar table (release wasm + query files, pinned by SHA-256), download cache
  WebHighlighter.swift   hidden WebPage running the grammars in web-tree-sitter, injected languages as layers
  Web/                   web-tree-sitter (vendored from the tree-sitter release) and its glue, highlighter.js
  SyntaxHighlighter.swift  code → sorted, non-overlapping capture spans (tree-sitter-highlight precedence)
  SyntaxDiff.swift       unified/line diffs split into lines, old and new sides highlighted separately
  SyntaxTheme.swift      GitHub (Primer) colors per capture, light and dark; spans → AttributedString
Tests/PaseoKitTests/     unit tests, plus opt-in live daemon tests
  Resources/relay-vectors.json  known-answer vectors generated from the upstream TypeScript
  Fixtures/terminal-vectors.json  terminal codec vectors generated from the upstream TypeScript
Tests/GarbeoTerminalTests/ SwiftTerm behavior the terminal session relies on, restore reply filter, daemon-answered query replies
Tests/GarbeoSyntaxTests/ every grammar downloads and highlights a sample; precedence, injections, diffs, language detection
Scripts/generate-relay-vectors.mjs  regenerates the relay vectors (instructions inside)
scripts/generate-terminal-vectors.mts  regenerates the terminal vectors
App/Garbeo.xcodeproj     multiplatform SwiftUI app target (Textual for markdown; Bonsplit linked on macOS only), GarbeoTests, GarbeoUITests
App/Garbeo/              views + AppModel (observable store), HostStore (saved hosts), QR scanner, credits (keep CreditsView in step with dependencies)
  Workspace/             workspace tabs: tab content model, saved layout, Bonsplit integration (macOS)
  Plugins/               PluginStore, WKWebView runtime + bridge, PluginPaneView, PluginTab, sidebar/menu entries
  PluginHost/plugin-host.js  generated JS host runtime (do not edit)
  LaunchOptions.swift    test isolation: -GarbeoEphemeral (UserDefaults.app, in-memory Keychain), -PaseoConnect
App/Shared/              AccessibilityID: identifiers shared by the app and its UI tests
App/GarbeoTests/         unit tests hosted in the app (@testable import Garbeo)
App/GarbeoUITests/       XCUITests; Harness/ has launchForTesting, element(_:), clickOrTap, replaceText, LiveDaemon
Scripts/with-test-daemon.sh  runs a command against a throwaway daemon (e2e and UI tests)
Scripts/test-plugin/     the plugin that daemon installs, for tests of plugin UI
PluginHost/              source of the JS host runtime (React, react-native-web, Paseo plugin SDK)
```

## Workspace tabs and panes (macOS)

The sidebar lists only workspaces; selecting one opens it as tabs. Every agent and terminal of the workspace gets a tab, including ones created later (appended to the focused pane without taking focus); creating one in the app focuses its tab. Subagents working in their parent's workspace are the exception: they open from the Open Tab menu, and the daemon is told (through an open-tab label) so it keeps them if their parent is archived. As in Paseo's own app, closing a tab archives its agent (confirming first if it's running), only closes the tab of a subagent, or kills its terminal (always confirmed). Tabs show agents (`AgentTab`) and terminals (`TerminalTab`); the toolbar's Open Tab menu lists both and creates terminals. A terminal tab only takes keyboard focus, and with it the PTY size claim, when it was just selected, not when restored. Drag a tab onto a pane's edge to split, onto its center or another tab bar to move it; the tab bar's split buttons create an empty pane. Bonsplit owns the tree; `WorkspaceTabs` maps its tabs to `WorkspaceTabContent` and saves the layout (derived from `treeSnapshot()`) to UserDefaults per daemon and workspace.

To add a tab kind (plugin webview, …), write a struct conforming to `WorkspaceTabKind` (a label, a content view, and optionally what closing it does) and add one `case` plus its `kind` arm to `WorkspaceTabContent` in `Workspace/WorkspaceTabContent.swift`. Tab bar, splits, drag and drop and persistence need nothing else.

## Syntax highlighting

`GarbeoSyntax` parses with tree-sitter and colors the captures of each grammar's own `highlights.scm`: Bash, C, C++, C#, CSS, Elixir, Go, Haskell, HTML, Java, JavaScript/JSX, JSON, Julia, Kotlin, Lua, Make, Markdown, Objective-C, OCaml, Perl, PHP, Python, R, Ruby, Rust, Scala, Swift, TOML, TypeScript, TSX, XML (plists, storyboards, SVG, …), YAML and Zig. Injections are followed, so HTML `<script>`/`<style>`, JS tagged templates, Rust macro bodies and markdown fences and inline markup are highlighted in their own language.

No grammar ships with the app. The first block in a language downloads its grammar's `.wasm` from the grammar's GitHub release and its query files from the repository at the same tag, checks each against the SHA-256 in `Grammars.swift`, and keeps them in the caches directory (all of them come to about 55 MB). The block stays plain until then, markdown fences keep Textual's Prism highlighting if the download fails, and a failed download is retried after a minute.

The wasm runs in [web-tree-sitter](https://github.com/tree-sitter/tree-sitter/tree/master/lib/binding_web) inside a `WebPage` that's never shown, the same on macOS and iOS: iOS forbids JIT in the app process, but WebKit's web content process runs wasm with it. The page starts with the first block to highlight, and a new one starts if iOS reclaims its process. Each language is a layer: `WebHighlighter` highlights the code, then every injected language over the ranges it covers (combined into one layer per language, as SwiftTreeSitterLayer does), and so on. The captures come back to Swift, where the deepest layer, then the innermost node, then the latest pattern wins.

In the app, `CodeBlock` highlights tool call bodies off the main actor and caches the result. Markdown code blocks go through a Textual `CodeBlockStyle` that renders the highlighted code with Textual's `InlineText` (so it stays part of the reply's text selection); fences in other languages keep Textual's Prism highlighting. Textual doesn't expose a code block's text, so the style reads it from `CodeBlockProxy` with `Mirror`; if a Textual update renames that property, every block falls back to Prism.

To add a language: its grammar's GitHub release must include `tree-sitter-<name>.wasm`. Add a case to `SyntaxLanguage` (plus extensions and aliases), its entry in `Grammars.grammar(for:)` with each file's `shasum -a 256` (queries it inherits from a base grammar first, as C++ and TypeScript do), and a sample in `GrammarTests`. `swift test --filter GarbeoSyntaxTests` downloads every grammar (once; it needs the network the first time) and highlights its sample, so it catches a moved tag, wasm web-tree-sitter can't load, and queries that don't compile. To update web-tree-sitter, replace `Sources/GarbeoSyntax/Web/web-tree-sitter.{js,wasm}` with the ones in a tree-sitter release's `web-tree-sitter.tar.gz` (currently 0.27.1) and run the same tests.

## Build and run

```sh
open App/Garbeo.xcodeproj        # pick "My Mac" or an iOS Simulator, then Run

# or from the command line
xcodebuild -project App/Garbeo.xcodeproj -scheme Garbeo -destination 'platform=macOS' \
  -skipPackagePluginValidation build
```

SwiftTerm (pinned to 1.99.0, the 2.0 preview) runs a build-tool plugin that generates its build info and terminfo tables. Xcode asks you to "Trust & Enable" it on first build; on the command line pass `-skipPackagePluginValidation`.

Requires Xcode 27+, macOS 27 / iOS 27.

## Tests

CI (`.github/workflows/ci.yaml`) runs every level on pull requests and pushes to `main`, macOS and iOS Simulator. Locally:

```sh
mise run test:unit              # SwiftPM unit tests (swift test)
mise run test:e2e               # SwiftPM live tests (--filter Live) against a throwaway daemon
mise run //App:test:unit:mac    # app unit tests (App/GarbeoTests, hosted in the app); also :ios
mise run //App:test:ui:mac      # XCUITests (App/GarbeoUITests) against a throwaway daemon; also :ios
mise run test                   # all of the above, macOS only
```

`Scripts/with-test-daemon.sh` starts the throwaway daemon (needs `paseo` on the `PATH`) on `127.0.0.1:6871` (`PASEO_TEST_PORT`) with its own home, one workspace and one plugin (`Scripts/test-plugin`: a workspace panel and two workspace commands, shaped like paseo-gh-stack), sets `PASEO_LIVE_URL`, `PASEO_LIVE_WORKSPACE`, `PASEO_LIVE_THROWAWAY=1`, `PASEO_LIVE_TERMINALS=1` and `PASEO_LIVE_PLUGINS=1`, and passes them on to XCUITests as `TEST_RUNNER_*`. With `PASEO_LIVE_URL` already set it uses that daemon instead and starts nothing. Tests that need a daemon skip without one. The iOS tasks run on `IOS_SIMULATOR` (default `iPhone 17`); results land in `App/build/results`. macOS XCUITests need Automation Mode, which asks for authentication the first time.

UI tests launch the app with `XCUIApplication.launchForTesting(daemon:arguments:)` (`App/GarbeoUITests/Harness`): `-GarbeoEphemeral YES` keeps settings in a throwaway domain and secrets in memory, so the app never sees or changes your saved hosts, and `-PaseoConnect <address>` connects on launch. Use `LiveDaemon.require()` for the daemon's address (skips without one) and `LiveDaemon.requireThrowaway()` before changing its state; `LiveDaemon.requirePlugins()` skips unless the test plugin is installed. Find elements by accessibility identifier: add a constant to `App/Shared/AccessibilityID.swift` (`<area>.<element>`, shared by the app and the UI tests), set it with `.accessibilityIdentifier(…)`, and look it up with `app.element(AccessibilityID.….…)`. Press buttons with `clickOrTap()` (`tap()` doesn't press SwiftUI buttons on macOS).

The live SwiftPM tests can also target a daemon of your own:

```sh
swift test                                      # unit tests (PaseoKit + GarbeoTerminal + GarbeoSyntax)
PASEO_LIVE_URL=127.0.0.1:6767 swift test        # + read-only checks against a running daemon (incl. plugin list/catalog)
PASEO_LIVE_URL=127.0.0.1:6767 PASEO_LIVE_WRITE=1 swift test   # + creates real agents (cheap model)
```

To test the relay end to end without touching your working daemon, run an isolated one with relay enabled and pair against it:

```sh
H=$(mktemp -d)
PASEO_LISTEN=127.0.0.1:47391 PASEO_RELAY_ENABLED=true PASEO_PASSWORD=pw paseo daemon run --home "$H" &
URL=$(paseo daemon pair --home "$H" --json | jq -r .url)
PASEO_LIVE_PAIRING_URL="$URL" PASEO_PASSWORD=pw swift test --filter LiveRelayTests
PASEO_LIVE_URL="$URL" PASEO_PASSWORD=pw swift test --filter LiveDaemonTests   # same read-only suite, over the relay
paseo daemon stop --home "$H"
```

```sh
# creates, types into, resizes and kills a terminal; point it at a throwaway daemon
PASEO_LIVE_URL=127.0.0.1:6899 PASEO_LIVE_TERMINALS=1 swift test --filter LiveTerminal
```

To get a throwaway daemon: `PASEO_HOME=/tmp/paseo-adhoc PASEO_LISTEN=127.0.0.1:6899 PASEO_RELAY_ENABLED=false paseo daemon run --home /tmp/paseo-adhoc`, then `paseo workspace create --host 127.0.0.1:6899 --isolation local --path <dir>`.

The write tests create agents. When the daemon creates a workspace for them, cleanup archives that workspace only if it didn't exist before the test ran. Otherwise they archive just their own agent. Don't run them against a daemon you're actively using unless that's acceptable.

## Releases

[release-please](https://github.com/googleapis/release-please) keeps a release PR open on `main`, built from [Conventional Commits](https://www.conventionalcommits.org/) (`feat: …`, `fix: …`; with squash merges, the PR title). Merging it bumps `MARKETING_VERSION` in `App/Version.xcconfig` and tags the release (`.github/workflows/cd.yaml`).

Every push to `main` also publishes the iOS and Mac apps to TestFlight (`mise run //App:beta:ios` and `//App:beta:mac`). Betas are built in the `Release` configuration, the same name and icon as a release, so any of them can be promoted to the App Store.

## Protocol notes

Speaks protocol version 1 as defined in `packages/protocol/src/messages.ts` of [getpaseo/paseo](https://github.com/getpaseo/paseo). The client advertises `owned_subscriptions`, `explicit_event_subscriptions`, and `selective_agent_timeline`, so it only receives streams for the agents on screen:

1. `hello` → `status.server_info` (or `hello.rejected`)
2. `fetch_workspaces_request` / `fetch_agents_request` with `subscribe: {}` → `workspace_update` / `agent_update`
3. `session.events.set_subscription.request` for permission events
4. `agent.timeline.set_subscription.request` with the full set of visible agents (every mounted agent view, so all panes on macOS), sent one at a time and coalesced since each call replaces the set. Once acknowledged, `fetch_agent_timeline_request` (tail) runs for newly covered agents; `agent_stream` deltas are merged by `seq`, and a gap or epoch change refetches the tail
5. Terminals: `list_terminals_request` once, then `subscribe_terminals_request` per workspace for `terminals_changed`. Opening a terminal sends `subscribe_terminal_request` with `restore: visible-snapshot` (when the daemon has `terminal-restore-modes`); the response assigns a slot, and binary frames (`[opcode, slot, payload]`) carry Output/Restore down and Input/Resize up. The slot is bound while the response frame is handled, so the Restore frame right behind it is never dropped. Legacy JSON `Snapshot` frames are rendered to ANSI client-side. The client advertises `terminal_reflowable_snapshot`

PTY size is last-interacting-client-wins: attaching and passive layout never resize. Focusing, clicking or tapping the terminal, returning to its window, or typing after 5s idle sends a `claim`; later grid changes send an `update`, which the daemon ignores if another client has claimed since.

Relay connections (`packages/relay`, `packages/protocol/src/connection-offer.ts`, `daemon-endpoints.ts`):

- Pairing links: `https://app.paseo.sh/#offer=<base64url JSON {v:2, serverId, daemonPublicKeyB64, relay:{endpoint,useTls}}>`, `relay://host:port/<serverId>?key=…&ssl=true[&password=…]`, or `…#connect=<relay URI>`
- Socket: `wss://relay.paseo.sh/ws?serverId=…&role=client&v=2`
- Handshake: a fresh ephemeral Curve25519 keypair per connection; plaintext `{"type":"e2ee_hello","key":…,"capabilities":{"binaryCiphertext":true}}` re-sent every second until `{"type":"e2ee_ready"}`
- Frames: `[24-byte nonce][box]` with the `box.before` key. With `binaryCiphertext` negotiated, app text is a base64 text frame and app binary a raw binary frame; legacy peers get base64 text for both. Any other plaintext JSON after the handshake, or a frame that fails authentication, closes the socket
- The regular `hello` (including the password) then runs inside the encrypted channel. Over the relay, a wrong password shows up as a disconnect (the daemon's `hello.rejected` is lost behind its close), which the client reports as a likely password problem

## Plugins

Upstream Paseo has no webview contract for plugins. The daemon compiles each plugin's `index.client.tsx` into a CommonJS bundle and ships it in `plugin.catalog.get.response`; the official app `eval`s it with a `require` that hands out its own React, React Native, TanStack Query, zod and `@getpaseo/plugin` modules, then renders the contributed components in its own tree. This client does the same inside a WKWebView:

- `PluginHost/` is a small JS host (React 19.1 + react-native-web + the Paseo plugin/client SDK) that ports upstream's `runPluginClientBundle`, its `require` map, providers (`QueryClientProvider`, `PaseoApiProvider`, `PluginRpcProvider`, `PluginClientStateProvider`) and the host-supplied modules (`@getpaseo/plugin/client/ui`, `/client/react-native`, `useSettings`, `useHosts`, Lucide icons by name). It is bundled into `App/Garbeo/PluginHost/plugin-host.js`, which is committed so the app builds without Node.
- A hidden **registry** page per connection runs every client bundle, reports contributions (screens, panels, Command Center items, settings screens) and renders sidebar items headlessly: the rows a plugin draws with `SidebarRow` show up as native rows under **Plugins** in the sidebar, and presses run the plugin's own `onPress`.
- Each open **pane** (`PluginPaneView`, a self-contained view any container can host) runs its own page that renders one screen or panel with the upstream props (`theme`, `host`, `layout`, `navigation`, `params` / `workspaceId` / `agentId`).
- Bridge: pages are served from `paseo-plugin://host/` by a `WKURLSchemeHandler`; navigation anywhere else is cancelled and http(s) links open in the system browser. The init payload (bundles, target, theme from native semantic colors, workspace/agent snapshots) is injected with a `WKUserScript`; JS calls the app through a `WKScriptMessageHandlerWithReply`. `useRpc` / `ctx.rpc` go through the app's own connection as `plugin.rpc.invoke.request`. `usePaseo()` gets a real `@getpaseo/client` `PaseoApi` whose socket the app opens natively with the connection's own transport (direct or relay E2EE) and relays (the daemon rejects WebSocket upgrades from unlisted origins, which includes the custom scheme).
- `status.plugin_catalog_changed` reloads the catalog and rebuilds pages; `status.plugin_settings_changed` refreshes `useSettings`.

Where they show up: sidebar items, legacy sidebar items and global commands in the sidebar's **Plugins** section; workspace panels and workspace commands in a workspace row's context menu (and, on macOS, the workspace's Open Tab menu); workspace/agent panels and commands in the agent toolbar's **Plugins** menu. On macOS, workspace panels open as workspace tabs (`PluginTab`) and screens in the detail column; on iOS both open in the detail column (a sheet on iPhone).

Not supported yet: composer pills, header buttons, slash commands, attachment sources, themes, timeline transformers/renderers, sidebar popovers (they register without error but don't render), and the `paseo` version check on `requirements`.

Rebuilding the JS host (needs Node and a getpaseo/paseo checkout at the pinned commit in `PluginHost/build.mjs`; the SDK is compiled from source rather than npm):

```sh
git clone https://github.com/getpaseo/paseo /tmp/paseo-src/paseo   # then check out the pinned ref
cd PluginHost && npm install && PASEO_SRC=/tmp/paseo-src/paseo npm run build
```

## Not yet supported

- Opening `https://app.paseo.sh/#offer=…` links from other apps (needs associated domains); paste or scan them instead
- QR scanning on macOS (paste the link instead)
- Git diff/commit/PR panes, file explorer, schedules, voice
- Terminal rename and find
- Image attachments

## Debug aids (DEBUG builds)

- `-PaseoConnect <address>` connects directly to a daemon on launch
- `-GarbeoEphemeral YES` starts from empty settings that aren't saved, and keeps passwords and keys out of the Keychain
- `-PaseoSelectAgent first|<agentId>` opens an agent on launch
- `-PaseoPairingLink <url>` pairs with a relay pairing link and connects on launch
- `-PaseoSelectTerminal first|<terminalId>|new` opens a terminal on launch (`new` creates one in the first workspace; throwaway daemons only)
- `-GarbeoTerminalType 'echo hi\r'` types into the opened terminal through the emulator's input path once it's live
- `-PaseoResizeWindow 900x500` (macOS, with `-PaseoSnapshot`) resizes the window and takes a third snapshot
- `-PaseoSelectWorkspace first|<workspaceId>` opens a workspace on launch (macOS: tabbed view)
- `-GarbeoTerminalPassive YES` (macOS) terminal tabs never take focus, so attaching never claims the PTY size (for read-only runs against a live daemon)
- `-PaseoSplit horizontal[:0.3][,vertical…]` (macOS) splits the focused pane per entry and moves a hidden tab into each new pane, as a drag would
- `-PaseoSnapshot /path/prefix` writes a state summary (visible timelines, subscription, workspace layout) and on macOS a window PNG after launch
- `-PaseoOpenPluginPane <pluginId>/screen/<id>` | `<pluginId>/panel/<id>[/<workspaceId>]` | `sidebar:<row label>` | `command:<pluginId>/<commandId>` opens a plugin pane once contributions load; `-PaseoPluginPress <aria-label prefix>` clicks inside it; with `-PaseoSnapshot` this writes `<prefix>-plugin.png` and `<prefix>-plugin.txt` (contributions and the bridge RPC log)
