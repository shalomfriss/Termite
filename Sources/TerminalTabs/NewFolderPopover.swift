import SwiftUI

struct NewFolderPopover: View {
    let suggestedName: String
    let createFolder: (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var folderName = ""
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("New Folder", systemImage: "folder.badge.plus")
                .font(.headline)

            TextField("Folder name", text: $folderName)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(create)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: dismiss.callAsFunction)
                    .help("Cancel folder creation")
                Button("Create", systemImage: "folder.badge.plus", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
                    .help("Create this folder")
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            folderName = suggestedName
            isNameFocused = true
        }
    }

    private var trimmedName: String {
        folderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func create() {
        guard !trimmedName.isEmpty else { return }
        do {
            try createFolder(trimmedName)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
