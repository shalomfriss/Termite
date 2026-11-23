import SwiftUI

struct TextFileEditorStatus: View {
    let isEditable: Bool
    let isDirty: Bool
    let isSaving: Bool

    var body: some View {
        Group {
            if !isEditable {
                Label("Read-only", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            } else if isSaving {
                ProgressView()
                    .controlSize(.small)
                    .help("Saving")
            } else if isDirty {
                Label("Edited", systemImage: "circle.fill")
                    .foregroundStyle(.orange)
            } else {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
