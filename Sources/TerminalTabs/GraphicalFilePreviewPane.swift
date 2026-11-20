import SwiftUI

struct GraphicalFilePreviewPane: View {
    let item: GraphicalFileItem
    let close: () -> Void

    @State private var isAvailable = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.fill")
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
                    QuickLookPreview(url: URL(fileURLWithPath: item.path))
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
                at: URL(fileURLWithPath: item.path)
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
