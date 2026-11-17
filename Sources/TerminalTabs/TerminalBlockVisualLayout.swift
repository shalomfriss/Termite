import CoreGraphics

struct TerminalBlockVisualLayout {
    let ranges: [Range<Int>]
    let rowOffsets: [CGFloat]
    let blockFrames: [CGRect]
    let hiddenRows: Set<Int>
    let collapsedRangeStarts: Set<Int>

    static func make(
        ranges: [Range<Int>],
        rowCount: Int,
        cellHeight: CGFloat,
        viewportHeight: CGFloat,
        lastContentRow: Int,
        collapsedRangeStarts: Set<Int> = [],
        contentPadding: CGFloat = 20,
        blockSpacing: CGFloat = 10
    ) -> TerminalBlockVisualLayout {
        guard rowCount > 0 else {
            return TerminalBlockVisualLayout(
                ranges: ranges,
                rowOffsets: [],
                blockFrames: [],
                hiddenRows: [],
                collapsedRangeStarts: []
            )
        }

        var rowOffsets = Array(repeating: CGFloat.zero, count: rowCount)
        var hiddenRows: Set<Int> = []
        var accumulatedOffset: CGFloat = 0
        var rangeIndex = 0
        for row in 0..<rowCount {
            if rangeIndex < ranges.count, row == ranges[rangeIndex].lowerBound {
                if rangeIndex > 0 {
                    let precedingRange = ranges[rangeIndex - 1]
                    let gap = precedingRange.upperBound..<ranges[rangeIndex].lowerBound
                    if !gap.isEmpty {
                        hiddenRows.formUnion(gap)
                        accumulatedOffset -= CGFloat(gap.count) * cellHeight
                    }
                }
                accumulatedOffset += contentPadding
            }
            let range = rangeIndex < ranges.count ? ranges[rangeIndex] : nil
            let isCollapsed = range.map {
                collapsedRangeStarts.contains($0.lowerBound) && $0.count > 1
            } ?? false
            if let range, isCollapsed, row > range.lowerBound, range.contains(row) {
                hiddenRows.insert(row)
                rowOffsets[row] = rowOffsets[range.lowerBound]
                    - CGFloat(row - range.lowerBound) * cellHeight
            } else {
                rowOffsets[row] = accumulatedOffset
            }
            if rangeIndex < ranges.count, row + 1 == ranges[rangeIndex].upperBound {
                if isCollapsed {
                    accumulatedOffset -= CGFloat(ranges[rangeIndex].count - 1) * cellHeight
                }
                accumulatedOffset += contentPadding + blockSpacing
                rangeIndex += 1
            }
        }

        var blockFrames = ranges.map { range in
            let firstOffset = rowOffsets.indices.contains(range.lowerBound)
                ? rowOffsets[range.lowerBound]
                : 0
            let visibleRowCount = collapsedRangeStarts.contains(range.lowerBound) && range.count > 1
                ? 1
                : range.count
            return CGRect(
                x: 0,
                y: CGFloat(range.lowerBound) * cellHeight + firstOffset - contentPadding,
                width: 0,
                height: CGFloat(visibleRowCount) * cellHeight + contentPadding * 2
            )
        }

        let clampedLastRow = min(max(0, lastContentRow), rowCount - 1)
        var contentBottom = CGFloat(clampedLastRow + 1) * cellHeight + rowOffsets[clampedLastRow]
        for (index, range) in ranges.enumerated() where range.lowerBound <= clampedLastRow {
            contentBottom = max(contentBottom, blockFrames[index].maxY)
        }
        let overflow = max(0, contentBottom - viewportHeight)
        if overflow > 0 {
            rowOffsets = rowOffsets.map { $0 - overflow }
            blockFrames = blockFrames.map { $0.offsetBy(dx: 0, dy: -overflow) }
        }

        return TerminalBlockVisualLayout(
            ranges: ranges,
            rowOffsets: rowOffsets,
            blockFrames: blockFrames,
            hiddenRows: hiddenRows,
            collapsedRangeStarts: collapsedRangeStarts
        )
    }

    func blockRange(at visualY: CGFloat) -> Range<Int>? {
        for index in blockFrames.indices.reversed() {
            let frame = blockFrames[index]
            if frame.minY <= visualY, visualY < frame.maxY { return ranges[index] }
        }
        return nil
    }

    func row(at visualY: CGFloat, cellHeight: CGFloat, nearest: Bool) -> Int? {
        for row in rowOffsets.indices where !hiddenRows.contains(row) {
            let minY = CGFloat(row) * cellHeight + rowOffsets[row]
            if minY <= visualY, visualY < minY + cellHeight { return row }
        }
        if let range = blockRange(at: visualY) {
            if collapsedRangeStarts.contains(range.lowerBound) { return range.lowerBound }
            let contentTop = CGFloat(range.lowerBound) * cellHeight + rowOffsets[range.lowerBound]
            return visualY < contentTop ? range.lowerBound : range.upperBound - 1
        }
        guard nearest else { return nil }
        return rowOffsets.indices.filter { !hiddenRows.contains($0) }.min { lhs, rhs in
            let lhsCenter = CGFloat(lhs) * cellHeight + rowOffsets[lhs] + cellHeight / 2
            let rhsCenter = CGFloat(rhs) * cellHeight + rowOffsets[rhs] + cellHeight / 2
            return abs(lhsCenter - visualY) < abs(rhsCenter - visualY)
        }
    }
}
