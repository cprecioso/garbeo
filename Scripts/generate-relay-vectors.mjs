// Generates Tests/PaseoKitTests/Resources/relay-vectors.json from the upstream TypeScript
// relay implementation, so the Swift client is checked byte-for-byte against it.
//
// Usage (Node 23+, which strips TypeScript types natively):
//   mkdir /tmp/paseo-kat && cd /tmp/paseo-kat && npm init -y && npm pkg set type=module && npm i tweetnacl@1.0.3 base64-js@1.5.1
//   mkdir src && cp <paseo>/packages/relay/src/{crypto,base64,encrypted-channel}.ts \
//     <paseo>/packages/protocol/src/daemon-endpoints.ts src/
//   sed -i '' 's#"./\([a-z0-9-]*\).js"#"./\1.ts"#' src/*.ts
//   node Scripts/generate-relay-vectors.mjs /tmp/paseo-kat > Tests/PaseoKitTests/Resources/relay-vectors.json

import { createRequire } from "node:module";
import path from "node:path";
import { pathToFileURL } from "node:url";

const root = path.resolve(process.argv[2] ?? ".");
const require = createRequire(path.join(root, "package.json"));
const nacl = require("tweetnacl");
const load = (name) => import(pathToFileURL(path.join(root, "src", name)).href);
const crypto = await load("crypto.ts");
const channelModule = await load("encrypted-channel.ts");
const endpoints = await load("daemon-endpoints.ts");

const hex = (bytes) => Buffer.from(bytes).toString("hex");
const b64 = (bytes) => Buffer.from(bytes).toString("base64");
const bytesFrom = (start, count) => Uint8Array.from({ length: count }, (_, i) => (start + i) & 0xff);

// Deterministic PRNG: each call returns the next queued buffer. crypto.ts probes the PRNG once
// (ensurePrng) and installs its own if the probe throws, so let that probe pass first.
crypto.generateKeyPair();
let queued = [];
nacl.setPRNG((x, n) => {
  const next = queued.shift();
  if (!next || next.length !== n) throw new Error(`PRNG asked for ${n} bytes without a queued value`);
  x.set(next, 0);
});

const daemon = nacl.box.keyPair.fromSecretKey(bytesFrom(1, 32));
const client = nacl.box.keyPair.fromSecretKey(bytesFrom(0x41, 32));
const sharedKey = crypto.deriveSharedKey(client.secretKey, daemon.publicKey);
const daemonSide = crypto.deriveSharedKey(daemon.secretKey, client.publicKey);
if (hex(sharedKey) !== hex(daemonSide)) throw new Error("shared key mismatch");

const plaintexts = [
  { kind: "text", text: "" },
  { kind: "text", text: "hello" },
  { kind: "text", text: JSON.stringify({ type: "session", message: { type: "ping", note: "héllo ✓ 🚀" } }) },
  { kind: "binary", hex: hex(bytesFrom(0, 256)) },
];
const boxes = plaintexts.map((entry, index) => {
  const nonce = bytesFrom(0xa0 + index, 24);
  queued.push(nonce);
  const data = entry.kind === "text" ? entry.text : Uint8Array.from(Buffer.from(entry.hex, "hex")).buffer;
  const bundle = new Uint8Array(crypto.encrypt(sharedKey, data));
  if (hex(bundle.slice(0, 24)) !== hex(nonce)) throw new Error("PRNG override did not take effect");
  return { ...entry, nonceHex: hex(nonce), bundleHex: hex(bundle) };
});

// Daemon-side channel transcript: what a client receives after sending e2ee_hello.
async function transcript(capabilities) {
  const sent = [];
  const transport = {
    send: (data) => void sent.push(typeof data === "string" ? { text: data } : { binaryHex: hex(new Uint8Array(data)) }),
    close: () => {},
    onmessage: null,
    onclose: null,
    onerror: null,
  };
  const pending = channelModule.createDaemonChannel(transport, daemon);
  const hello = { type: "e2ee_hello", key: crypto.exportPublicKey(client.publicKey), ...(capabilities ? { capabilities } : {}) };
  transport.onmessage({ data: JSON.stringify(hello), isBinary: false });
  const channel = await pending;
  const textPlain = JSON.stringify({ type: "session", message: { type: "status", payload: { status: "ok" } } });
  queued.push(bytesFrom(0x10, 24));
  await channel.send(textPlain);
  const binaryPlain = bytesFrom(0xf0, 40);
  queued.push(bytesFrom(0x30, 24));
  await channel.send(binaryPlain.slice().buffer);
  return {
    hello: JSON.stringify(hello),
    frames: sent,
    plaintexts: [{ kind: "text", text: textPlain }, { kind: "binary", hex: hex(binaryPlain) }],
  };
}

const offer = {
  v: 2,
  serverId: "srv_test_123",
  daemonPublicKeyB64: crypto.exportPublicKey(daemon.publicKey),
  relay: { endpoint: "relay.paseo.sh:443", useTls: true },
};
const offerUrl = `https://app.paseo.sh/#offer=${Buffer.from(JSON.stringify(offer), "utf8").toString("base64url")}`;
const relayUri = endpoints.serializeRelayConnectionUri({ offer, password: "p@ss word" });

const out = {
  source: "getpaseo/paseo packages/relay + packages/protocol (tweetnacl 1.0.3)",
  daemonSecretKeyHex: hex(daemon.secretKey),
  daemonPublicKeyB64: b64(daemon.publicKey),
  clientSecretKeyHex: hex(client.secretKey),
  clientPublicKeyB64: b64(client.publicKey),
  sharedKeyHex: hex(sharedKey),
  boxes,
  channelBinaryCapable: await transcript({ binaryCiphertext: true }),
  channelLegacy: await transcript(undefined),
  offer,
  offerUrl,
  relayUri,
  relayUriParsed: endpoints.parseRelayConnectionUri(relayUri),
  relayWebSocketUrls: [
    { endpoint: "relay.paseo.sh:443", useTls: true, serverId: "srv_test_123" },
    { endpoint: "[::1]:8080", useTls: false, serverId: "srv/with space" },
  ].map((params) => ({ ...params, url: endpoints.buildRelayWebSocketUrl({ ...params, role: "client" }) })),
};
process.stdout.write(JSON.stringify(out, null, 2) + "\n");
