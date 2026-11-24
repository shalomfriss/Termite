import SwiftUI

struct RepositoryContextPopover: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(TerminalTheme.text)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.repositoryContext?.displayName ?? "Repository")
                        .font(.headline)
                    Text(session.repositoryContext?.rootPath ?? session.workingDirectory)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                Button("Refresh repository tools", systemImage: "arrow.clockwise") {
                    session.refreshRepositoryContext()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .frame(width: 30, height: 30)
                .background(TerminalTheme.subtleFill, in: .rect(cornerRadius: 6))
                .help("Refresh branches and runtimes")
            }
            .padding(14)

            Divider()

            if session.repositoryContext == nil, session.gitBranch == nil {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Inspecting repository…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        RepositoryBranchSection(session: session)
                        if let runtimes = session.repositoryContext?.runtimes {
                            ForEach(runtimes) { runtime in
                                Divider()
                                RepositoryRuntimeSection(session: session, runtime: runtime)
                            }
                        }
                    }
                    .padding(14)
                }
                .frame(maxHeight: 430)
            }
        }
        .frame(width: 360)
        .background(TerminalTheme.surface)
        .foregroundStyle(TerminalTheme.text)
    }
}
