import Foundation

// Binary terminal stream frames, mirroring `packages/protocol/src/binary-frames/terminal.ts`:
// one opcode byte, one slot byte (the daemon-assigned stream id), then the payload.

public enum TerminalStreamOpcode: UInt8, Sendable {
    /// Daemon → client: raw PTY output bytes.
    case output = 0x01
    /// Client → daemon: UTF-8 keyboard input.
    case input = 0x02
    /// Client → daemon: JSON `{rows, cols, intent}`.
    case resize = 0x03
    /// Daemon → client: JSON `TerminalState` (legacy restore, no `restore` option on subscribe).
    case snapshot = 0x04
    /// Daemon → client: ANSI that repaints the screen (sent when subscribing with `restore`).
    case restore = 0x05
}

public struct TerminalStreamFrame: Sendable, Equatable {
    public var opcode: TerminalStreamOpcode
    public var slot: UInt8
    public var payload: Data

    public init(opcode: TerminalStreamOpcode, slot: UInt8, payload: Data = Data()) {
        self.opcode = opcode
        self.slot = slot
        self.payload = payload
    }

    /// Like the TS encoder, slots outside 0...255 are truncated to their low byte.
    public init(opcode: TerminalStreamOpcode, slot: Int, payload: Data = Data()) {
        self.init(opcode: opcode, slot: UInt8(truncatingIfNeeded: slot), payload: payload)
    }

    public func encoded() -> Data {
        var bytes = Data(capacity: 2 + payload.count)
        bytes.append(opcode.rawValue)
        bytes.append(slot)
        bytes.append(payload)
        return bytes
    }

    /// Returns nil for frames shorter than two bytes or with an unknown opcode.
    public init?(decoding bytes: Data) {
        guard bytes.count >= 2, let opcode = TerminalStreamOpcode(rawValue: bytes[bytes.startIndex]) else {
            return nil
        }
        self.opcode = opcode
        slot = bytes[bytes.startIndex + 1]
        payload = Data(bytes.dropFirst(2))
    }
}

public enum TerminalResizeIntent: String, Sendable, Codable {
    /// Take ownership of the PTY size (focus, tap, typing). Applies even if the size is unchanged.
    case claim
    /// Follow-up geometry change; ignored by the daemon unless this connection owns the size.
    case update
}

public struct TerminalSize: Sendable, Hashable, Codable {
    public var rows: Int
    public var cols: Int

    public init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
    }
}

public enum TerminalFramePayload {
    /// Byte-identical to `JSON.stringify({rows, cols, intent})`.
    public static func resize(_ size: TerminalSize, intent: TerminalResizeIntent?) -> Data {
        var json = "{\"rows\":\(size.rows),\"cols\":\(size.cols)"
        if let intent { json += ",\"intent\":\"\(intent.rawValue)\"" }
        json += "}"
        return Data(json.utf8)
    }
}

// MARK: - Snapshot state

public struct TerminalCell: Codable, Sendable, Hashable {
    public var char: String
    public var fg: Int?
    public var bg: Int?
    public var fgMode: Int?
    public var bgMode: Int?
    public var bold: Bool?
    public var italic: Bool?
    public var underline: Bool?
    public var dim: Bool?
    public var inverse: Bool?
    public var strikethrough: Bool?

    public init(char: String) { self.char = char }
}

public struct TerminalCursor: Codable, Sendable, Hashable {
    public var row: Int
    public var col: Int
    public var hidden: Bool?
    public var style: String?
    public var blink: Bool?
}

/// `TerminalState` from `messages.ts`. Carried by the legacy `Snapshot` opcode.
public struct TerminalState: Codable, Sendable, Hashable {
    public var rows: Int
    public var cols: Int
    public var grid: [[TerminalCell]]
    public var scrollback: [[TerminalCell]]
    public var cursor: TerminalCursor
    public var title: String?
    public var gridWrapped: [Bool]?
    public var scrollbackWrapped: [Bool]?
}

