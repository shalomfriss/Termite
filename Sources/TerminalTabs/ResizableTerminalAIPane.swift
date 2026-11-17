import AppKit
import SwiftUI

struct ResizableTerminalAIPane: View {
    static let minimumPaneHeight: CGFloat = 180
    static let dividerHeight: CGFloat = 12

    @ObservedObject var session: TerminalSession
    @ObservedObject var store: TerminalStore
    @ObservedObject var settings: AISettings
    let openDirectoryInNewTab: (URL) -> Void

    @State private var aiPanelHeight: CGFloat = 280
    @State private var dragStartHeight: CGFloat?
    @State private var isHoveringDivider = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                TerminalSurface(
                    session: session,
                    store: store,
                    openDirectoryInNewTab: openDirectoryInNewTab
                )
                .frame(minHeight: Self.minimumPaneHeight)

                resizeHandle(containerHeight: geometry.size.height)

                AIConversationPanel(session: session, settings: settings)
                    .frame(
                        height: Self.clampedPanelHeight(
                            aiPanelHeight,
                            containerHeight: geometry.size.height
                        )
                    )
            }
            .onChange(of: geometry.size.height) { _, height in
                aiPanelHeight = Self.clampedPanelHeight(
                    aiPanelHeight,
                    containerHeight: height
                )
            }
        }
    }

    private func resizeHandle(containerHeight: CGFloat) -> some View {
        Rectangle()
            .fill(isHoveringDivider ? TerminalTheme.cyan.opacity(0.08) : .clear)
            .frame(height: Self.dividerHeight)
            .overlay {
                Capsule()
                    .fill(isHoveringDivider ? TerminalTheme.cyan.opacity(0.8) : .white.opacity(0.18))
                    .frame(width: 48, height: 3)
            }
            .contentShape(.rect)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isHoveringDivider = true
                    NSCursor.resizeUpDown.set()
                case .ended:
                    isHoveringDivider = false
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let startHeight = dragStartHeight ?? aiPanelHeight
                        dragStartHeight = startHeight
                        aiPanelHeight = Self.clampedPanelHeight(
                            startHeight - value.translation.height,
                            containerHeight: containerHeight
                        )
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
            .accessibilityLabel("Resize Terminal AI panel")
            .help("Drag to resize Terminal AI")
    }

    static func clampedPanelHeight(
        _ requestedHeight: CGFloat,
        containerHeight: CGFloat
    ) -> CGFloat {
        let maximumHeight = max(
            minimumPaneHeight,
            containerHeight - minimumPaneHeight - dividerHeight
        )
        return min(max(requestedHeight, minimumPaneHeight), maximumHeight)
    }
}
