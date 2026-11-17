import CoreGraphics

struct TerminalGraphicalRowCoverage {
    static func range(
        placementRow: Int,
        cellOffsetY: CGFloat,
        pixelHeight: CGFloat,
        layoutRowHeight: Int,
        rowCount: Int,
        cellHeight: CGFloat
    ) -> Range<Int>? {
        guard rowCount > 0,
              cellHeight > 0,
              (0..<rowCount).contains(placementRow) else { return nil }

        let imageMinY = CGFloat(placementRow) * cellHeight + cellOffsetY
        let imageMaxY = imageMinY + max(1, pixelHeight)
        let pixelLowerBound = Int(floor(imageMinY / cellHeight))
        let pixelUpperBound = Int(ceil(imageMaxY / cellHeight))
        let lowerBound = max(0, min(placementRow, pixelLowerBound))
        let upperBound = min(
            rowCount,
            max(
                placementRow + max(1, layoutRowHeight),
                pixelUpperBound
            )
        )

        guard lowerBound < upperBound else { return nil }
        return lowerBound..<upperBound
    }
}
