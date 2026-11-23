import CoreGraphics

enum GraphicalPreviewSizing {
    static let minimumWidth: CGFloat = 240
    static let defaultWidth: CGFloat = 360
    static let maximumWidth: CGFloat = 720
    static let minimumUncoveredWidth: CGFloat = 320
    static let resizeHandleWidth: CGFloat = 18
    static let resizeStep: CGFloat = 40

    static func clampedWidth(_ requestedWidth: CGFloat, containerWidth: CGFloat) -> CGFloat {
        let uncoveredWidth = min(
            minimumUncoveredWidth,
            max(0, containerWidth - minimumWidth - resizeHandleWidth)
        )
        let availableWidth = max(0, containerWidth - uncoveredWidth - resizeHandleWidth)
        let maximumAllowedWidth = min(maximumWidth, availableWidth)
        let minimumAllowedWidth = min(minimumWidth, maximumAllowedWidth)
        return min(max(requestedWidth, minimumAllowedWidth), maximumAllowedWidth)
    }
}
