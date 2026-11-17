import SwiftUI

struct TerminalSurface: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var store: TerminalStore
    let openDirectoryInNewTab: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            TerminalCanvas(
                session: session,
                openDirectoryInNewTab: openDirectoryInNewTab
            )
            .id(session.id)

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

            if let branch = session.gitBranch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Git branch: \(branch)")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(TerminalTheme.cyan.opacity(0.08), in: .capsule)
                    .overlay {
                        Capsule().stroke(TerminalTheme.cyan.opacity(0.15), lineWidth: 1)
                    }
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
