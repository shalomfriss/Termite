import SwiftUI

struct TextFilePreview: View {
    let url: URL
    let highlightsSyntax: Bool

    @State private var document: TextFileDocument?
    @State private var source = ""
    @State private var savedSource = ""
    @State private var isWritable = false
    @State private var isSaving = false
    @State private var isPreviewingMarkdown = false
    @State private var errorMessage: String?
    @State private var saveErrorMessage: String?

    var body: some View {
        Group {
            if document != nil {
                VStack(spacing: 0) {
                    TextFileEditorToolbar(
                        isEditable: isWritable,
                        isDirty: isDirty,
                        isSaving: isSaving,
                        errorMessage: saveErrorMessage,
                        canPreviewMarkdown: isMarkdownFile,
                        isPreviewingMarkdown: isPreviewingMarkdown,
                        toggleMarkdownPreview: toggleMarkdownPreview,
                        revert: revert,
                        save: save
                    )

                    Divider()

                    if isPreviewingMarkdown {
                        RenderedMarkdownView(
                            source: source,
                            baseURL: url.deletingLastPathComponent()
                        )
                    } else {
                        HighlightedTextView(
                            source: $source,
                            highlightsSyntax: highlightsSyntax,
                            isEditable: isWritable && !isSaving
                        )
                    }
                }
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
        document = nil
        source = ""
        savedSource = ""
        isWritable = false
        isSaving = false
        isPreviewingMarkdown = false
        errorMessage = nil
        saveErrorMessage = nil

        do {
            let url = url
            let loadedDocument = try await Task.detached(priority: .userInitiated) {
                try TextFileDocument.load(from: url)
            }.value
            try Task.checkCancellation()
            document = loadedDocument
            source = loadedDocument.text
            savedSource = loadedDocument.text
            isWritable = FileManager.default.isWritableFile(atPath: url.path)
        } catch is CancellationError {
            return
        } catch CocoaError.fileReadTooLarge {
            errorMessage = "Text files larger than 4 MB are not previewed."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var isDirty: Bool {
        source != savedSource
    }

    private var isMarkdownFile: Bool {
        MarkdownPreviewFileDetector.isMarkdownFile(url)
    }

    private func toggleMarkdownPreview() {
        isPreviewingMarkdown.toggle()
    }

    private func revert() {
        source = savedSource
        saveErrorMessage = nil
    }

    private func save() {
        guard let document, isWritable, isDirty, !isSaving else { return }
        let sourceToSave = source
        let url = url
        isSaving = true
        saveErrorMessage = nil

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try document.write(sourceToSave, to: url)
                }.value
                try Task.checkCancellation()
                savedSource = sourceToSave
                isSaving = false
            } catch is CancellationError {
                isSaving = false
            } catch {
                saveErrorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
