import AppKit
import SwiftUI

struct GraphicalPreviewResizeHandle: View {
    @Binding var width: CGFloat
    let containerWidth: CGFloat

    @State private var dragStartWidth: CGFloat?
    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(isActive ? TerminalTheme.cyan.opacity(0.14) : .clear)
            .frame(width: GraphicalPreviewSizing.resizeHandleWidth)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(
                        isActive
                            ? TerminalTheme.cyan.opacity(0.9)
                            : Color.white.opacity(0.16)
                    )
                    .frame(width: isActive ? 2 : 1)
            }
            .contentShape(.rect)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isHovering = true
                    NSCursor.resizeLeftRight.set()
                case .ended:
                    isHovering = false
                    if !isDragging { NSCursor.arrow.set() }
                }
            }
            .onDisappear {
                NSCursor.arrow.set()
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        isDragging = true
                        NSCursor.resizeLeftRight.set()
                        let startWidth = dragStartWidth
                            ?? GraphicalPreviewSizing.clampedWidth(
                                width,
                                containerWidth: containerWidth
                            )
                        dragStartWidth = startWidth
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            width = GraphicalPreviewSizing.clampedWidth(
                                startWidth - value.translation.width,
                                containerWidth: containerWidth
                            )
                        }
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                        isDragging = false
                        if !isHovering { NSCursor.arrow.set() }
                    }
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

    private var isActive: Bool {
        isHovering || isDragging
    }
}
