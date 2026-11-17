import SwiftUI

struct ScheduledJobsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var jobStore: ScheduledJobStore
    @ObservedObject private var terminalStore: TerminalStore
    @State private var isEditorPresented = false
    @State private var editingJob: ScheduledJob?

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
                        .help("Remove finished and failed jobs")
                }
                Button("New Job", systemImage: "plus", action: createJob)
                    .buttonStyle(.borderedProminent)
                    .help("Create a scheduled job or saved workflow")
            }
            .padding()

            Divider()

            if jobStore.jobs.isEmpty {
                ContentUnavailableView(
                    "No Jobs or Workflows",
                    systemImage: "clock",
                    description: Text(
                        "Schedule a script for later or save a workflow to run whenever you need it."
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
                Text("Jobs and workflows are saved automatically. Only timed jobs run automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close", action: dismiss.callAsFunction)
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
                save: saveJob
            )
        }
    }

    private func createJob() {
        editingJob = nil
        isEditorPresented = true
    }

    private func editJob(_ job: ScheduledJob) {
        editingJob = job
        isEditorPresented = true
    }

    private func saveJob(
        _ timing: ScheduledJobTiming,
        _ scheduledAt: Date?,
        _ script: ScheduledJobScript,
        _ runLocation: ScheduledJobRunLocation,
        _ directory: String
    ) throws {
        if let editingJob {
            try jobStore.update(
                editingJob.id,
                timing: timing,
                scheduledAt: scheduledAt,
                script: script,
                runLocation: runLocation,
                workingDirectory: directory
            )
        } else {
            try jobStore.schedule(
                timing: timing,
                at: scheduledAt,
                script: script,
                runLocation: runLocation,
                workingDirectory: directory
            )
        }
    }
}
