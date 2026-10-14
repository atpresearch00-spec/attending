import Foundation

/// A read-only iCalendar (.ics) feed, such as the private address Google Calendar and
/// Outlook give for a calendar. Handles what school and personal calendars use: time
/// zones (including Outlook's Windows names), all-day events, weekly and daily repeats
/// with BYDAY, INTERVAL, COUNT and UNTIL, skipped dates (EXDATE) and moved occurrences
/// (RECURRENCE-ID).
public struct ICSCalendar: Sendable {
    public struct Event: Sendable, Equatable {
        public var uid: String
        public var title: String
        public var start: Date
        public var end: Date
        public var allDay: Bool
        public var location: String?
        public var url: String?
        public var notes: String?
        public var rule: Rule?
        public var excluded: Set<Date> = []
        public var timeZone: TimeZone
        /// For a moved occurrence of a repeating event: the start it replaces.
        public var replaces: Date?
    }
    public struct Rule: Sendable, Equatable {
        public enum Frequency: String, Sendable { case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY" }
        public var frequency: Frequency
        public var interval = 1
        public var count: Int?
        public var until: Date?
        /// Weekdays as Calendar weekday numbers (1 = Sunday).
        public var weekdays: [Int] = []
    }

    public var name: String?
    public var events: [Event]

