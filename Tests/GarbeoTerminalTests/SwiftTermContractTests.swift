import AppKit
import Foundation
import Testing
@testable import GarbeoTerminal
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

    /// `DaemonQueryReplies` must recognize SwiftTerm's own answers to the queries the daemon answers.
    @Test func repliesToDaemonAnsweredQueriesAreRecognized() async throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let recorder = Recorder()
        view.terminalDelegate = recorder
        let queries = ["\u{1b}[c", "\u{1b}[>c", "\u{1b}[5n", "\u{1b}[6n", "\u{1b}[?6n", "\u{1b}]11;?\u{1b}\\",
                       "\u{1b}]10;?\u{07}", "\u{1b}[?2004$p"]
        for query in queries { view.feed(byteArray: Array(query.utf8)[...]) }
        for _ in 0..<40 where recorder.sent.count < queries.count { try await Task.sleep(for: .milliseconds(25)) }
        #expect(recorder.sent.count == queries.count)
        for reply in recorder.sent {
            #expect(DaemonQueryReplies.contains(Data(reply)), "\(String(decoding: reply, as: UTF8.self).debugDescription)")
        }
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

@Suite struct DaemonQueryRepliesTests {
    @Test func matchesQueryReplies() {
        for reply in ["\u{1b}[?62;22c", "\u{1b}[>0;276;0c", "\u{1b}[0n", "\u{1b}[12;1R", "\u{1b}[?12;1;1R",
                      "\u{1b}]11;rgb:ffff/ffff/ffff\u{1b}\\", "\u{1b}]10;rgb:0/0/0\u{07}", "\u{1b}[?2004;2$y",
                      "\u{1b}[?0u", "\u{1b}P!|00000000\u{1b}\\"] {
            #expect(DaemonQueryReplies.contains(Data(reply.utf8)), "\(reply.debugDescription)")
        }
    }

    @Test func passesOtherEmulatorOutput() {
        // SGR and X10 mouse reports, focus in, an OSC 4 palette reply, an XTVERSION reply.
        for data in ["\u{1b}[<0;3;4M", "\u{1b}[M !!", "\u{1b}[I", "\u{1b}]4;1;rgb:ffff/0/0\u{1b}\\",
                     "\u{1b}P>|SwiftTerm\u{1b}\\", "a"] {
            #expect(!DaemonQueryReplies.contains(Data(data.utf8)), "\(data.debugDescription)")
        }
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
