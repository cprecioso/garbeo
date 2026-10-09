# Paseo Swift

A native SwiftUI client (macOS + iOS) for [Paseo](https://paseo.sh), the agentic development environment. It connects to a Paseo daemon over its WebSocket protocol, either directly or through the Paseo relay with end-to-end encryption.

## Features

- Connect to a daemon by address (`127.0.0.1:6767`, `host:port`, `ws(s)://…`), with an optional password stored in the Keychain
- Pair through the Paseo relay: scan the QR code from `paseo daemon pair` / Paseo Desktop (iOS), or paste the pairing link (both platforms). Traffic is end-to-end encrypted (Curve25519 + XSalsa20-Poly1305, wire-compatible with the official apps)
- Saved hosts list; relay daemon keys and passwords live in the Keychain. The sidebar footer shows whether the connection is direct or relayed
- Live sidebar: projects → workspaces → agents, with status, diff stats, and permission badges, kept in sync through daemon subscriptions
- Agent timeline: markdown replies, collapsible reasoning, tool calls (shell, read, edit diffs, search, fetch, sub-agents), task lists, errors. Streams live, with "load earlier" paging
- Send messages (optimistic, confirmed when the daemon echoes them), stop a running turn, change permission mode, archive
- Answer permission requests inline (provider-supplied actions or Allow/Deny)
- Create agents: workspace, provider, model, thinking level, mode, prompt
- Automatic reconnect with backoff; ping/pong liveness lease

## Layout

```
Package.swift            PaseoKit: protocol models, WebSocket client, timeline reducer (depends on swift-sodium)
Sources/PaseoKit/
  DaemonClient.swift     hello handshake, requestId correlation, subscriptions, ping
  DaemonTransport.swift  transport protocol + plain WebSocket transport; endpoint → transport selection
  RelayE2EETransport.swift  relay client channel: e2ee_hello/e2ee_ready, capability negotiation, framing
  RelayCrypto.swift      NaCl box (libsodium) matching packages/relay/src/crypto.ts
  Pairing.swift          pairing offers (#offer=), relay:// connection URIs, relay WebSocket URLs
  Models.swift           tolerant Decodable wire models (unknown fields and enum values are fine)
  Timeline.swift         merges live agent_stream deltas into projected pages; detects seq gaps
Tests/PaseoKitTests/     unit tests, plus opt-in live daemon tests
  Resources/relay-vectors.json  known-answer vectors generated from the upstream TypeScript
Scripts/generate-relay-vectors.mjs  regenerates those vectors (instructions inside)
App/PaseoSwift.xcodeproj multiplatform SwiftUI app target
App/PaseoSwift/          views + AppModel (observable store), HostStore (saved hosts), QR scanner
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

To test the relay end to end without touching your working daemon, run an isolated one with relay enabled and pair against it:

```sh
H=$(mktemp -d)
PASEO_LISTEN=127.0.0.1:47391 PASEO_RELAY_ENABLED=true PASEO_PASSWORD=pw paseo daemon run --home "$H" &
URL=$(paseo daemon pair --home "$H" --json | jq -r .url)
PASEO_LIVE_PAIRING_URL="$URL" PASEO_PASSWORD=pw swift test --filter LiveRelayTests
PASEO_LIVE_URL="$URL" PASEO_PASSWORD=pw swift test --filter LiveDaemonTests   # same read-only suite, over the relay
paseo daemon stop --home "$H"
```

The write tests create agents. When the daemon creates a workspace for them, cleanup archives that workspace only if it didn't exist before the test ran. Otherwise they archive just their own agent. Don't run them against a daemon you're actively using unless that's acceptable.

## Protocol notes

Speaks protocol version 1 as defined in `packages/protocol/src/messages.ts` of [getpaseo/paseo](https://github.com/getpaseo/paseo). The client advertises `owned_subscriptions`, `explicit_event_subscriptions`, and `selective_agent_timeline`, so it only receives streams for the agent being viewed:

1. `hello` → `status.server_info` (or `hello.rejected`)
2. `fetch_workspaces_request` / `fetch_agents_request` with `subscribe: {}` → `workspace_update` / `agent_update`
3. `session.events.set_subscription.request` for permission events
4. `agent.timeline.set_subscription.request` + `fetch_agent_timeline_request` (tail) for the open agent; `agent_stream` deltas are merged by `seq`, and a gap or epoch change refetches the tail

Relay connections (`packages/relay`, `packages/protocol/src/connection-offer.ts`, `daemon-endpoints.ts`):

- Pairing links: `https://app.paseo.sh/#offer=<base64url JSON {v:2, serverId, daemonPublicKeyB64, relay:{endpoint,useTls}}>`, `relay://host:port/<serverId>?key=…&ssl=true[&password=…]`, or `…#connect=<relay URI>`
- Socket: `wss://relay.paseo.sh/ws?serverId=…&role=client&v=2`
- Handshake: a fresh ephemeral Curve25519 keypair per connection; plaintext `{"type":"e2ee_hello","key":…,"capabilities":{"binaryCiphertext":true}}` re-sent every second until `{"type":"e2ee_ready"}`
- Frames: `[24-byte nonce][box]` with the `box.before` key. With `binaryCiphertext` negotiated, app text is a base64 text frame and app binary a raw binary frame; legacy peers get base64 text for both. Any other plaintext JSON after the handshake, or a frame that fails authentication, closes the socket
- The regular `hello` (including the password) then runs inside the encrypted channel. Over the relay, a wrong password shows up as a disconnect (the daemon's `hello.rejected` is lost behind its close), which the client reports as a likely password problem

## Not yet supported

- Opening `https://app.paseo.sh/#offer=…` links from other apps (needs associated domains); paste or scan them instead
- QR scanning on macOS (paste the link instead)
- Terminals, git diff/commit/PR panes, file explorer, schedules, voice
- Image attachments

## Debug aids (DEBUG builds)

- `-PaseoSelectAgent first|<agentId>` opens an agent on launch
- `-PaseoPairingLink <url>` pairs with a relay pairing link and connects on launch
- `-PaseoSnapshot /path/prefix` writes a state summary (and on macOS a window PNG) after launch
