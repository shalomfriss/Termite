import Foundation

struct TerminalTextPosition: Comparable, Equatable {
    let row: UInt64
    let column: Int

    static func < (lhs: TerminalTextPosition, rhs: TerminalTextPosition) -> Bool {
        lhs.row == rhs.row ? lhs.column < rhs.column : lhs.row < rhs.row
    }
}

struct TerminalTextSelection: Equatable {
    let anchor: TerminalTextPosition
    let extent: TerminalTextPosition

    var lowerBound: TerminalTextPosition { min(anchor, extent) }
    var upperBound: TerminalTextPosition { max(anchor, extent) }

    func columns(for row: UInt64, totalColumns: Int) -> Range<Int>? {
        guard totalColumns > 0, row >= lowerBound.row, row <= upperBound.row else { return nil }
        let lowerColumn = row == lowerBound.row ? lowerBound.column : 0
        let upperColumn = row == upperBound.row ? upperBound.column + 1 : totalColumns
        let clampedLower = min(max(0, lowerColumn), totalColumns)
        let clampedUpper = min(max(clampedLower, upperColumn), totalColumns)
        return clampedLower..<clampedUpper
    }

    func contains(row: UInt64, column: Int, totalColumns: Int) -> Bool {
        columns(for: row, totalColumns: totalColumns)?.contains(column) == true
    }
}

enum TerminalTextSelectionExtractor {
    static func text(
        cellRows: [[String]],
        firstRow: UInt64,
        selection: TerminalTextSelection
    ) -> String {
        var lines: [String] = []
        for (rowIndex, cells) in cellRows.enumerated() {
            let row = firstRow + UInt64(rowIndex)
            guard let columns = selection.columns(for: row, totalColumns: cells.count) else { continue }
            var line = columns.map { cells[$0] }.joined()
            while line.last == " " || line.last == "\t" { line.removeLast() }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
