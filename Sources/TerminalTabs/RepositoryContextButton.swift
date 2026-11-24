import SwiftUI

struct RepositoryContextButton: View {
    @ObservedObject var session: TerminalSession

    @State private var isPresented = false
    @State private var isHovering = false

    var body: some View {
        Button(action: presentRepositoryContext) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                Text(session.gitBranch ?? session.repositoryContext?.displayName ?? "Repository")
                    .lineLimit(1)
                    .truncationMode(.middle)
                if session.repositoryContext?.node != nil {
                    Text("N")
                        .accessibilityLabel("Node project")
                        .repositoryRuntimeBadge()
                }
                if session.repositoryContext?.python != nil {
                    Text("Py")
                        .accessibilityLabel("Python project")
                        .repositoryRuntimeBadge()
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .background(
                isHovering ? TerminalTheme.hoverFill : TerminalTheme.subtleFill,
                in: .rect(cornerRadius: 6)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(TerminalTheme.border, lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            RepositoryContextPopover(session: session)
        }
        .help("Change branch or repository runtime")
        .accessibilityLabel("Repository tools")
        .accessibilityValue(session.gitBranch ?? session.repositoryContext?.displayName ?? "Repository")
        .accessibilityHint("Opens branch, Node, and Python controls")
    }

    private func presentRepositoryContext() {
        session.refreshRepositoryContext()
        isPresented = true
    }
}

private extension View {
    func repositoryRuntimeBadge() -> some View {
        font(.caption.monospaced())
            .foregroundStyle(TerminalTheme.text)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(TerminalTheme.raised, in: .rect(cornerRadius: 4))
    }
}
