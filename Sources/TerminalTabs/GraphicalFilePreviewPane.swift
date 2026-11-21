import SwiftUI

struct GraphicalFilePreviewPane: View {
    let item: GraphicalFileItem
    let close: () -> Void

    @State private var isAvailable = false
    @State private var errorMessage: String?

    private var fileURL: URL {
        URL(fileURLWithPath: item.path)
    }

    private var isCodeFile: Bool {
        CodePreviewFileDetector.isCodeFile(fileURL)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(
                    systemName: isCodeFile
                        ? "chevron.left.forwardslash.chevron.right"
                        : "doc.text.fill"
                )
                    .foregroundStyle(TerminalTheme.cyan)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.callout)
                        .bold()
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(Int64(clamping: item.size), format: .byteCount(style: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button("Close Preview", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
                    .help("Close preview")
            }
            .padding(10)

            Divider()

            Group {
                if let errorMessage {
                    ContentUnavailableView(
                        "Preview Unavailable",
                        systemImage: "eye.slash",
                        description: Text(errorMessage)
                    )
                } else if isAvailable {
                    TextFilePreview(url: fileURL, highlightsSyntax: isCodeFile)
                        .id(item.path)
                } else {
                    ProgressView("Loading preview…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(TerminalTheme.surface)
        .task(id: item.path) {
            await preparePreview()
        }
    }

    private func preparePreview() async {
        isAvailable = false
        errorMessage = nil
        do {
            try await TerminalSession.ensureUbiquitousItemIsAvailable(
                at: fileURL
            )
            try Task.checkCancellation()
            isAvailable = true
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
