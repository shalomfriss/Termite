import SwiftUI

struct GitBranchMenu: View {
    @ObservedObject var session: TerminalSession

    @State private var isHovering = false

    var body: some View {
        Menu {
            if session.gitBranches.isEmpty {
                Button("No local branches") {}
                    .disabled(true)
                    .help("No local branches are available")
            } else {
                ForEach(session.gitBranches, id: \.self) { branch in
                    Button {
                        session.switchGitBranch(to: branch)
                    } label: {
                        if branch == session.gitBranch {
                            Label(branch, systemImage: "checkmark")
                        } else {
                            Text(branch)
                        }
                    }
                    .disabled(branch == session.gitBranch)
                    .help(branch == session.gitBranch
                          ? "Current branch"
                          : "Switch to \(branch)")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                Text(session.gitBranch ?? "Git")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(TerminalTheme.cyanMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                TerminalTheme.cyan.opacity(isHovering ? 0.14 : 0.08),
                in: .capsule
            )
            .overlay {
                Capsule().stroke(
                    TerminalTheme.cyan.opacity(isHovering ? 0.42 : 0.15),
                    lineWidth: 1
                )
            }
            .contentShape(.capsule)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovering in
            self.isHovering = isHovering
            if isHovering { session.refreshGitBranches() }
        }
        .simultaneousGesture(TapGesture().onEnded {
            session.refreshGitBranches()
        })
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .help("Switch Git branch")
        .accessibilityLabel("Git branch")
        .accessibilityValue(session.gitBranch ?? "Unknown")
        .accessibilityHint("Opens a menu of local branches")
    }
}
