import SwiftUI

struct ScheduledJobsButton: View {
    @ObservedObject var store: TerminalStore

    var body: some View {
        Button("Jobs & Workflows", systemImage: "clock") {
            store.isScheduledJobsVisible = true
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .foregroundStyle(TerminalTheme.cyanMuted)
        .overlay(alignment: .topTrailing) {
            if store.scheduledJobs.scheduledCount > 0 {
                Circle()
                    .fill(TerminalTheme.cyan)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
        }
        .help("Jobs & Workflows")
    }
}
