import SwiftUI

struct TextFileEditorToolbar: View {
    let isEditable: Bool
    let isDirty: Bool
    let isSaving: Bool
    let errorMessage: String?
    let canPreviewMarkdown: Bool
    let isPreviewingMarkdown: Bool
    let toggleMarkdownPreview: () -> Void
    let revert: () -> Void
    let save: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextFileEditorStatus(
                isEditable: isEditable,
                isDirty: isDirty,
                isSaving: isSaving
            )

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(errorMessage)
            }

            Spacer(minLength: 8)

            if canPreviewMarkdown {
                Button(
                    isPreviewingMarkdown ? "Edit" : "Preview",
                    systemImage: isPreviewingMarkdown ? "pencil" : "doc.richtext",
                    action: toggleMarkdownPreview
                )
                .help(isPreviewingMarkdown ? "Edit Markdown source" : "Render Markdown preview")
            }

            Button("Revert", action: revert)
                .disabled(!isDirty || isSaving)
                .help("Revert unsaved changes")

            Button("Save", systemImage: "square.and.arrow.down", action: save)
                .disabled(!isEditable || !isDirty || isSaving)
                .keyboardShortcut("s", modifiers: .command)
                .help("Save changes")
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.025))
    }
}
