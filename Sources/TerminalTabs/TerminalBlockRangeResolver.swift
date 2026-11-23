import Foundation

struct TerminalBlockRangeResolver {
    static func mergingGraphicalOutputWithActivePrompt(
        ranges: [Range<Int>],
        graphicalRows: Set<Int>,
        cursorRow: Int?
    ) -> [Range<Int>] {
        guard let cursorRow, ranges.count > 1 else { return ranges }
        var result = ranges
        for index in 0..<(result.count - 1) {
            let graphicalRange = result[index]
            let promptRange = result[index + 1]
            guard graphicalRange.upperBound == cursorRow,
                  promptRange == cursorRow..<(cursorRow + 1),
                  graphicalRange.contains(where: graphicalRows.contains) else { continue }
            result.replaceSubrange(
                index...(index + 1),
                with: [graphicalRange.lowerBound..<promptRange.upperBound]
            )
            break
        }
        return result
    }

    static func collapsedVisibleRows(
        ranges: [Range<Int>],
        collapsedRangeStarts: Set<Int>,
        graphicalRows: Set<Int>,
        textRows: Set<Int>
    ) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for range in ranges where collapsedRangeStarts.contains(range.lowerBound) && range.count > 1 {
            guard let lastGraphicalRow = range.reversed().first(where: graphicalRows.contains),
                  let promptRow = range.reversed().first(where: {
                      $0 > lastGraphicalRow
                          && textRows.contains($0)
                          && !graphicalRows.contains($0)
                  }) else { continue }
            result[range.lowerBound] = promptRow
        }
        return result
    }

    static func normalizedSemantics(
        rowSemantics: [UInt8],
        inputRows: [Bool]
    ) -> [UInt8] {
        var result = rowSemantics
        let rowCount = min(result.count, inputRows.count)
        for row in 0..<rowCount where inputRows[row] {
            let continuesPreviousInput = row > 0 && inputRows[row - 1]
            // A command may wrap across several terminal rows, but it still has
            // only one semantic beginning. Some shells copy the input semantic
            // marker onto every wrapped row, so explicitly clear those duplicate
            // starts instead of turning each visual line into its own block.
            result[row] = continuesPreviousInput ? 0 : 1
        }
        return result
    }

    static func ranges(
        rowSemantics: [UInt8],
        visibleRows: [Bool],
        cursorRow: Int?,
        inputRows: [Bool] = []
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
               cursorRow < rowCount,
               !(inputRows.indices.contains(cursorRow) && inputRows[cursorRow]) {
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
