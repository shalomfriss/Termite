import CoreGraphics

enum TerminalBlockActionLayout {
    static let buttonSize: CGFloat = 22
    static let buttonGap: CGFloat = 4
    static let trailingInset: CGFloat = 10

    static func rects(
        actionCount: Int,
        trailingEdge: CGFloat,
        top: CGFloat
    ) -> [CGRect] {
        guard actionCount > 0 else { return [] }
        let totalWidth = CGFloat(actionCount) * buttonSize
            + CGFloat(actionCount - 1) * buttonGap
        let leadingEdge = trailingEdge - trailingInset - totalWidth
        return (0..<actionCount).map { index in
            CGRect(
                x: leadingEdge + CGFloat(index) * (buttonSize + buttonGap),
                y: top,
                width: buttonSize,
                height: buttonSize
            )
        }
    }
}
