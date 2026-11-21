import CoreGraphics

struct TerminalBlockVisualLayout {
    let ranges: [Range<Int>]
    let rowOffsets: [CGFloat]
    let blockFrames: [CGRect]
    let hiddenRows: Set<Int>
    let collapsedVisibleRows: [Int: Int]

    static func make(
        ranges: [Range<Int>],
        rowCount: Int,
        cellHeight: CGFloat,
        viewportHeight: CGFloat,
        lastContentRow: Int,
        collapsedRangeStarts: Set<Int> = [],
        collapsedVisibleRows: [Int: Int] = [:],
        contentPadding: CGFloat = 20,
        blockSpacing: CGFloat = 10,
        topInset: CGFloat = 0
    ) -> TerminalBlockVisualLayout {
        guard rowCount > 0 else {
            return TerminalBlockVisualLayout(
                ranges: ranges,
                rowOffsets: [],
                blockFrames: [],
                hiddenRows: [],
                collapsedVisibleRows: [:]
            )
        }

        let resolvedCollapsedVisibleRows = Dictionary(uniqueKeysWithValues: ranges.compactMap {
            range -> (Int, Int)? in
            guard collapsedRangeStarts.contains(range.lowerBound), range.count > 1 else {
                return nil
            }
            let preferredRow = collapsedVisibleRows[range.lowerBound]
                .flatMap { range.contains($0) ? $0 : nil }
                ?? range.lowerBound
            return (range.lowerBound, preferredRow)
        })

        var rowOffsets = Array(repeating: CGFloat.zero, count: rowCount)
        var hiddenRows: Set<Int> = []
        var accumulatedOffset: CGFloat = ranges.isEmpty ? 0 : topInset
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
            let collapsedVisibleRow = range.flatMap {
                resolvedCollapsedVisibleRows[$0.lowerBound]
            }
            let isCollapsed = collapsedVisibleRow != nil
            if let range, let collapsedVisibleRow, range.contains(row) {
                if row != collapsedVisibleRow { hiddenRows.insert(row) }
                rowOffsets[row] = accumulatedOffset
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
            let visibleRow = resolvedCollapsedVisibleRows[range.lowerBound] ?? range.lowerBound
            let firstOffset = rowOffsets.indices.contains(visibleRow)
                ? rowOffsets[visibleRow]
                : 0
            let visibleRowCount = resolvedCollapsedVisibleRows[range.lowerBound] != nil
                ? 1
                : range.count
            return CGRect(
                x: 0,
                y: CGFloat(visibleRow) * cellHeight + firstOffset - contentPadding,
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
            collapsedVisibleRows: resolvedCollapsedVisibleRows
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
            if let visibleRow = collapsedVisibleRows[range.lowerBound] { return visibleRow }
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
