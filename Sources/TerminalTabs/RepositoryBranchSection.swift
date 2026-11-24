import SwiftUI

struct RepositoryBranchSection: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Branch", systemImage: "arrow.triangle.branch")
                .font(.subheadline)
                .bold()

            if session.gitBranches.isEmpty {
                Text("No local branches found")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 3) {
                    ForEach(session.gitBranches, id: \.self) { branch in
                        Button {
                            session.switchGitBranch(to: branch)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: branch == session.gitBranch ? "checkmark" : "circle")
                                    .foregroundStyle(
                                        branch == session.gitBranch
                                            ? TerminalTheme.text
                                            : TerminalTheme.mutedText
                                    )
                                    .frame(width: 16)
                                Text(branch)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if branch == session.gitBranch {
                                    Text("Current")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 8)
                            .frame(minHeight: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            branch == session.gitBranch ? TerminalTheme.subtleFill : .clear,
                            in: .rect(cornerRadius: 6)
                        )
                        .disabled(branch == session.gitBranch)
                        .help(branch == session.gitBranch ? "Current branch" : "Switch to \(branch)")
                    }
                }
            }
        }
    }
}
