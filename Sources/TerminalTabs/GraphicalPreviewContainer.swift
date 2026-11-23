import SwiftUI

struct GraphicalPreviewContainer: View {
    @Binding var width: CGFloat

    let containerWidth: CGFloat
    let item: GraphicalFileItem
    let collapse: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            GraphicalPreviewResizeHandle(
                width: $width,
                containerWidth: containerWidth
            )

            GraphicalFilePreviewPane(item: item, close: collapse)
                .frame(width: effectiveWidth)
        }
    }

    private var effectiveWidth: CGFloat {
        GraphicalPreviewSizing.clampedWidth(
            width,
            containerWidth: containerWidth
        )
    }
}