// MARK: - Snapshot → ANSI

extension TerminalState {
    /// Port of `renderTerminalSnapshotToAnsi` (`terminal-snapshot.ts`). The daemon runs the same
    /// function for `Restore` frames; the client needs it only for legacy `Snapshot` frames.
    public func renderANSI() -> String {
        let rows = scrollback + grid
        let wrapFlags = (scrollbackWrapped ?? []) + (gridWrapped ?? [])
        // With per-row soft-wrap flags, logical lines replay unbroken with autowrap on so the
        // emulator can reflow them later. Without them, replay verbatim: autowrap off, newline per row.
        let hasWrapInfo = wrapFlags.count == rows.count
        var out = hasWrapInfo ? "" : "\u{1b}[?7l"

        for (index, row) in rows.enumerated() {
            let continues = hasWrapInfo && wrapFlags[index]
            out += Self.render(row: row, padTo: continues ? cols : nil)
            if index < rows.count - 1, !continues { out += "\r\n" }
        }

        out += "\u{1b}[0m"
        if let style = cursor.style {
            let blinkOff = cursor.blink == false
            let code = switch style {
            case "block": blinkOff ? 2 : 1
            case "underline": blinkOff ? 4 : 3
            default: blinkOff ? 6 : 5
            }
            out += "\u{1b}[\(code) q"
        }
        out += "\u{1b}[\(cursor.row + 1);\(cursor.col + 1)H"
        out += cursor.hidden == true ? "\u{1b}[?25l" : "\u{1b}[?25h"
        if !hasWrapInfo { out += "\u{1b}[?7h" }
        return out
    }

    private struct Style: Equatable {
        var fg, bg, fgMode, bgMode: Int?
        var bold = false, italic = false, underline = false, dim = false, inverse = false, strikethrough = false

        init() {}

        init(_ cell: TerminalCell) {
            fg = cell.fg
            bg = cell.bg
            fgMode = cell.fgMode
            bgMode = cell.bgMode
            bold = cell.bold ?? false
            italic = cell.italic ?? false
            underline = cell.underline ?? false
            dim = cell.dim ?? false
            inverse = cell.inverse ?? false
            strikethrough = cell.strikethrough ?? false
        }

        var sgr: String {
            var codes = ["0"]
            if bold { codes.append("1") }
            if dim { codes.append("2") }
            if italic { codes.append("3") }
            if underline { codes.append("4") }
            if inverse { codes.append("7") }
            if strikethrough { codes.append("9") }
            if let fg, let fgMode { codes += Self.color(mode: fgMode, value: fg, background: false) }
            if let bg, let bgMode { codes += Self.color(mode: bgMode, value: bg, background: true) }
            return "\u{1b}[\(codes.joined(separator: ";"))m"
        }

        static func color(mode: Int, value: Int, background: Bool) -> [String] {
            switch mode {
            case 1:
                value >= 8 ? [String((background ? 100 : 90) + value - 8)] : [String((background ? 40 : 30) + value)]
            case 2:
                [background ? "48" : "38", "5", String(value)]
            case 3:
                [background ? "48" : "38", "2", String((value >> 16) & 0xff), String((value >> 8) & 0xff), String(value & 0xff)]
            default:
                []
            }
        }
    }

    private static func render(row: [TerminalCell], padTo: Int?) -> String {
        let length = max(contentLength(row), padTo ?? 0)
        var out = ""
        var previous = Style()
        for index in 0..<length {
            let cell = index < row.count ? row[index] : TerminalCell(char: " ")
            let style = Style(cell)
            if style != previous {
                out += style.sgr
                previous = style
            }
            out += cell.char.isEmpty ? " " : cell.char
        }
        if previous != Style() { out += "\u{1b}[0m" }
        return out
    }

    private static func contentLength(_ row: [TerminalCell]) -> Int {
        for index in row.indices.reversed() {
            let cell = row[index]
            if cell.char != " " || Style(cell) != Style() { return index + 1 }
        }
        return 0
    }
}
