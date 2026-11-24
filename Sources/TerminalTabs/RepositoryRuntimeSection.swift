import SwiftUI

struct RepositoryRuntimeSection: View {
    @ObservedObject var session: TerminalSession
    let runtime: RepositoryContext.Runtime

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(runtime.kind.title, systemImage: runtime.kind.systemImage)
                    .font(.subheadline)
                    .bold()
                Spacer()
                Text(declarationDescription)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if runtime.installations.isEmpty {
                Text("No local \(runtime.kind.title) installations were found")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 3) {
                    ForEach(runtime.installations) { installation in
                        Button {
                            session.switchRepositoryRuntime(installation, kind: runtime.kind)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isActive(installation) ? "checkmark" : "circle")
                                    .foregroundStyle(
                                        isActive(installation) ? TerminalTheme.text : TerminalTheme.mutedText
                                    )
                                    .frame(width: 16)
                                Text(installation.version)
                                    .monospaced()
                                if matchesDeclaration(installation) {
                                    Text("project")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(installation.source)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .frame(minHeight: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            isActive(installation) ? TerminalTheme.subtleFill : .clear,
                            in: .rect(cornerRadius: 6)
                        )
                        .disabled(isActive(installation))
                        .help("Use \(runtime.kind.title) \(installation.version) in this shell")
                    }
                }
            }
        }
    }

    private var declarationDescription: String {
        if let declaredVersion = runtime.declaredVersion {
            "\(declaredVersion) · \(runtime.declarationSource)"
        } else {
            runtime.declarationSource
        }
    }

    private func isActive(_ installation: RepositoryContext.RuntimeInstallation) -> Bool {
        session.activeRepositoryRuntimePaths[runtime.kind] == installation.binPath
    }

    private func matchesDeclaration(_ installation: RepositoryContext.RuntimeInstallation) -> Bool {
        guard let declaredVersion = runtime.declaredVersion,
              declaredVersion.first?.isNumber == true else { return installation.isProjectLocal }
        return installation.version == declaredVersion
            || installation.version.hasPrefix(declaredVersion + ".")
    }
}
