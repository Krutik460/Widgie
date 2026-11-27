import Foundation

extension Spec {
    /// An AI block. It runs on the server, never on the phone. Each run writes one row to `writes`, and the
    /// model's output is that table's fields, so there is no second schema to keep in step.
    package struct Automation: Hashable, Sendable {
        package let id: AutomationID
        package let prompt: String
        package let schedule: Schedule
        package let writes: Table
    }

    package struct Schedule: Hashable, Sendable {
        package enum Cadence: Hashable, Sendable {
            case hourly(minute: Int)
            case daily(hour: Int, minute: Int)
            case weekly(Weekday, hour: Int, minute: Int)
        }

        package let cadence: Cadence

        /// The first run after `instant` in `zone`. Automations follow the phone's current time zone, so someone
        /// who moves keeps getting the word at 06:00 local. A wall-clock time that a daylight saving change skips
        /// runs at the next time that exists, and one it repeats runs once.
        package func nextRun(after instant: Date, in zone: TimeZone) -> Date? {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            var match = DateComponents()
            match.second = 0
            switch cadence {
            case .hourly(let minute):
                match.minute = minute
            case .daily(let hour, let minute):
                match.hour = hour
                match.minute = minute
            case .weekly(let weekday, let hour, let minute):
                match.weekday = weekday.calendarNumber
                match.hour = hour
                match.minute = minute
            }
            return calendar.nextDate(after: instant, matching: match, matchingPolicy: .nextTime)
        }
    }
}

extension Spec.Automation {
    static func parse(_ id: Spec.AutomationID, _ json: JSONValue, _ resolver: Resolver) throws(Diagnostic)
        -> Spec.Automation
    {
        do throws(Diagnostic) {
            let automation = try Reader(
                json,
                else:
                    "an automation must be an object like {\"prompt\": \"...\", \"every\": \"day\", \"at\": \"06:00\", \"writes\": \"words\"}, not \(json.described)"
            )
            // Documents saved before automations followed the phone's time zone (2026-11-27) carry the zone
            // they were built in as `timeZone`. It is read past and never written again.
            try automation.requireOnly(["at", "every", "on", "prompt", "timeZone", "writes"]) {
                "unknown key \(Diagnostic.quote($0)) (keys: prompt, every, at, on, writes)"
            }
            guard let prompt = try automation.string("prompt", maxLength: Spec.Limits.promptLength), !prompt.isEmpty
            else {
                throw Diagnostic("needs \"prompt\": what the model should write each time it runs")
            }
            guard let target = automation["writes"] else {
                throw Diagnostic("needs \"writes\": the table each run adds a row to \(resolver.tableChoices)")
            }
            let writes = try resolver.table(target, for: "writes")
            return Spec.Automation(
                id: id, prompt: prompt, schedule: Spec.Schedule(cadence: try cadence(automation)), writes: writes)
        } catch {
            throw error.within("automation \(Diagnostic.quote(id.raw))")
        }
    }

    private static func cadence(_ automation: Reader) throws(Diagnostic) -> Spec.Schedule.Cadence {
        guard let every = automation["every"] else { throw Diagnostic("needs \"every\": hour, day, or week") }
        guard case .string(let raw) = every, ["hour", "day", "week"].contains(raw) else {
            throw Diagnostic("\"every\" must be hour, day, or week, not \(every.described)")
        }
        if raw != "week", automation.has("on") {
            throw Diagnostic("\"on\" names a weekday and works only with \"every\": \"week\"")
        }
        if raw == "hour" {
            guard let at = automation["at"] else { return .hourly(minute: 0) }
            guard case .string(let text) = at, text.count == 3, text.hasPrefix(":"), let minute = Int(text.dropFirst()),
                (0...59).contains(minute)
            else {
                throw Diagnostic("\"at\" for every hour must be the minute, like \":15\", not \(at.described)")
            }
            return .hourly(minute: minute)
        }
        guard let at = automation["at"] else {
            throw Diagnostic("needs \"at\": the time of day it runs, like \"06:00\" (24-hour)")
        }
        let parts = clock(at)
        guard parts.count == 2 else {
            throw Diagnostic("\"at\" must be a time of day like \"06:00\" (24-hour), not \(at.described)")
        }
        if raw == "day" { return .daily(hour: parts[0], minute: parts[1]) }
        let names = Weekday.allCases.map(\.name)
        guard let on = automation["on"] else {
            throw Diagnostic("every week needs \"on\": the weekday it runs (\(names.joined(separator: ", ")))")
        }
        guard case .string(let name) = on, let weekday = Weekday.allCases.first(where: { $0.name == name }) else {
            throw Diagnostic("\"on\" must be a weekday (\(names.joined(separator: ", "))), not \(on.described)")
        }
        return .weekly(weekday, hour: parts[0], minute: parts[1])
    }

    /// `"06:00"` as `[6, 0]`, or an empty list for anything that is not a 24-hour time.
    private static func clock(_ value: JSONValue) -> [Int] {
        guard case .string(let text) = value, text.count == 5 else { return [] }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 }), let hour = Int(parts[0]),
            let minute = Int(parts[1]),
            (0...23).contains(hour), (0...59).contains(minute)
        else { return [] }
        return [hour, minute]
    }

    var json: JSONValue {
        .object(schedule.cadence.members.merging(["prompt": .string(prompt), "writes": .string(writes.id.raw)]) { $1 })
    }
}

extension Spec.Schedule.Cadence {
    /// `every`, `at`, and `on` as the document writes them, for the document and for the automation payload.
    package var members: [String: JSONValue] {
        switch self {
        case .hourly(let minute):
            ["every": .string("hour"), "at": .string(String(format: ":%02d", minute))]
        case .daily(let hour, let minute):
            ["every": .string("day"), "at": .string(String(format: "%02d:%02d", hour, minute))]
        case .weekly(let weekday, let hour, let minute):
            [
                "every": .string("week"), "on": .string(weekday.name),
                "at": .string(String(format: "%02d:%02d", hour, minute)),
            ]
        }
    }
}
