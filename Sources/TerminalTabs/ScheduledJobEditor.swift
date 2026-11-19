import SwiftUI

struct ScheduledJobEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var timing: ScheduledJobTiming
    @State private var scheduledAt: Date
    @State private var cronExpression: String
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
        String?,
        ScheduledJobScript,
        ScheduledJobRunLocation,
        String
    ) throws -> Void

    init(
        job: ScheduledJob?,
        defaultWorkingDirectory: String,
        initialTiming: ScheduledJobTiming = .scheduled,
        save: @escaping (
            ScheduledJobTiming,
            Date?,
            String?,
            ScheduledJobScript,
            ScheduledJobRunLocation,
            String
        ) throws -> Void
    ) {
        let script = job?.script ?? .pasted("", language: .bash)
        isEditing = job != nil
        self.save = save
        _timing = State(initialValue: job?.timing ?? initialTiming)
        _scheduledAt = State(initialValue: job?.scheduledAt ?? .now.addingTimeInterval(300))
        _cronExpression = State(initialValue: job?.cronExpression ?? "0 9 * * 1-5")
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
                } else if timing == .cron {
                    LabeledContent("Cron schedule") {
                        TextField("0 9 * * 1-5", text: $cronExpression)
                            .font(.body.monospaced())
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 230)
                            .help("Five fields: minute, hour, day of month, month, day of week")
                    }
                    Label(
                        "Five fields: minute, hour, day of month, month, day of week. Example: */15 * * * *",
                        systemImage: "repeat"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
                    .buttonStyle(.airSecondary)
                    .help("Discard changes and close")
                Button(isEditing ? "Save" : primaryActionTitle, action: saveJob)
                    .buttonStyle(.airPrimary)
                    .disabled(!canSave)
                    .help(isEditing ? "Save changes" : primaryActionHelp)
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
        if timing == .cron,
           (try? CronSchedule(cronExpression)) == nil { return false }
        return switch scriptSource {
        case .pasted:
            !pastedScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .file:
            scriptFilePath != nil
        }
    }

    private var primaryActionTitle: String {
        switch timing {
        case .scheduled: "Schedule"
        case .cron: "Create Cron Job"
        case .manual: "Save Workflow"
        }
    }

    private var primaryActionHelp: String {
        switch timing {
        case .scheduled: "Schedule this job"
        case .cron: "Create this recurring cron job"
        case .manual: "Save this workflow without a time"
        }
    }

    private var footerMessage: String {
        switch timing {
        case .scheduled: "Pending jobs launch when the app is next open."
        case .cron: "Cron jobs run while Air is open and catch up when Air is reopened."
        case .manual: "Saved workflows run only when you start them."
        }
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
                timing == .cron ? cronExpression : nil,
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
