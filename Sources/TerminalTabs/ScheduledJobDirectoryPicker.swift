import SwiftUI

struct ScheduledJobDirectoryPicker: View {
    @Binding var runLocation: ScheduledJobRunLocation
    @Binding var path: String
    @Binding var errorMessage: String?

    var body: some View {
        Section("Run Location") {
            Picker("Location", selection: $runLocation) {
                ForEach(ScheduledJobRunLocation.allCases) { location in
                    Text(location.title).tag(location)
                }
            }
            .pickerStyle(.segmented)

            if runLocation == .selectedFolder {
                LabeledContent("Run in") {
                    HStack {
                        Text(path)
                            .font(.body.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose Folder…", systemImage: "folder", action: chooseDirectory)
                            .buttonStyle(.airSecondary)
                            .help("Choose the working directory")
                    }
                }
            } else {
                Label(
                    "Air will create a unique folder under /tmp and remove it after the script exits.",
                    systemImage: "folder.badge.minus"
                )
                .foregroundStyle(.secondary)
            }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Working Directory"
        panel.message = "The scheduled shell will start in this folder."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }

        Task { @MainActor in
            guard await panel.begin() == .OK, let url = panel.url else { return }
            path = url.standardizedFileURL.path
            errorMessage = nil
        }
    }
}
