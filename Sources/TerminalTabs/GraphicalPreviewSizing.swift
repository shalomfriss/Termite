import CoreGraphics

enum GraphicalPreviewSizing {
    static let minimumWidth: CGFloat = 240
    static let defaultWidth: CGFloat = 360
    static let maximumWidth: CGFloat = 720
    static let minimumUncoveredWidth: CGFloat = 120
    static let resizeStep: CGFloat = 40

    static func clampedWidth(_ requestedWidth: CGFloat, containerWidth: CGFloat) -> CGFloat {
        let availableWidth = max(0, containerWidth - minimumUncoveredWidth)
        let maximumAllowedWidth = min(maximumWidth, availableWidth)
        let minimumAllowedWidth = min(minimumWidth, maximumAllowedWidth)
        return min(max(requestedWidth, minimumAllowedWidth), maximumAllowedWidth)
    }
}
