import Foundation

struct ScheduledJob: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var timing: ScheduledJobTiming
    var scheduledAt: Date?
    var cronExpression: String?
    var script: ScheduledJobScript
    var runLocation: ScheduledJobRunLocation
    var workingDirectory: String
    var status: ScheduledJobStatus
    var createdAt: Date
    var launchedAt: Date?
    var failureMessage: String?

    init(
        id: UUID = UUID(),
        timing: ScheduledJobTiming = .scheduled,
        scheduledAt: Date?,
        cronExpression: String? = nil,
        script: ScheduledJobScript,
        runLocation: ScheduledJobRunLocation = .selectedFolder,
        workingDirectory: String,
        status: ScheduledJobStatus = .scheduled,
        createdAt: Date = .now,
        launchedAt: Date? = nil,
        failureMessage: String? = nil
    ) {
        self.id = id
        self.timing = timing
        self.scheduledAt = timing == .manual ? nil : scheduledAt
        self.cronExpression = timing == .cron ? cronExpression : nil
        self.script = script
        self.runLocation = runLocation
        self.workingDirectory = workingDirectory
        self.status = status
        self.createdAt = createdAt
        self.launchedAt = launchedAt
        self.failureMessage = failureMessage
    }

    var summary: String {
        script.summary
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timing
        case scheduledAt
        case cronExpression
        case script
        case scriptConfiguration
        case runLocation
        case workingDirectory
        case status
        case createdAt
        case launchedAt
        case failureMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timing = try container.decodeIfPresent(ScheduledJobTiming.self, forKey: .timing)
            ?? .scheduled
        scheduledAt = try container.decodeIfPresent(Date.self, forKey: .scheduledAt)
        cronExpression = try container.decodeIfPresent(String.self, forKey: .cronExpression)
        if let configuration = try container.decodeIfPresent(
            ScheduledJobScript.self,
            forKey: .scriptConfiguration
        ) {
            script = configuration
        } else {
            let legacyScript = try container.decode(String.self, forKey: .script)
            script = .pasted(legacyScript, language: .bash)
        }
        runLocation = try container.decodeIfPresent(
            ScheduledJobRunLocation.self,
            forKey: .runLocation
        ) ?? .selectedFolder
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        status = try container.decode(ScheduledJobStatus.self, forKey: .status)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        launchedAt = try container.decodeIfPresent(Date.self, forKey: .launchedAt)
        failureMessage = try container.decodeIfPresent(String.self, forKey: .failureMessage)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timing, forKey: .timing)
        try container.encodeIfPresent(scheduledAt, forKey: .scheduledAt)
        try container.encodeIfPresent(cronExpression, forKey: .cronExpression)
        try container.encode(script, forKey: .scriptConfiguration)
        try container.encode(runLocation, forKey: .runLocation)
        try container.encode(workingDirectory, forKey: .workingDirectory)
        try container.encode(status, forKey: .status)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(launchedAt, forKey: .launchedAt)
        try container.encodeIfPresent(failureMessage, forKey: .failureMessage)
    }
}
