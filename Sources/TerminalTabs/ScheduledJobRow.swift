import SwiftUI

struct ScheduledJobRow: View {
    let job: ScheduledJob
    let runNow: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.summary)
                        .font(.headline.monospaced())
                        .lineLimit(1)
                    scheduleDescription
                }
                Spacer()
                Label(statusTitle, systemImage: statusSystemImage)
                    .font(.callout)
                    .foregroundStyle(statusColor)
            }

            Label(runLocationDescription, systemImage: runLocationSystemImage)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Label(scriptDescription, systemImage: job.script.source == .file ? "doc" : "text.quote")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let failureMessage = job.failureMessage {
                Text(failureMessage)
                    .font(.callout)
                    .foregroundStyle(TerminalTheme.danger)
            }

            HStack {
                Button(
                    job.status == .scheduled || job.status == .saved ? "Run Now" : "Run Again",
                    systemImage: "play.fill",
                    action: runNow
                )
                .help("Run this job in a new shell")
                Button("Edit", systemImage: "pencil", action: edit)
                    .help("Edit this job or workflow")
                Spacer()
                Button("Delete", systemImage: "trash", role: .destructive, action: delete)
                    .help("Delete this job or workflow")
            }
            .controlSize(.small)
            .disabled(job.status == .launching)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private var statusTitle: String {
        switch job.status {
        case .scheduled: "Scheduled"
        case .saved: "Saved Workflow"
        case .launching: "Launching"
        case .launched: "Started"
        case .failed: "Failed"
        }
    }

    @ViewBuilder
    private var scheduleDescription: some View {
        if job.timing == .manual {
            if let launchedAt = job.launchedAt {
                Text("Saved workflow · Last run \(launchedAt, format: .relative(presentation: .named))")
                    .foregroundStyle(.secondary)
            } else {
                Text("Saved workflow · Runs manually")
                    .foregroundStyle(.secondary)
            }
        } else if let scheduledAt = job.scheduledAt {
            Text(scheduledAt, format: .dateTime.weekday().month().day().hour().minute())
                .foregroundStyle(.secondary)
        }
    }

    private var scriptDescription: String {
        switch job.script.source {
        case .pasted: "Pasted \(job.script.language.title) script"
        case .file: "\(job.script.language.title) script file"
        }
    }

    private var runLocationDescription: String {
        switch job.runLocation {
        case .selectedFolder: job.workingDirectory
        case .temporaryFolder: "/tmp — removed after the script exits"
        }
    }

    private var runLocationSystemImage: String {
        switch job.runLocation {
        case .selectedFolder: "folder"
        case .temporaryFolder: "folder.badge.minus"
        }
    }

    private var statusSystemImage: String {
        switch job.status {
        case .scheduled: "clock"
        case .saved: "bookmark.fill"
        case .launching: "arrow.up.forward.circle"
        case .launched: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch job.status {
        case .scheduled: TerminalTheme.cyan
        case .saved: TerminalTheme.cyan
        case .launching: .orange
        case .launched: TerminalTheme.green
        case .failed: TerminalTheme.danger
        }
    }
}
