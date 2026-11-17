import Combine
import Foundation

@MainActor
final class ScheduledJobStore: ObservableObject {
    typealias Executor = @MainActor (ScheduledJob) -> Void

    @Published private(set) var jobs: [ScheduledJob]

    private let userDefaults: UserDefaults
    private let storageKey: String
    private var executor: Executor?

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "scheduledJobs"
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        jobs = Self.loadJobs(from: userDefaults, storageKey: storageKey)

        var recoveredInterruptedJob = false
        for index in jobs.indices where jobs[index].status == .launching {
            jobs[index].status = .failed
            jobs[index].failureMessage = "The app closed before the shell accepted this script."
            recoveredInterruptedJob = true
        }
        sortJobs()
        if recoveredInterruptedJob { persist() }
    }

    var scheduledCount: Int {
        jobs.count { $0.timing == .scheduled && $0.status == .scheduled }
    }

    func setExecutor(_ executor: @escaping Executor) {
        self.executor = executor
    }

    @discardableResult
    func schedule(
        timing: ScheduledJobTiming = .scheduled,
        at scheduledAt: Date?,
        script: ScheduledJobScript,
        runLocation: ScheduledJobRunLocation = .selectedFolder,
        workingDirectory: String
    ) throws -> ScheduledJob {
        try script.validate()
        if timing == .scheduled, scheduledAt == nil {
            throw ScheduledJobError.missingScheduleDate
        }
        let cleanedDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let job = ScheduledJob(
            timing: timing,
            scheduledAt: scheduledAt,
            script: script,
            runLocation: runLocation,
            workingDirectory: cleanedDirectory.isEmpty
                ? FileManager.default.currentDirectoryPath
                : cleanedDirectory,
            status: timing == .scheduled ? .scheduled : .saved
        )
        jobs.append(job)
        sortAndPersist()
        return job
    }

    @discardableResult
    func schedule(
        at scheduledAt: Date,
        script: String,
        workingDirectory: String
    ) throws -> ScheduledJob {
        try schedule(
            at: scheduledAt,
            script: .pasted(script, language: .bash),
            workingDirectory: workingDirectory
        )
    }

    func update(
        _ id: UUID,
        timing: ScheduledJobTiming = .scheduled,
        scheduledAt: Date?,
        script: ScheduledJobScript,
        runLocation: ScheduledJobRunLocation = .selectedFolder,
        workingDirectory: String
    ) throws {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        try script.validate()
        if timing == .scheduled, scheduledAt == nil {
            throw ScheduledJobError.missingScheduleDate
        }
        let cleanedDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        jobs[index].timing = timing
        jobs[index].scheduledAt = timing == .scheduled ? scheduledAt : nil
        jobs[index].script = script
        jobs[index].runLocation = runLocation
        jobs[index].workingDirectory = cleanedDirectory.isEmpty
            ? FileManager.default.currentDirectoryPath
            : cleanedDirectory
        jobs[index].status = timing == .scheduled ? .scheduled : .saved
        jobs[index].launchedAt = nil
        jobs[index].failureMessage = nil
        sortAndPersist()
    }

    func delete(_ id: UUID) {
        jobs.removeAll { $0.id == id }
        persist()
    }

    func deleteFinishedJobs() {
        jobs.removeAll {
            $0.timing == .scheduled && ($0.status == .launched || $0.status == .failed)
        }
        persist()
    }

    func runNow(_ id: UUID) {
        guard let executor,
              let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].status != .launching else { return }
        jobs[index].status = .launching
        jobs[index].failureMessage = nil
        let job = jobs[index]
        sortAndPersist()
        executor(job)
    }

    func launchDueJobs(at date: Date = .now) {
        guard let executor else { return }
        let dueIDs = jobs.filter {
            $0.timing == .scheduled
                && $0.status == .scheduled
                && ($0.scheduledAt.map { $0 <= date } ?? false)
        }.map(\.id)
        guard !dueIDs.isEmpty else { return }

        for id in dueIDs {
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { continue }
            jobs[index].status = .launching
            jobs[index].failureMessage = nil
            let job = jobs[index]
            persist()
            executor(job)
        }
    }

    func markLaunched(_ id: UUID, at date: Date = .now) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].status = jobs[index].timing == .manual ? .saved : .launched
        jobs[index].launchedAt = date
        jobs[index].failureMessage = nil
        persist()
    }

    func markFailed(_ id: UUID, message: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].status = .failed
        jobs[index].failureMessage = message
        persist()
    }

    private func sortAndPersist() {
        sortJobs()
        persist()
    }

    private func sortJobs() {
        jobs.sort {
            let leftRank = Self.sortRank(for: $0)
            let rightRank = Self.sortRank(for: $1)
            if leftRank != rightRank { return leftRank < rightRank }
            let leftDate = $0.scheduledAt ?? $0.createdAt
            let rightDate = $1.scheduledAt ?? $1.createdAt
            if leftDate != rightDate { return leftDate < rightDate }
            return $0.summary.localizedStandardCompare($1.summary) == .orderedAscending
        }
    }

    nonisolated private static func sortRank(for job: ScheduledJob) -> Int {
        if job.timing == .scheduled, job.status == .scheduled { return 0 }
        if job.timing == .manual { return 1 }
        if job.status == .launching { return 2 }
        return 3
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    nonisolated private static func loadJobs(
        from userDefaults: UserDefaults,
        storageKey: String
    ) -> [ScheduledJob] {
        guard let data = userDefaults.data(forKey: storageKey),
              let jobs = try? JSONDecoder().decode([ScheduledJob].self, from: data) else {
            return []
        }
        return jobs
    }
}
