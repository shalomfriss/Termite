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
                    TerminalCanvas(
                        session: session,
                        openDirectoryInNewTab: openDirectoryInNewTab
                    )
                    .id(session.id)

                    if store.graphicalMode,
                       isGraphicalPreviewPresented,
                       let item = session.graphicalPreviewItem {
                        GraphicalPreviewContainer(
                            width: $graphicalPreviewWidth,
                            containerWidth: geometry.size.width,
                            item: item,
                            collapse: collapseGraphicalPreview
                        )
                        .opacity(store.graphicalPreviewOpacity)
                        .shadow(color: .black.opacity(0.32), radius: 16, x: -6)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
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
                .animation(.smooth(duration: 0.2), value: isGraphicalPreviewPresented)
            }

            statusBar
        }
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(TerminalTheme.border, lineWidth: 1)
        }
        .onChange(of: store.graphicalMode) { _, isEnabled in
            if !isEnabled {
                isGraphicalPreviewPresented = false
                session.sendUserInput(Data("clear && ls\n".utf8))
            }
        }
        .onChange(of: isGraphicalPreviewPresented) { _, presented in
            guard !presented else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(260))
                session.showCurrentDirectoryGraphically()
            }
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

            Spacer(minLength: 12)

            TerminalBookmarksMenu(session: session)

            if session.repositoryContext != nil || session.gitBranch != nil {
                RepositoryContextButton(session: session)
            }
        }
        .font(.caption.monospaced())
        .foregroundStyle(TerminalTheme.mutedText)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(TerminalTheme.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TerminalTheme.border)
                .frame(height: 1)
        }
    }
}
