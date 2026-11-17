import Foundation

struct TerminalBlockID: Hashable, Sendable {
    let sessionID: UUID
    let historyRow: UInt64
}
