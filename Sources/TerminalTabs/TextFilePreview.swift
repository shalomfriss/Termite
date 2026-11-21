import SwiftUI

struct TextFilePreview: View {
    static let maximumByteCount = 4 * 1_024 * 1_024

    let url: URL
    let highlightsSyntax: Bool

    @State private var source: String?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let source {
                HighlightedTextView(source: source, highlightsSyntax: highlightsSyntax)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Text Preview Unavailable",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("Loading text…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            await loadSource()
        }
    }

    private func loadSource() async {
        source = nil
        errorMessage = nil

        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if let fileSize = values.fileSize, fileSize > Self.maximumByteCount {
                errorMessage = "Text files larger than 4 MB are not previewed."
                return
            }

            let url = url
            let maximumByteCount = Self.maximumByteCount
            let loadedSource = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= maximumByteCount else {
                    throw CocoaError(.fileReadTooLarge)
                }
                guard let decoded = Self.decode(data) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                return decoded
            }.value
            try Task.checkCancellation()
            source = loadedSource
        } catch is CancellationError {
            return
        } catch CocoaError.fileReadTooLarge {
            errorMessage = "Text files larger than 4 MB are not previewed."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    nonisolated private static func decode(_ data: Data) -> String? {
        for encoding in [
            String.Encoding.utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .isoLatin1,
        ] {
            if let decoded = String(data: data, encoding: encoding) {
                return decoded
            }
        }
        return nil
    }
}
