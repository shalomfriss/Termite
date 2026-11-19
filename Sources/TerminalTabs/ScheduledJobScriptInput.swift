import SwiftUI

struct ScheduledJobScriptInput: View {
    @Binding var source: ScheduledJobScriptSource
    @Binding var language: ScheduledScriptLanguage
    @Binding var pastedText: String
    @Binding var filePath: String?
    @Binding var errorMessage: String?

    var body: some View {
        Section("Script") {
            Picker("Source", selection: $source) {
                ForEach(ScheduledJobScriptSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.segmented)

            if source == .pasted {
                Picker("Language", selection: $language) {
                    ForEach(ScheduledScriptLanguage.pastedScriptOptions) { language in
                        Text(language.title).tag(language)
                    }
                }
                .pickerStyle(.segmented)

                ScheduledScriptTextArea(text: $pastedText)
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(filePath ?? "No script selected")
                            .font(.body.monospaced())
                            .foregroundStyle(filePath == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if filePath != nil {
                            Label("Detected as \(language.title)", systemImage: "checkmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(TerminalTheme.green)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose Script…", systemImage: "doc", action: chooseScript)
                        .buttonStyle(.airSecondary)
                        .help("Choose a script file to run")
                }
            }
        }
    }

    private func chooseScript() {
        let panel = NSOpenPanel()
        panel.title = "Choose Script"
        panel.message = "Bash, sh, Zsh, and Python scripts are detected automatically."
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if let filePath {
            panel.directoryURL = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        }

        Task { @MainActor in
            guard await panel.begin() == .OK, let url = panel.url else { return }
            do {
                try await TerminalSession.ensureUbiquitousItemIsAvailable(at: url)
                language = try ScheduledScriptLanguage.detect(at: url)
                filePath = url.standardizedFileURL.path
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
