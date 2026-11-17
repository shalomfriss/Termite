import SwiftUI

struct ScheduledJobEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var timing: ScheduledJobTiming
    @State private var scheduledAt: Date
    @State private var scriptSource: ScheduledJobScriptSource
    @State private var scriptLanguage: ScheduledScriptLanguage
    @State private var pastedScript: String
    @State private var scriptFilePath: String?
    @State private var runLocation: ScheduledJobRunLocation
    @State private var workingDirectory: String
    @State private var errorMessage: String?

    let isEditing: Bool
    let save: (
        ScheduledJobTiming,
        Date?,
        ScheduledJobScript,
        ScheduledJobRunLocation,
        String
    ) throws -> Void

    init(
        job: ScheduledJob?,
        defaultWorkingDirectory: String,
        save: @escaping (
            ScheduledJobTiming,
            Date?,
            ScheduledJobScript,
            ScheduledJobRunLocation,
            String
        ) throws -> Void
    ) {
        let script = job?.script ?? .pasted("", language: .bash)
        isEditing = job != nil
        self.save = save
        _timing = State(initialValue: job?.timing ?? .scheduled)
        _scheduledAt = State(initialValue: job?.scheduledAt ?? .now.addingTimeInterval(300))
        _scriptSource = State(initialValue: script.source)
        _scriptLanguage = State(initialValue: script.language)
        _pastedScript = State(initialValue: script.pastedText)
        _scriptFilePath = State(initialValue: script.filePath)
        _runLocation = State(initialValue: job?.runLocation ?? .selectedFolder)
        _workingDirectory = State(
            initialValue: job?.workingDirectory ?? defaultWorkingDirectory
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(isEditing ? "Edit Job or Workflow" : "New Job or Workflow", systemImage: "clock")
                .font(.title2)
                .bold()
                .foregroundStyle(TerminalTheme.text)
                .padding()

            Divider()

            Form {
                Picker("Type", selection: $timing) {
                    ForEach(ScheduledJobTiming.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                if timing == .scheduled {
                    DatePicker(
                        "Run at",
                        selection: $scheduledAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                } else {
                    Label(
                        "This workflow is saved without a time and runs only when you choose Run Now.",
                        systemImage: "bookmark"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                ScheduledJobDirectoryPicker(
                    runLocation: $runLocation,
                    path: $workingDirectory,
                    errorMessage: $errorMessage
                )

                ScheduledJobScriptInput(
                    source: $scriptSource,
                    language: $scriptLanguage,
                    pastedText: $pastedScript,
                    filePath: $scriptFilePath,
                    errorMessage: $errorMessage
                )

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(TerminalTheme.danger)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Text(footerMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel, action: dismiss.callAsFunction)
                Button(isEditing ? "Save" : primaryActionTitle, action: saveJob)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
            .padding()
        }
        .frame(minWidth: 620, minHeight: 520)
        .background(TerminalTheme.backdrop)
        .onChange(of: scriptSource) {
            errorMessage = nil
            if scriptSource == .pasted,
               !ScheduledScriptLanguage.pastedScriptOptions.contains(scriptLanguage) {
                scriptLanguage = .bash
            } else if scriptSource == .file,
                      let scriptFilePath,
                      let detected = try? ScheduledScriptLanguage.detect(
                        at: URL(fileURLWithPath: scriptFilePath)
                      ) {
                scriptLanguage = detected
            }
        }
    }

    private var canSave: Bool {
        switch scriptSource {
        case .pasted:
            !pastedScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .file:
            scriptFilePath != nil
        }
    }

    private var primaryActionTitle: String {
        timing == .scheduled ? "Schedule" : "Save Workflow"
    }

    private var footerMessage: String {
        timing == .scheduled
            ? "Pending jobs launch when the app is next open."
            : "Saved workflows run only when you start them."
    }

    private func saveJob() {
        do {
            let script: ScheduledJobScript = switch scriptSource {
            case .pasted:
                .pasted(pastedScript, language: scriptLanguage)
            case .file:
                ScheduledJobScript(
                    source: .file,
                    language: scriptLanguage,
                    pastedText: "",
                    filePath: scriptFilePath
                )
            }
            try save(
                timing,
                timing == .scheduled ? scheduledAt : nil,
                script,
                runLocation,
                workingDirectory
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
