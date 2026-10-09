# Paseo Swift

A native SwiftUI client (macOS + iOS) for [Paseo](https://paseo.sh), the agentic development environment. It connects straight to a Paseo daemon over its WebSocket protocol.

## Features

- Connect to a daemon by address (`127.0.0.1:6767`, `host:port`, `ws(s)://…`), with an optional password stored in the Keychain
- Live sidebar: projects → workspaces → agents, with status, diff stats, and permission badges, kept in sync through daemon subscriptions
- Agent timeline: markdown replies, collapsible reasoning, tool calls (shell, read, edit diffs, search, fetch, sub-agents), task lists, errors. Streams live, with "load earlier" paging
- Send messages (optimistic, confirmed when the daemon echoes them), stop a running turn, change permission mode, archive
- Answer permission requests inline (provider-supplied actions or Allow/Deny)
- Create agents: workspace, provider, model, thinking level, mode, prompt
- Automatic reconnect with backoff; ping/pong liveness lease
- Plugin UI: screens, workspace/agent panels, sidebar items and Command Center items from [Paseo plugins](https://paseo.sh/docs/plugins) run unmodified in WKWebView panes (see [Plugins](#plugins))

## Layout

```
Package.swift            PaseoKit: protocol models, WebSocket client, timeline reducer
Sources/PaseoKit/
  DaemonClient.swift     hello handshake, requestId correlation, subscriptions, ping
  Models.swift           tolerant Decodable wire models (unknown fields and enum values are fine)
  Timeline.swift         merges live agent_stream deltas into projected pages; detects seq gaps
  Plugins.swift          plugin list/catalog/RPC requests and catalog-change events
Tests/PaseoKitTests/     unit tests, plus opt-in live daemon tests
App/PaseoSwift.xcodeproj multiplatform SwiftUI app target
App/PaseoSwift/          views + AppModel (observable store)
App/PaseoSwift/Plugins/  PluginStore, WKWebView runtime + bridge, PluginPaneView, sidebar/menu entries
App/PaseoSwift/PluginHost/plugin-host.js   generated JS host runtime (do not edit)
PluginHost/              source of the JS host runtime (React, react-native-web, Paseo plugin SDK)
```

## Build and run

```sh
open App/PaseoSwift.xcodeproj        # pick "My Mac" or an iOS Simulator, then Run

# or from the command line
xcodebuild -project App/PaseoSwift.xcodeproj -scheme PaseoSwift -destination 'platform=macOS' build
```

Requires Xcode 16+ (tested with Xcode 27), macOS 15 / iOS 18.

## Tests

```sh
swift test                                      # unit tests
PASEO_LIVE_URL=127.0.0.1:6767 swift test        # + read-only checks against a running daemon (incl. plugin list/catalog)
PASEO_LIVE_URL=127.0.0.1:6767 PASEO_LIVE_WRITE=1 swift test   # + creates real agents (cheap model)
```

The write tests create agents. When the daemon creates a workspace for them, cleanup archives that workspace only if it didn't exist before the test ran. Otherwise they archive just their own agent. Don't run them against a daemon you're actively using unless that's acceptable.

## Protocol notes

Speaks protocol version 1 as defined in `packages/protocol/src/messages.ts` of [getpaseo/paseo](https://github.com/getpaseo/paseo). The client advertises `owned_subscriptions`, `explicit_event_subscriptions`, and `selective_agent_timeline`, so it only receives streams for the agent being viewed:

1. `hello` → `status.server_info` (or `hello.rejected`)
2. `fetch_workspaces_request` / `fetch_agents_request` with `subscribe: {}` → `workspace_update` / `agent_update`
3. `session.events.set_subscription.request` for permission events
4. `agent.timeline.set_subscription.request` + `fetch_agent_timeline_request` (tail) for the open agent; `agent_stream` deltas are merged by `seq`, and a gap or epoch change refetches the tail

## Plugins

Upstream Paseo has no webview contract for plugins. The daemon compiles each plugin's `index.client.tsx` into a CommonJS bundle and ships it in `plugin.catalog.get.response`; the official app `eval`s it with a `require` that hands out its own React, React Native, TanStack Query, zod and `@getpaseo/plugin` modules, then renders the contributed components in its own tree. This client does the same inside a WKWebView:

- `PluginHost/` is a small JS host (React 19.1 + react-native-web + the Paseo plugin/client SDK) that ports upstream's `runPluginClientBundle`, its `require` map, providers (`QueryClientProvider`, `PaseoApiProvider`, `PluginRpcProvider`, `PluginClientStateProvider`) and the host-supplied modules (`@getpaseo/plugin/client/ui`, `/client/react-native`, `useSettings`, `useHosts`, Lucide icons by name). It is bundled into `App/PaseoSwift/PluginHost/plugin-host.js`, which is committed so the app builds without Node.
- A hidden **registry** page per connection runs every client bundle, reports contributions (screens, panels, Command Center items, settings screens) and renders sidebar items headlessly: the rows a plugin draws with `SidebarRow` show up as native rows under **Plugins** in the sidebar, and presses run the plugin's own `onPress`.
- Each open **pane** (`PluginPaneView`, a self-contained view any container can host) runs its own page that renders one screen or panel with the upstream props (`theme`, `host`, `layout`, `navigation`, `params` / `workspaceId` / `agentId`).
- Bridge: pages are served from `paseo-plugin://host/` by a `WKURLSchemeHandler`; navigation anywhere else is cancelled and http(s) links open in the system browser. The init payload (bundles, target, theme from native semantic colors, workspace/agent snapshots) is injected with a `WKUserScript`; JS calls the app through a `WKScriptMessageHandlerWithReply`. `useRpc` / `ctx.rpc` go through the app's own connection as `plugin.rpc.invoke.request`. `usePaseo()` gets a real `@getpaseo/client` `PaseoApi` whose socket the app opens natively and relays (the daemon rejects WebSocket upgrades from unlisted origins, which includes the custom scheme).
- `status.plugin_catalog_changed` reloads the catalog and rebuilds pages; `status.plugin_settings_changed` refreshes `useSettings`.

Where they show up: sidebar items, legacy sidebar items and global commands in the sidebar's **Plugins** section; workspace panels and workspace commands in a workspace row's context menu; workspace/agent panels and commands in the agent toolbar's **Plugins** menu. Panes open in the detail column (a sheet on iPhone).

Not supported yet: composer pills, header buttons, slash commands, attachment sources, themes, timeline transformers/renderers, sidebar popovers (they register without error but don't render), and the `paseo` version check on `requirements`.

Rebuilding the JS host (needs Node and a getpaseo/paseo checkout at the pinned commit in `PluginHost/build.mjs`; the SDK is compiled from source rather than npm):

```sh
git clone https://github.com/getpaseo/paseo /tmp/paseo-src/paseo   # then check out the pinned ref
cd PluginHost && npm install && PASEO_SRC=/tmp/paseo-src/paseo npm run build
```

## Not yet supported

- Relay / QR pairing (needs NaCl box E2EE), so remote hosts must be reachable directly (LAN, Tailscale, SSH tunnel)
- Terminals, git diff/commit/PR panes, file explorer, schedules, voice
- Image attachments

## Debug aids (DEBUG builds)

- `-PaseoSelectAgent first|<agentId>` opens an agent on launch
- `-PaseoSnapshot /path/prefix` writes a state summary (and on macOS a window PNG) after launch
- `-PaseoOpenPluginPane <pluginId>/screen/<id>` | `<pluginId>/panel/<id>[/<workspaceId>]` | `sidebar:<row label>` | `command:<pluginId>/<commandId>` opens a plugin pane once contributions load; `-PaseoPluginPress <aria-label prefix>` clicks inside it; with `-PaseoSnapshot` this writes `<prefix>-plugin.png` and `<prefix>-plugin.txt` (contributions and the bridge RPC log)
