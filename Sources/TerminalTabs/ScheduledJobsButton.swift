import SwiftUI

struct ScheduledJobsButton: View {
    @ObservedObject var store: TerminalStore

    var body: some View {
        Button("Jobs & Workflows", systemImage: "clock") {
            store.isScheduledJobsVisible = true
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.toolbarIcon)
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