    public static func parse(_ text: String) -> ICSCalendar {
        // Unfold continuation lines (RFC 5545 §3.1), then read properties.
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty { lines[lines.count - 1] += raw.dropFirst() } else { lines.append(String(raw)) }
        }
        var calendar = ICSCalendar(name: nil, events: [])
        var current: [String: (params: [String: String], value: String)]?
        var exdates: [(params: [String: String], value: String)] = []
        var depth = 0
        for line in lines {
            guard let colon = Self.valueSeparator(in: line) else { continue }
            let head = line[..<colon], value = String(line[line.index(after: colon)...])
            var parts = head.split(separator: ";").map(String.init)
            let key = parts.removeFirst().uppercased()
            var params: [String: String] = [:]
            for part in parts { let pair = part.split(separator: "=", maxSplits: 1); if pair.count == 2 { params[pair[0].uppercased()] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) } }
            switch (key, value.uppercased()) {
            case ("BEGIN", "VEVENT"): current = [:]; exdates = []; depth = 0
            case ("BEGIN", _): if current != nil { depth += 1 }
            case ("END", "VEVENT"):
                if let properties = current, let event = Self.event(properties, exdates: exdates) { calendar.events.append(event) }
                current = nil
            case ("END", _): if current != nil { depth -= 1 }
            case ("X-WR-CALNAME", _): if current == nil { calendar.name = unescape(value) }
            case ("EXDATE", _): if current != nil, depth == 0 { exdates.append((params, value)) }
            default: if current != nil, depth == 0, current?[key] == nil { current?[key] = (params, value) }
            }
        }
        return calendar
    }

    /// Every occurrence that overlaps [from, to], as (event, start, end), sorted by start.
    public func occurrences(from: Date, to: Date) -> [(event: Event, start: Date, end: Date)] {
        var moved: [String: Set<Date>] = [:]
        for event in events { if let replaced = event.replaces { moved[event.uid, default: []].insert(replaced) } }
        var result: [(Event, Date, Date)] = []
        for event in events {
            let length = event.end.timeIntervalSince(event.start)
            for start in Self.starts(of: event, from: from.addingTimeInterval(-length), until: to) where !event.excluded.contains(start) && !(event.replaces == nil && moved[event.uid]?.contains(start) == true) {
                let end = start.addingTimeInterval(length)
                if end > from && start < to { result.append((event, start, end)) }
            }
        }
        return result.sorted { $0.1 < $1.1 }
    }

    // MARK: Reading

    private static func event(_ p: [String: (params: [String: String], value: String)], exdates: [(params: [String: String], value: String)]) -> Event? {
        guard p["STATUS"]?.value.uppercased() != "CANCELLED", let startField = p["DTSTART"],
              let (start, allDay, zone) = date(startField.value, params: startField.params) else { return nil }
        var end: Date
        if let endField = p["DTEND"], let (parsed, _, _) = date(endField.value, params: endField.params) { end = parsed }
        else if let duration = p["DURATION"].flatMap({ Self.duration($0.value) }) { end = start.addingTimeInterval(duration) }
        else { end = allDay ? start.addingTimeInterval(86400) : start }
        if end < start { end = start }
        var event = Event(uid: p["UID"]?.value ?? UUID().uuidString, title: unescape(p["SUMMARY"]?.value ?? "Event"), start: start, end: end, allDay: allDay,
                          location: p["LOCATION"].map { unescape($0.value) }, url: p["URL"]?.value, notes: p["DESCRIPTION"].map { unescape($0.value) },
                          rule: p["RRULE"].flatMap { rule($0.value) }, timeZone: zone)
        for field in exdates { for value in field.value.split(separator: ",") { if let (date, _, _) = date(String(value), params: field.params) { event.excluded.insert(date) } } }
        if let moved = p["RECURRENCE-ID"], let (date, _, _) = date(moved.value, params: moved.params) { event.replaces = date }
        return event
    }

    /// The colon that separates a property's name and parameters from its value (parameter
    /// values may be quoted and contain colons, as in TZID="(UTC-05:00) Eastern").
    private static func valueSeparator(in line: String) -> String.Index? {
        var quoted = false
        for index in line.indices {
            switch line[index] { case "\"": quoted.toggle(); case ":" where !quoted: return index; default: continue }
        }
        return nil
    }

    static func date(_ value: String, params: [String: String]) -> (Date, Bool, TimeZone)? {
        let text = value.trimmingCharacters(in: .whitespaces)
        let zone = params["TZID"].flatMap(timeZone) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        if params["VALUE"]?.uppercased() == "DATE" || text.count == 8 {
            guard text.count == 8, let y = Int(text.prefix(4)), let m = Int(text.dropFirst(4).prefix(2)), let d = Int(text.suffix(2)) else { return nil }
            calendar.timeZone = .current
            return calendar.date(from: DateComponents(year: y, month: m, day: d)).map { ($0, true, .current) }
        }
        let utc = text.hasSuffix("Z")
        let digits = text.replacingOccurrences(of: "Z", with: "").replacingOccurrences(of: "T", with: "")
        guard digits.count >= 12, let y = Int(digits.prefix(4)), let mo = Int(digits.dropFirst(4).prefix(2)), let d = Int(digits.dropFirst(6).prefix(2)),
              let h = Int(digits.dropFirst(8).prefix(2)), let mi = Int(digits.dropFirst(10).prefix(2)) else { return nil }
        let s = digits.count >= 14 ? Int(digits.dropFirst(12).prefix(2)) ?? 0 : 0
        calendar.timeZone = utc ? TimeZone(identifier: "UTC")! : zone
        return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s)).map { ($0, false, utc ? .current : zone) }
    }

    /// IANA names, plus the Windows names Outlook writes.
    static func timeZone(_ name: String) -> TimeZone? {
        if let zone = TimeZone(identifier: name) { return zone }
        let windows: [String: String] = [
            "Eastern Standard Time": "America/New_York", "US Eastern Standard Time": "America/Indiana/Indianapolis",
            "Central Standard Time": "America/Chicago", "Mountain Standard Time": "America/Denver", "US Mountain Standard Time": "America/Phoenix",
            "Pacific Standard Time": "America/Los_Angeles", "Alaskan Standard Time": "America/Anchorage", "Hawaiian Standard Time": "Pacific/Honolulu",
            "Atlantic Standard Time": "America/Halifax", "GMT Standard Time": "Europe/London", "W. Europe Standard Time": "Europe/Berlin",
            "Romance Standard Time": "Europe/Paris", "Arabian Standard Time": "Asia/Dubai", "India Standard Time": "Asia/Kolkata",
            "Pakistan Standard Time": "Asia/Karachi", "Arab Standard Time": "Asia/Riyadh", "Egypt Standard Time": "Africa/Cairo",
            "Turkey Standard Time": "Europe/Istanbul", "China Standard Time": "Asia/Shanghai", "Tokyo Standard Time": "Asia/Tokyo",
            "AUS Eastern Standard Time": "Australia/Sydney", "UTC": "UTC", "Coordinated Universal Time": "UTC",
        ]
        if let mapped = windows[name] { return TimeZone(identifier: mapped) }
        // "(UTC-05:00) Eastern Time (US & Canada)" style names.
        if name.contains("Eastern") { return TimeZone(identifier: "America/New_York") }
        if name.contains("Central") { return TimeZone(identifier: "America/Chicago") }
        if name.contains("Mountain") { return TimeZone(identifier: "America/Denver") }
        if name.contains("Pacific") { return TimeZone(identifier: "America/Los_Angeles") }
        return nil
    }

    static func duration(_ value: String) -> TimeInterval? {
        // P1D, PT1H30M, P1W
        var seconds = 0.0, number = "", inTime = false
        for char in value.uppercased().dropFirst(value.hasPrefix("-") ? 2 : 1) {
            if char.isNumber { number.append(char); continue }
            let n = Double(number) ?? 0; number = ""
            switch char {
            case "T": inTime = true
            case "W": seconds += n * 604_800
            case "D": seconds += n * 86400
            case "H": seconds += n * 3600
            case "M": seconds += inTime ? n * 60 : n * 2_592_000
            case "S": seconds += n
            default: return nil
            }
        }
        return seconds
    }

    static func rule(_ value: String) -> Rule? {
        var fields: [String: String] = [:]
        for part in value.split(separator: ";") { let pair = part.split(separator: "=", maxSplits: 1); if pair.count == 2 { fields[pair[0].uppercased()] = String(pair[1]) } }
        guard let frequency = fields["FREQ"].flatMap({ Rule.Frequency(rawValue: $0.uppercased()) }) else { return nil }
        var rule = Rule(frequency: frequency)
        rule.interval = max(1, Int(fields["INTERVAL"] ?? "1") ?? 1)
        rule.count = fields["COUNT"].flatMap(Int.init)
        rule.until = fields["UNTIL"].flatMap { date($0, params: [:])?.0 }
        let days = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]
        rule.weekdays = (fields["BYDAY"] ?? "").split(separator: ",").compactMap { days[String($0.suffix(2)).uppercased()] }.sorted()
        return rule
    }

    /// Start times of an event's occurrences up to `limit`, in its own time zone (so a
    /// 9 AM lecture stays at 9 AM across daylight saving).
    private static func starts(of event: Event, from: Date, until limit: Date) -> [Date] {
        guard let rule = event.rule else { return [event.start] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = event.timeZone
        let end = min(limit, rule.until ?? .distantFuture)
        var starts: [Date] = []
        // Without COUNT, skip straight to the window instead of walking from a start years ago.
        let period: Double = switch rule.frequency { case .daily: 86400; case .weekly: 604_800; case .monthly: 2_629_800; case .yearly: 31_557_600 }
        var step = rule.count == nil ? max(0, Int(from.timeIntervalSince(event.start) / (period * Double(rule.interval))) - 1) : 0
        let lastStep = step + 5000
        while starts.count < 2000, step < lastStep {
            let periodStart: Date?
            switch rule.frequency {
            case .daily: periodStart = calendar.date(byAdding: .day, value: step * rule.interval, to: event.start)
            case .weekly: periodStart = calendar.date(byAdding: .weekOfYear, value: step * rule.interval, to: event.start)
            case .monthly: periodStart = calendar.date(byAdding: .month, value: step * rule.interval, to: event.start)
            case .yearly: periodStart = calendar.date(byAdding: .year, value: step * rule.interval, to: event.start)
            }
            // A week's BYDAY days can fall before its anchor day, so weekly runs one week past the end.
            guard let period = periodStart, period <= end.addingTimeInterval(rule.frequency == .weekly ? 604_800 : 0) else { break }
            var candidates = [period]
            if rule.frequency == .weekly, !rule.weekdays.isEmpty {
                // The days named in BYDAY within this occurrence's week, at the event's time of day.
                let weekday = calendar.component(.weekday, from: period)
                candidates = rule.weekdays.compactMap { calendar.date(byAdding: .day, value: $0 - weekday, to: period) }
            }
            for candidate in candidates.sorted() where candidate >= event.start && candidate <= end {
                starts.append(candidate)
                if let count = rule.count, starts.count >= count { return starts }
            }
            step += 1
        }
        return starts
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";").replacingOccurrences(of: "\\\\", with: "\\")
    }
}
