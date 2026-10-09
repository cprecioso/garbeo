import AppKit
import Foundation
import Testing
@testable import PaseoTerminal
import SwiftTerm

/// Pins SwiftTerm behavior that `TerminalSession` depends on, so a version bump that changes it fails here.
@MainActor @Suite struct SwiftTermContractTests {
    private final class Recorder: TerminalViewDelegate {
        var sent: [[UInt8]] = []
        var sizes: [(Int, Int)] = []
        func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append(Array(data)) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { sizes.append((newCols, newRows)) }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    /// `RestoreReplyFilter` relies on SwiftTerm answering DSR 5 with `ESC[0n` and delivering replies in order.
    @Test func answersStatusReportAfterEarlierReplies() async throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let recorder = Recorder()
        view.terminalDelegate = recorder
        view.feed(byteArray: Array("\u{1b}[c".utf8)[...])
        view.feed(byteArray: Array(RestoreReplyFilter.barrierQuery)[...])
        for _ in 0..<40 where recorder.sent.count < 2 { try await Task.sleep(for: .milliseconds(25)) }
        let replies = recorder.sent.map { Data($0) }
        #expect(replies.count == 2)
        #expect(replies.first?.starts(with: Data("\u{1b}[?".utf8)) == true)
        #expect(replies.last == RestoreReplyFilter.barrierReply)
    }

    /// Grid changes from layout must reach `sizeChanged`; that's how resizes get to the daemon.
    @Test func frameChangesReportGridSize() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let recorder = Recorder()
        view.terminalDelegate = recorder
        view.setFrameSize(NSSize(width: 800, height: 600))
        let last = try #require(recorder.sizes.last)
        #expect(last.0 > 80)
    }
}

@Suite struct RestoreReplyFilterTests {
    @Test func dropsUntilBarrierReply() {
        var filter = RestoreReplyFilter()
        #expect(filter.filter(Data("a".utf8)) == Data("a".utf8))
        filter.beginRestore()
        #expect(filter.filter(Data("\u{1b}[?62;22c".utf8)) == nil)
        #expect(filter.filter(Data("x\u{1b}[0nls".utf8)) == Data("ls".utf8))
        #expect(!filter.isSuppressing)
        #expect(filter.filter(Data("\u{1b}[0n".utf8)) == Data("\u{1b}[0n".utf8))
    }

    @Test func barrierReplyAloneIsDropped() {
        var filter = RestoreReplyFilter()
        filter.beginRestore()
        #expect(filter.filter(RestoreReplyFilter.barrierReply) == nil)
        #expect(filter.filter(Data("a".utf8)) == Data("a".utf8))
    }

    @Test func timeoutLiftsSuppression() {
        var filter = RestoreReplyFilter()
        filter.beginRestore()
        filter.timeOut()
        #expect(filter.filter(Data("a".utf8)) == Data("a".utf8))
    }
}
