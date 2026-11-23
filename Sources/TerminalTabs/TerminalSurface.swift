import SwiftUI

struct TerminalSurface: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var store: TerminalStore
    let openDirectoryInNewTab: (URL) -> Void

    @State private var graphicalPreviewWidth = GraphicalPreviewSizing.defaultWidth
    @State private var isGraphicalPreviewPresented = false

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack(alignment: .trailing) {
                    HStack(spacing: 0) {
                        TerminalCanvas(
                            session: session,
                            openDirectoryInNewTab: openDirectoryInNewTab
                        )
                        .id(session.id)

                        if store.graphicalMode,
                           store.graphicalPreviewLayoutMode == .resizeContent,
                           isGraphicalPreviewPresented,
                           let item = session.graphicalPreviewItem {
                            GraphicalPreviewContainer(
                                width: $graphicalPreviewWidth,
                                containerWidth: geometry.size.width,
                                item: item,
                                collapse: collapseGraphicalPreview
                            )
                        }
                    }

                    if store.graphicalMode,
                       store.graphicalPreviewLayoutMode == .overlay,
                       isGraphicalPreviewPresented,
                       let item = session.graphicalPreviewItem {
                        GraphicalPreviewContainer(
                            width: $graphicalPreviewWidth,
                            containerWidth: geometry.size.width,
                            item: item,
                            collapse: collapseGraphicalPreview
                        )
                        .shadow(color: .black.opacity(0.32), radius: 16, x: -6)
                    }

                    if store.graphicalMode,
                       !isGraphicalPreviewPresented,
                       let item = session.graphicalPreviewItem {
                        GraphicalPreviewDisclosureButton(item: item) {
                            withAnimation(.smooth(duration: 0.2)) {
                                isGraphicalPreviewPresented = true
                            }
                        }
                    }
                }
                .animation(
                    .smooth(duration: 0.2),
                    value: isGraphicalPreviewPresented
                )
            }

            statusBar
        }
        .clipShape(.rect(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(
                    store.graphicalMode
                        ? TerminalTheme.cyan.opacity(0.22)
                        : Color.white.opacity(0.06),
                    lineWidth: 1
                )
        }
        .shadow(
            color: store.graphicalMode
                ? TerminalTheme.cyan.opacity(0.08)
                : TerminalTheme.canvas.opacity(0.32),
            radius: 18,
            y: 8
        )
        .onChange(of: store.graphicalMode) { _, isEnabled in
            if !isEnabled { isGraphicalPreviewPresented = false }
        }
    }

    private func collapseGraphicalPreview() {
        withAnimation(.smooth(duration: 0.2)) {
            isGraphicalPreviewPresented = false
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Label(session.workingDirectory, systemImage: "folder.fill")
                .lineLimit(1)
                .truncationMode(.middle)
                .help(session.workingDirectory)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.045), in: .capsule)
                .overlay {
                    Capsule().stroke(Color.white.opacity(0.07), lineWidth: 1)
                }

            Spacer(minLength: 12)

            TerminalBookmarksMenu(session: session)

            if session.gitBranch != nil {
                GitBranchMenu(session: session)
            }
        }
        .font(.caption2.monospaced())
        .foregroundStyle(TerminalTheme.text.opacity(0.72))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(TerminalTheme.canvas.opacity(0.98))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
        }
    }
}
