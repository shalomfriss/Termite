import Foundation

struct TerminalBlockRangeResolver {
    static func ranges(
        rowSemantics: [UInt8],
        visibleRows: [Bool],
        cursorRow: Int?
    ) -> [Range<Int>] {
        let rowCount = min(rowSemantics.count, visibleRows.count)
        guard rowCount > 0 else { return [] }
        var starts = (0..<rowCount).filter { rowSemantics[$0] == 1 }
        if let firstVisibleRow = (0..<rowCount).first(where: { visibleRows[$0] }),
           firstVisibleRow < (starts.first ?? rowCount) {
            starts.insert(firstVisibleRow, at: 0)
        }
        var ranges = starts.enumerated().map { index, start in
            var limit = index + 1 < starts.count ? starts[index + 1] : rowCount
            if index == starts.count - 1,
               let cursorRow,
               cursorRow > start,
               cursorRow < rowCount {
                limit = min(limit, cursorRow)
            }

            var end = limit
            while end > start + 1, !visibleRows[end - 1] {
                end -= 1
            }
            return start..<max(start + 1, end)
        }

        if let cursorRow,
           (0..<rowCount).contains(cursorRow),
           !ranges.contains(where: { $0.contains(cursorRow) }) {
            ranges.append(cursorRow..<(cursorRow + 1))
        }
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
    }
}
