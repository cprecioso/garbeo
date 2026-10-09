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

## Layout

```
Package.swift            PaseoKit: protocol models, WebSocket client, timeline reducer
Sources/PaseoKit/
  DaemonClient.swift     hello handshake, requestId correlation, subscriptions, ping
  Models.swift           tolerant Decodable wire models (unknown fields and enum values are fine)
  Timeline.swift         merges live agent_stream deltas into projected pages; detects seq gaps
Tests/PaseoKitTests/     unit tests, plus opt-in live daemon tests
App/PaseoSwift.xcodeproj multiplatform SwiftUI app target
App/PaseoSwift/          views + AppModel (observable store)
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
PASEO_LIVE_URL=127.0.0.1:6767 swift test        # + read-only checks against a running daemon
PASEO_LIVE_URL=127.0.0.1:6767 PASEO_LIVE_WRITE=1 swift test   # + creates real agents (cheap model)
```

The write tests create agents. When the daemon creates a workspace for them, cleanup archives that workspace only if it didn't exist before the test ran. Otherwise they archive just their own agent. Don't run them against a daemon you're actively using unless that's acceptable.

## Protocol notes

Speaks protocol version 1 as defined in `packages/protocol/src/messages.ts` of [getpaseo/paseo](https://github.com/getpaseo/paseo). The client advertises `owned_subscriptions`, `explicit_event_subscriptions`, and `selective_agent_timeline`, so it only receives streams for the agent being viewed:

1. `hello` → `status.server_info` (or `hello.rejected`)
2. `fetch_workspaces_request` / `fetch_agents_request` with `subscribe: {}` → `workspace_update` / `agent_update`
3. `session.events.set_subscription.request` for permission events
4. `agent.timeline.set_subscription.request` + `fetch_agent_timeline_request` (tail) for the open agent; `agent_stream` deltas are merged by `seq`, and a gap or epoch change refetches the tail

## Not yet supported

- Relay / QR pairing (needs NaCl box E2EE), so remote hosts must be reachable directly (LAN, Tailscale, SSH tunnel)
- Terminals, git diff/commit/PR panes, file explorer, schedules, voice
- Image attachments

## Debug aids (DEBUG builds)

- `-PaseoSelectAgent first|<agentId>` opens an agent on launch
- `-PaseoSnapshot /path/prefix` writes a state summary (and on macOS a window PNG) after launch
