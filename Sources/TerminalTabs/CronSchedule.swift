import Foundation

struct CronSchedule: Equatable, Sendable {
    enum ValidationError: LocalizedError, Equatable {
        case invalidExpression(String)

        var errorDescription: String? {
            switch self {
            case .invalidExpression(let detail):
                "Invalid cron schedule: \(detail)"
            }
        }
    }

    let expression: String

    private let minutes: Field
    private let hours: Field
    private let daysOfMonth: Field
    private let months: Field
    private let daysOfWeek: Field

    init(_ expression: String) throws {
        let normalized = expression
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .joined(separator: " ")
        let parts = normalized.split(separator: " ").map(String.init)
        guard parts.count == 5 else {
            throw ValidationError.invalidExpression(
                "enter five fields: minute hour day-of-month month day-of-week."
            )
        }

        self.expression = normalized
        minutes = try Field(parts[0], range: 0...59, name: "minute")
        hours = try Field(parts[1], range: 0...23, name: "hour")
        daysOfMonth = try Field(parts[2], range: 1...31, name: "day of month")
        months = try Field(parts[3], range: 1...12, name: "month")
        daysOfWeek = try Field(
            parts[4],
            range: 0...7,
            name: "day of week",
            normalize: { $0 == 7 ? 0 : $0 }
        )
    }

    func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents(
            [.minute, .hour, .day, .month, .weekday],
            from: date
        )
        guard let minute = components.minute,
              let hour = components.hour,
              let day = components.day,
              let month = components.month,
              let weekday = components.weekday else { return false }

        let dayOfWeek = weekday - 1
        let monthDayMatches = daysOfMonth.values.contains(day)
        let weekDayMatches = daysOfWeek.values.contains(dayOfWeek)
        let dayMatches: Bool
        if daysOfMonth.isWildcard {
            dayMatches = weekDayMatches
        } else if daysOfWeek.isWildcard {
            dayMatches = monthDayMatches
        } else {
            dayMatches = monthDayMatches || weekDayMatches
        }

        return minutes.values.contains(minute)
            && hours.values.contains(hour)
            && months.values.contains(month)
            && dayMatches
    }

    func nextDate(after date: Date, calendar: Calendar = .current) -> Date? {
        var candidate = calendar.date(
            from: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        ) ?? date
        candidate = calendar.date(byAdding: .minute, value: 1, to: candidate) ?? candidate

        let searchLimit = 366 * 24 * 60 * 5
        for _ in 0..<searchLimit {
            if matches(candidate, calendar: calendar) { return candidate }
            guard let next = calendar.date(byAdding: .minute, value: 1, to: candidate) else {
                return nil
            }
            candidate = next
        }
        return nil
    }

    private struct Field: Equatable, Sendable {
        let values: Set<Int>
        let isWildcard: Bool

        init(
            _ source: String,
            range: ClosedRange<Int>,
            name: String,
            normalize: (Int) -> Int = { $0 }
        ) throws {
            isWildcard = source == "*"
            var parsed = Set<Int>()

            for component in source.split(separator: ",", omittingEmptySubsequences: false) {
                let stepParts = component.split(separator: "/", omittingEmptySubsequences: false)
                guard stepParts.count <= 2,
                      !stepParts[0].isEmpty else {
                    throw ValidationError.invalidExpression("invalid \(name) field ‘\(source)’.")
                }
                let step = stepParts.count == 2 ? Int(stepParts[1]) : 1
                guard let step, step > 0 else {
                    throw ValidationError.invalidExpression("\(name) step must be greater than zero.")
                }

                let base = String(stepParts[0])
                let bounds: ClosedRange<Int>
                if base == "*" {
                    bounds = range
                } else {
                    let rangeParts = base.split(separator: "-", omittingEmptySubsequences: false)
                    if rangeParts.count == 1, let value = Int(rangeParts[0]) {
                        bounds = value...value
                    } else if rangeParts.count == 2,
                              let lower = Int(rangeParts[0]),
                              let upper = Int(rangeParts[1]),
                              lower <= upper {
                        bounds = lower...upper
                    } else {
                        throw ValidationError.invalidExpression("invalid \(name) field ‘\(source)’.")
                    }
                }

                guard range.contains(bounds.lowerBound), range.contains(bounds.upperBound) else {
                    throw ValidationError.invalidExpression(
                        "\(name) must be between \(range.lowerBound) and \(range.upperBound)."
                    )
                }
                for value in stride(from: bounds.lowerBound, through: bounds.upperBound, by: step) {
                    parsed.insert(normalize(value))
                }
            }

            guard !parsed.isEmpty else {
                throw ValidationError.invalidExpression("\(name) cannot be empty.")
            }
            values = parsed
        }
    }
}
