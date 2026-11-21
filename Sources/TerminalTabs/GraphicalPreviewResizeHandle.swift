import AppKit
import SwiftUI

struct GraphicalPreviewResizeHandle: View {
    @Binding var width: CGFloat
    let containerWidth: CGFloat

    @State private var dragStartWidth: CGFloat?
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(isHovering ? TerminalTheme.cyan.opacity(0.12) : .clear)
            .frame(width: 10)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(
                        isHovering
                            ? TerminalTheme.cyan.opacity(0.9)
                            : Color.white.opacity(0.16)
                    )
                    .frame(width: isHovering ? 2 : 1)
            }
            .contentShape(.rect)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isHovering = true
                    NSCursor.resizeLeftRight.set()
                case .ended:
                    isHovering = false
                    NSCursor.arrow.set()
                }
            }
            .onDisappear {
                NSCursor.arrow.set()
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let startWidth = dragStartWidth
                            ?? GraphicalPreviewSizing.clampedWidth(
                                width,
                                containerWidth: containerWidth
                            )
                        dragStartWidth = startWidth
                        width = GraphicalPreviewSizing.clampedWidth(
                            startWidth - value.translation.width,
                            containerWidth: containerWidth
                        )
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
            .accessibilityElement()
            .accessibilityLabel("File preview width")
            .accessibilityValue("\(Int(effectiveWidth)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    width = GraphicalPreviewSizing.clampedWidth(
                        effectiveWidth + GraphicalPreviewSizing.resizeStep,
                        containerWidth: containerWidth
                    )
                case .decrement:
                    width = GraphicalPreviewSizing.clampedWidth(
                        effectiveWidth - GraphicalPreviewSizing.resizeStep,
                        containerWidth: containerWidth
                    )
                @unknown default:
                    break
                }
            }
            .help("Drag to resize the file preview")
    }

    private var effectiveWidth: CGFloat {
        GraphicalPreviewSizing.clampedWidth(width, containerWidth: containerWidth)
    }
}
