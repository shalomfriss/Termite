import SwiftUI

struct GraphicalModeToolbar: View {
    @ObservedObject var session: TerminalSession
    @Binding var isEnabled: Bool
    @Binding var viewMode: GraphicalViewMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $isEnabled) {
                Label("Graphical", systemImage: "sparkles.rectangle.stack.fill")
                    .font(.callout)
                    .bold()
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(isEnabled ? TerminalTheme.canvas : TerminalTheme.text)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(
                isEnabled ? TerminalTheme.cyan : TerminalTheme.raised,
                in: .rect(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(isEnabled ? 0.24 : 0.08), lineWidth: 1)
            }
            .help(isEnabled ? "Turn off graphical mode" : "Browse directories graphically")

            if isEnabled {
                Rectangle()
                    .fill(.white.opacity(0.08))
                    .frame(width: 1, height: 22)

                Image(systemName: "folder.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(TerminalTheme.cyan)

                VStack(alignment: .leading, spacing: 1) {
                    Text(directoryName)
                        .font(.callout)
                        .bold()
                        .foregroundStyle(TerminalTheme.text)
                        .lineLimit(1)
                    Text(directorySubtitle)
                        .font(.caption)
                        .foregroundStyle(TerminalTheme.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(session.workingDirectory)

                Spacer(minLength: 12)

                if let count = session.graphicalItemCount {
                    Text("^[\(count) item](inflect: true)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(TerminalTheme.mutedText)
                }

                Button("Attach listing to AI Chat", systemImage: "paperclip") {
                    session.attachGraphicalOutputToAI()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(TerminalTheme.mutedText)
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.045), in: .rect(cornerRadius: 7))
                .disabled(!session.canAttachGraphicalOutputToAI)
                .help("Attach directory listing to AI Chat")

                Button("Refresh directory", systemImage: "arrow.clockwise") {
                    session.showCurrentDirectoryGraphically()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(TerminalTheme.mutedText)
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.045), in: .rect(cornerRadius: 7))
                .help("Refresh directory")

                GraphicalViewPicker(selection: $viewMode)
            } else {
                Text("Clickable files, native menus, and directory previews")
                    .font(.callout)
                    .foregroundStyle(TerminalTheme.mutedText)
                    .lineLimit(1)
                Spacer()
            }
        }
        .padding(.horizontal, 9)
        .frame(minHeight: 42)
        .background(.thinMaterial, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.075), lineWidth: 1)
        }
        .shadow(color: TerminalTheme.canvas.opacity(0.42), radius: 14, y: 7)
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: isEnabled)
    }

    private var directoryName: String {
        let name = URL(fileURLWithPath: session.workingDirectory, isDirectory: true).lastPathComponent
        return name.isEmpty ? "/" : name
    }

    private var directorySubtitle: String {
        let parent = URL(fileURLWithPath: session.workingDirectory, isDirectory: true)
            .deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }
}
