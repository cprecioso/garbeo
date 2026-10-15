import Foundation

/// Recognizes emulator replies to queries the daemon already answers.
///
/// The daemon's headless emulator answers DA1, DSR 5/6, DECXCPR, OSC 10/11/12 and the kitty keyboard query
/// itself, so a second answer from SwiftTerm reaches the program late, as stray input (e.g. `gh secret set`
/// reads a leftover OSC 11 reply when it expects a cursor report). Like the upstream client, this also covers
/// DA2, DA3 and DECRQM, which the daemon leaves unanswered on purpose.
enum DaemonQueryReplies {
    /// Whether `data`, one reply as SwiftTerm emits it, answers such a query.
    static func contains(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        let reply = /\e\[[?>]?[0-9;]*[cnRu]|\e\[\??[0-9;]*\$y|\eP!\|[^\e]*\e\\|\e\]1[0-2];[^\a\e]*(?:\a|\e\\)/
        return text.wholeMatch(of: reply) != nil
    }
}
