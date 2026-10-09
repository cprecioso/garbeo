// Generates Tests/PaseoKitTests/Fixtures/terminal-vectors.json from the upstream TypeScript
// protocol implementation, so the Swift codec is checked against the real encoder.
//
//   cp -R <paseo>/packages/protocol /tmp/vectors && cd /tmp/vectors
//   npm install zod semver tsx
//   PASEO_PROTOCOL_SRC=/tmp/vectors/src npx tsx <this repo>/scripts/generate-terminal-vectors.mts > terminal-vectors.json

const src = process.env.PASEO_PROTOCOL_SRC;
if (!src) throw new Error("Set PASEO_PROTOCOL_SRC to packages/protocol/src of a paseo checkout");

const frames = await import(`${src}/binary-frames/terminal.ts`);
const { renderTerminalSnapshotToAnsi } = await import(`${src}/terminal-snapshot.ts`);
const { TerminalStreamOpcode: Op } = frames;

const hex = (bytes: Uint8Array) => Buffer.from(bytes).toString("hex");
const utf8 = (text: string) => new TextEncoder().encode(text);
const cells = (text: string) => [...text].map((char) => ({ char }));

const state = {
  rows: 2,
  cols: 4,
  grid: [[{ char: "A", fg: 1, fgMode: 1, bold: true }, { char: "B" }], cells("CD")],
  scrollback: [cells("zz")],
  cursor: { row: 1, col: 2 },
};

const encodeCases = [
  { name: "output", opcode: Op.Output, slot: 7, payload: utf8("hello") },
  { name: "input", opcode: Op.Input, slot: 0, payload: utf8("echo hi\r") },
  { name: "input-utf8", opcode: Op.Input, slot: 255, payload: utf8("héllo ✓ 🐢") },
  { name: "input-slot-wraps", opcode: Op.Input, slot: 300, payload: utf8("x") },
  { name: "empty", opcode: Op.Output, slot: 1, payload: new Uint8Array(0) },
  {
    name: "resize-claim",
    opcode: Op.Resize,
    slot: 3,
    payload: frames.encodeTerminalResizePayload({ rows: 24, cols: 80, intent: "claim" }),
  },
  {
    name: "resize-update",
    opcode: Op.Resize,
    slot: 3,
    payload: frames.encodeTerminalResizePayload({ rows: 50, cols: 132, intent: "update" }),
  },
  { name: "snapshot", opcode: Op.Snapshot, slot: 9, payload: frames.encodeTerminalSnapshotPayload(state) },
  { name: "restore", opcode: Op.Restore, slot: 2, payload: utf8("\u001b[0mrestored") },
].map(({ name, opcode, slot, payload }) => ({
  name,
  opcode,
  slot,
  payloadHex: hex(payload),
  frameHex: hex(frames.encodeTerminalStreamFrame({ opcode, slot, payload })),
}));

const decodeCases = ["ff0102", "01", "", "0607", "0100", "0203616263"].map((frameHex) => {
  const decoded = frames.decodeTerminalStreamFrame(new Uint8Array(Buffer.from(frameHex, "hex")));
  return {
    frameHex,
    result: decoded ? { opcode: decoded.opcode, slot: decoded.slot, payloadHex: hex(decoded.payload) } : null,
  };
});

const snapshotStates = {
  plain: state,
  "wrapped-rows": {
    rows: 2,
    cols: 10,
    scrollback: [],
    scrollbackWrapped: [],
    grid: [cells("ABCDEFGHIJ"), cells("KLMNOP")],
    gridWrapped: [true, false],
    cursor: { row: 1, col: 6 },
  },
  "legacy-no-wrap-flags": {
    rows: 2,
    cols: 10,
    scrollback: [],
    grid: [cells("ABCDEFGHIJ"), cells("KLMNOP")],
    cursor: { row: 1, col: 6 },
  },
  "colors-and-styles": {
    rows: 1,
    cols: 12,
    scrollback: [],
    grid: [
      [
        { char: "a", fg: 9, fgMode: 1 },
        { char: "b", bg: 3, bgMode: 1 },
        { char: "c", bg: 12, bgMode: 1, underline: true },
        { char: "d", fg: 208, fgMode: 2, italic: true },
        { char: "e", fg: 0x112233, fgMode: 3, bg: 0xaabbcc, bgMode: 3 },
        { char: "f", dim: true, inverse: true, strikethrough: true },
        { char: "g", fg: 4 },
        { char: " ", bg: 2, bgMode: 1 },
        { char: " " },
        { char: "" },
        { char: " " },
      ],
    ],
    cursor: { row: 0, col: 3, hidden: true, style: "bar", blink: false },
  },
  "cursor-styles": {
    rows: 1,
    cols: 2,
    scrollback: [],
    grid: [[]],
    cursor: { row: 0, col: 0, style: "underline" },
  },
  "cursor-block-steady": {
    rows: 1,
    cols: 2,
    scrollback: [],
    grid: [cells("x")],
    cursor: { row: 0, col: 1, style: "block", blink: false },
  },
};

const snapshots = Object.entries(snapshotStates).map(([name, value]) => ({
  name,
  stateJSON: JSON.stringify(value),
  ansiHex: hex(utf8(renderTerminalSnapshotToAnsi(value))),
}));

console.log(JSON.stringify({ encode: encodeCases, decode: decodeCases, snapshots }, null, 2));
