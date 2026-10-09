# Paseo Swift

A native SwiftUI client (macOS + iOS) for [Paseo](https://paseo.sh), the agentic development environment. It connects to a Paseo daemon over its WebSocket protocol, either directly or through the Paseo relay with end-to-end encryption.

## Features

- Connect to a daemon by address (`127.0.0.1:6767`, `host:port`, `ws(s)://…`), with an optional password stored in the Keychain. When a daemon answers on `127.0.0.1:6767` (`/api/health`, polled while the connect screen is up) and isn't saved yet, the connect screen offers a one-click Connect
- Pair through the Paseo relay: scan the QR code from `paseo daemon pair` / Paseo Desktop (iOS), or paste the pairing link (both platforms). Traffic is end-to-end encrypted (Curve25519 + XSalsa20-Poly1305, wire-compatible with the official apps)
- Saved hosts list; relay daemon keys and passwords live in the Keychain. The sidebar footer shows whether the connection is direct or relayed
- Live sidebar: projects → workspaces (iOS: → agents and terminals), with status, diff stats, and permission badges, kept in sync through daemon subscriptions
- macOS workspaces as tabs (one per agent and terminal) that drag into nested horizontal/vertical split panes ([Bonsplit](https://bonsplit.alasdairmonk.com/)), each pane with its own live timeline. Layouts persist per workspace across launches
- Agent timeline: markdown replies ([Textual](https://github.com/gonzalezreal/textual): tables, syntax-highlighted code, text selection), collapsible reasoning, tool calls (shell, read, edit diffs, search, fetch, sub-agents), task lists, errors. Streams live, with "load earlier" paging
- Send messages (optimistic, confirmed when the daemon echoes them), stop a running turn, change permission mode, archive
- Answer permission requests inline (provider-supplied actions or Allow/Deny)
- Create agents: workspace, provider, model, thinking level, mode, prompt
- Workspace terminals: tabs of their workspace on macOS, listed per workspace in the sidebar on iOS (live via `terminals_changed`), opened in a real terminal emulator ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)) with keyboard input, screen restore on attach, resize, new and kill. On iOS, SwiftTerm's accessory bar provides esc, ctrl, tab, and arrow keys
- Automatic reconnect with backoff; ping/pong liveness lease
- Plugin UI: screens, workspace/agent panels, sidebar items and Command Center items from [Paseo plugins](https://paseo.sh/docs/plugins) run unmodified in WKWebView panes (see [Plugins](#plugins))

## Layout

```
Package.swift            PaseoKit + PaseoTerminal libraries (PaseoKit depends on swift-sodium, PaseoTerminal on SwiftTerm)
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
Sources/PaseoTerminal/   PaseoTerminalView: self-contained SwiftUI terminal (SwiftTerm), hostable in any container
Tests/PaseoKitTests/     unit tests, plus opt-in live daemon tests
  Resources/relay-vectors.json  known-answer vectors generated from the upstream TypeScript
  Fixtures/terminal-vectors.json  terminal codec vectors generated from the upstream TypeScript
Tests/PaseoTerminalTests/ SwiftTerm behavior the terminal session relies on, restore reply filter
Scripts/generate-relay-vectors.mjs  regenerates the relay vectors (instructions inside)
scripts/generate-terminal-vectors.mts  regenerates the terminal vectors
App/PaseoSwift.xcodeproj multiplatform SwiftUI app target (Textual for markdown; Bonsplit linked on macOS only)
App/PaseoSwift/          views + AppModel (observable store), HostStore (saved hosts), QR scanner
  Workspace/             workspace tabs: tab content model, saved layout, Bonsplit integration (macOS)
  Plugins/               PluginStore, WKWebView runtime + bridge, PluginPaneView, PluginTab, sidebar/menu entries
  PluginHost/plugin-host.js  generated JS host runtime (do not edit)
PluginHost/              source of the JS host runtime (React, react-native-web, Paseo plugin SDK)
```

## Workspace tabs and panes (macOS)

The sidebar lists only workspaces; selecting one opens it as tabs. Every agent and terminal of the workspace gets a tab, including ones created later (appended to the focused pane without taking focus); creating one in the app focuses its tab. Subagents working in their parent's workspace are the exception: they open from the Open Tab menu, and the daemon is told (through an open-tab label) so it keeps them if their parent is archived. As in Paseo's own app, closing a tab archives its agent (confirming first if it's running), only closes the tab of a subagent, or kills its terminal (always confirmed). Tabs show agents (`AgentTab`) and terminals (`TerminalTab`); the toolbar's Open Tab menu lists both and creates terminals. A terminal tab only takes keyboard focus, and with it the PTY size claim, when it was just selected, not when restored. Drag a tab onto a pane's edge to split, onto its center or another tab bar to move it; the tab bar's split buttons create an empty pane. Bonsplit owns the tree; `WorkspaceTabs` maps its tabs to `WorkspaceTabContent` and saves the layout (derived from `treeSnapshot()`) to UserDefaults per daemon and workspace.

To add a tab kind (plugin webview, …), write a struct conforming to `WorkspaceTabKind` (a label, a content view, and optionally what closing it does) and add one `case` plus its `kind` arm to `WorkspaceTabContent` in `Workspace/WorkspaceTabContent.swift`. Tab bar, splits, drag and drop and persistence need nothing else.

## Build and run

```sh
open App/PaseoSwift.xcodeproj        # pick "My Mac" or an iOS Simulator, then Run

# or from the command line
xcodebuild -project App/PaseoSwift.xcodeproj -scheme PaseoSwift -destination 'platform=macOS' \
  -skipPackagePluginValidation build
```

SwiftTerm (pinned to 1.99.0, the 2.0 preview) runs a build-tool plugin that generates its build info and terminfo tables. Xcode asks you to "Trust & Enable" it on first build; on the command line pass `-skipPackagePluginValidation`.

Requires Xcode 27+, macOS 27 / iOS 27.

## Tests

```sh
swift test                                      # unit tests (PaseoKit + PaseoTerminal)
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

- `PluginHost/` is a small JS host (React 19.1 + react-native-web + the Paseo plugin/client SDK) that ports upstream's `runPluginClientBundle`, its `require` map, providers (`QueryClientProvider`, `PaseoApiProvider`, `PluginRpcProvider`, `PluginClientStateProvider`) and the host-supplied modules (`@getpaseo/plugin/client/ui`, `/client/react-native`, `useSettings`, `useHosts`, Lucide icons by name). It is bundled into `App/PaseoSwift/PluginHost/plugin-host.js`, which is committed so the app builds without Node.
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

- `-PaseoSelectAgent first|<agentId>` opens an agent on launch
- `-PaseoPairingLink <url>` pairs with a relay pairing link and connects on launch
- `-PaseoSelectTerminal first|<terminalId>|new` opens a terminal on launch (`new` creates one in the first workspace; throwaway daemons only)
- `-PaseoTerminalType 'echo hi\r'` types into the opened terminal through the emulator's input path once it's live
- `-PaseoResizeWindow 900x500` (macOS, with `-PaseoSnapshot`) resizes the window and takes a third snapshot
- `-PaseoSelectWorkspace first|<workspaceId>` opens a workspace on launch (macOS: tabbed view)
- `-PaseoTerminalPassive YES` (macOS) terminal tabs never take focus, so attaching never claims the PTY size (for read-only runs against a live daemon)
- `-PaseoSplit horizontal[:0.3][,vertical…]` (macOS) splits the focused pane per entry and moves a hidden tab into each new pane, as a drag would
- `-PaseoSnapshot /path/prefix` writes a state summary (visible timelines, subscription, workspace layout) and on macOS a window PNG after launch
- `-PaseoOpenPluginPane <pluginId>/screen/<id>` | `<pluginId>/panel/<id>[/<workspaceId>]` | `sidebar:<row label>` | `command:<pluginId>/<commandId>` opens a plugin pane once contributions load; `-PaseoPluginPress <aria-label prefix>` clicks inside it; with `-PaseoSnapshot` this writes `<prefix>-plugin.png` and `<prefix>-plugin.txt` (contributions and the bridge RPC log)
