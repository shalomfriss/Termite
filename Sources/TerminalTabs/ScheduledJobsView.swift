import SwiftUI

struct ScheduledJobsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var jobStore: ScheduledJobStore
    @ObservedObject private var terminalStore: TerminalStore
    @State private var isEditorPresented = false
    @State private var editingJob: ScheduledJob?
    @State private var newJobTiming: ScheduledJobTiming = .scheduled

    init(store: TerminalStore) {
        terminalStore = store
        jobStore = store.scheduledJobs
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Jobs & Workflows", systemImage: "clock")
                    .font(.title2)
                    .bold()
                Spacer()
                if jobStore.jobs.contains(where: { $0.status == .launched || $0.status == .failed }) {
                    Button("Clear Finished", action: jobStore.deleteFinishedJobs)
                        .buttonStyle(.airSecondary)
                        .help("Remove finished and failed jobs")
                }
                Button("New Cron Job", systemImage: "repeat", action: createCronJob)
                    .buttonStyle(.airSecondary)
                    .help("Create a recurring job using a cron schedule")
                Button("New Job", systemImage: "plus", action: createJob)
                    .buttonStyle(.airPrimary)
                    .help("Create a scheduled job or saved workflow")
            }
            .padding()

            Divider()

            if jobStore.jobs.isEmpty {
                ContentUnavailableView(
                    "No Jobs or Workflows",
                    systemImage: "clock",
                    description: Text(
                        "Schedule a script, create a recurring cron job, or save a workflow to run whenever you need it."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(jobStore.jobs) { job in
                    ScheduledJobRow(
                        job: job,
                        runNow: { jobStore.runNow(job.id) },
                        edit: { editJob(job) },
                        delete: { jobStore.delete(job.id) }
                    )
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Text("Jobs and workflows are saved automatically. Timed and cron jobs run automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close", action: dismiss.callAsFunction)
                    .buttonStyle(.airSecondary)
                    .keyboardShortcut(.cancelAction)
                    .help("Close Jobs & Workflows")
            }
            .padding()
        }
        .frame(minWidth: 640, minHeight: 500)
        .background(TerminalTheme.backdrop)
        .sheet(isPresented: $isEditorPresented) {
            ScheduledJobEditor(
                job: editingJob,
                defaultWorkingDirectory: terminalStore.selected?.workingDirectory
                    ?? FileManager.default.currentDirectoryPath,
                initialTiming: newJobTiming,
                save: saveJob
            )
        }
    }

    private func createJob() {
        editingJob = nil
        newJobTiming = .scheduled
        isEditorPresented = true
    }

    private func createCronJob() {
        editingJob = nil
        newJobTiming = .cron
        isEditorPresented = true
    }

    private func editJob(_ job: ScheduledJob) {
        editingJob = job
        newJobTiming = job.timing
        isEditorPresented = true
    }

    private func saveJob(
        _ timing: ScheduledJobTiming,
        _ scheduledAt: Date?,
        _ cronExpression: String?,
        _ script: ScheduledJobScript,
        _ runLocation: ScheduledJobRunLocation,
        _ directory: String
    ) throws {
        if let editingJob {
            try jobStore.update(
                editingJob.id,
                timing: timing,
                scheduledAt: scheduledAt,
                cronExpression: cronExpression,
                script: script,
                runLocation: runLocation,
                workingDirectory: directory
            )
        } else {
            try jobStore.schedule(
                timing: timing,
                at: scheduledAt,
                cronExpression: cronExpression,
                script: script,
                runLocation: runLocation,
                workingDirectory: directory
            )
        }
    }
}
