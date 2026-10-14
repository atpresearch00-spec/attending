import Foundation

/// A board or course exam with its countdown and study plan.
public struct BoardExam: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case comlex1, comlex2, comlex3, step1, step2, step3, shelf, block, custom
        public var title: String {
            switch self {
            case .comlex1: "COMLEX Level 1"; case .comlex2: "COMLEX Level 2-CE"; case .comlex3: "COMLEX Level 3"
            case .step1: "USMLE Step 1"; case .step2: "USMLE Step 2 CK"; case .step3: "USMLE Step 3"
            case .shelf: "Shelf exam"; case .block: "Block exam"; case .custom: "Custom"
            }
        }
        /// Short form for the notch: "Level 1", "Step 2 CK".
        public var short: String {
            switch self {
            case .comlex1: "Level 1"; case .comlex2: "Level 2"; case .comlex3: "Level 3"
            case .step1: "Step 1"; case .step2: "Step 2 CK"; case .step3: "Step 3"
            case .shelf: "Shelf"; case .block: "Exam"; case .custom: "Exam"
            }
        }
        /// Level 1 and Step 1 are reported pass/fail, so they get no target score.
        public var passFail: Bool { self == .comlex1 || self == .step1 }
        public var isBoard: Bool { [.comlex1, .comlex2, .comlex3, .step1, .step2, .step3].contains(self) }
        /// Typical days from the exam to scores, as a starting estimate the user can change.
        public var typicalScoreDays: Int? {
            switch self {
            case .step1, .step2, .step3: 21
            case .comlex1, .comlex2, .comlex3: 28
            default: nil
            }
        }
    }
    public struct Practice: Codable, Identifiable, Equatable, Sendable {
        public var id = UUID()
        public var name: String
        public var date: Date
        public var score: Int?
        public init(name: String, date: Date, score: Int? = nil) { self.name = name; self.date = date; self.score = score }
    }

    public var id = UUID()
    public var kind: Kind
    public var customName: String = ""
    /// Exam start (date and time).
    public var date: Date
    public var dedicatedStart: Date?
    public var targetScore: Int?
    /// Weekdays without studying (Calendar weekday numbers, 1 = Sunday).
    public var daysOff: Set<Int> = []
    public var bankName: String = "UWorld"
    public var bankTotal: Int?
    public var bankDone: Int = 0
    public var practice: [Practice] = []
    public var scoreRelease: Date?
    public var checklistDone: Set<String> = []
    /// Logged after the fact (a past score), so it's over regardless of the time of day.
    public var logged = false
    /// Your result once it's out: a percent for block, shelf and custom exams, the score for boards.
    public var result: Double?
    public var resultIsPercent: Bool { !kind.isBoard }
    public var resultText: String? {
        result.map { resultIsPercent ? "\(Int($0.rounded()))%" : "\(Int($0.rounded()))" }
    }

    public init(kind: Kind, date: Date, customName: String = "") { self.kind = kind; self.date = date; self.customName = customName }

    // Every field but the exam itself is optional when loading, so exams saved by older
    // versions keep loading as fields are added.
    private enum CodingKeys: String, CodingKey { case id, kind, customName, date, dedicatedStart, targetScore, daysOff, bankName, bankTotal, bankDone, practice, scoreRelease, checklistDone, logged, result }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        date = try c.decode(Date.self, forKey: .date)
        customName = try c.decodeIfPresent(String.self, forKey: .customName) ?? ""
        dedicatedStart = try c.decodeIfPresent(Date.self, forKey: .dedicatedStart)
        targetScore = try c.decodeIfPresent(Int.self, forKey: .targetScore)
        daysOff = try c.decodeIfPresent(Set<Int>.self, forKey: .daysOff) ?? []
        bankName = try c.decodeIfPresent(String.self, forKey: .bankName) ?? "UWorld"
        bankTotal = try c.decodeIfPresent(Int.self, forKey: .bankTotal)
        bankDone = try c.decodeIfPresent(Int.self, forKey: .bankDone) ?? 0
        practice = try c.decodeIfPresent([Practice].self, forKey: .practice) ?? []
        scoreRelease = try c.decodeIfPresent(Date.self, forKey: .scoreRelease)
        checklistDone = try c.decodeIfPresent(Set<String>.self, forKey: .checklistDone) ?? []
        logged = try c.decodeIfPresent(Bool.self, forKey: .logged) ?? false
        result = try c.decodeIfPresent(Double.self, forKey: .result)
    }

    public var name: String {
        let custom = customName.trimmingCharacters(in: .whitespaces)
        return kind == .custom || ((kind == .shelf || kind == .block) && !custom.isEmpty) ? (custom.isEmpty ? "Exam" : custom) : kind.title
    }
    public var shortName: String {
        let custom = customName.trimmingCharacters(in: .whitespaces)
        return kind.isBoard || custom.isEmpty ? kind.short : custom
    }
    public var bankLeft: Int? { bankTotal.map { max(0, $0 - bankDone) } }
    /// The estimated or set score release date, once the exam is over.
    public var expectedScores: Date? {
        scoreRelease ?? kind.typicalScoreDays.flatMap { Calendar.current.date(byAdding: .day, value: $0, to: date) }
    }
    public var nextPractice: Practice? { practice.filter { $0.date >= Calendar.current.startOfDay(for: Date()) }.min { $0.date < $1.date } }
    public var scoredPractice: [Practice] { practice.filter { $0.score != nil }.sorted { $0.date < $1.date } }
}

/// Countdown math, kept free of UI so it can be checked.
public enum BoardsMath {
    public enum Phase: Equatable, Sendable { case preDedicated(daysToDedicated: Int), dedicated, finalWeek, examDay, finished
        public var title: String {
            switch self {
            case .preDedicated(let days): days == 1 ? "Dedicated starts tomorrow" : "Dedicated starts in \(days) days"
            case .dedicated: "Dedicated"
            case .finalWeek: "Final week"
            case .examDay: "Exam day"
            case .finished: "Done"
            }
        }
    }

    public static func calendarDays(from now: Date, to exam: Date, calendar: Calendar = .current) -> Int {
        max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: exam)).day ?? 0)
    }
    /// Days left to study: from today up to the day before the exam, skipping days off.
    public static func studyDays(from now: Date, to exam: Date, daysOff: Set<Int>, calendar: Calendar = .current) -> Int {
        var day = calendar.startOfDay(for: now), count = 0
        let examDay = calendar.startOfDay(for: exam)
        while day < examDay, count < 2000 {
            if !daysOff.contains(calendar.component(.weekday, from: day)) { count += 1 }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return count
    }
    public static func phase(for exam: BoardExam, now: Date, calendar: Calendar = .current) -> Phase {
        if exam.logged || now >= exam.date.addingTimeInterval(8 * 3600) { return .finished }
        let days = calendarDays(from: now, to: exam.date, calendar: calendar)
        if days == 0 { return .examDay }
        if days <= 7 { return .finalWeek }
        if let start = exam.dedicatedStart, now < calendar.startOfDay(for: start) {
            return .preDedicated(daysToDedicated: calendarDays(from: now, to: start, calendar: calendar))
        }
        return .dedicated
    }
    /// Share of the dedicated period that has passed, when one is set.
    public static func dedicatedProgress(for exam: BoardExam, now: Date) -> Double? {
        guard let start = exam.dedicatedStart, exam.date > start else { return nil }
        return min(1, max(0, now.timeIntervalSince(start) / exam.date.timeIntervalSince(start)))
    }
    /// Questions to do per study day to finish the bank, counting from the start of today
    /// so the target holds steady through the day (`doneAtDayStart` is the count at midnight).
    public static func questionsPerDay(for exam: BoardExam, doneAtDayStart: Int, now: Date, calendar: Calendar = .current) -> Int? {
        guard let total = exam.bankTotal, total > 0 else { return nil }
        let left = max(0, total - doneAtDayStart)
        guard left > 0 else { return 0 }
        var days = studyDays(from: now, to: exam.date, daysOff: exam.daysOff, calendar: calendar)
        // A day off today still has the rest of the plan; never divide by zero.
        if days == 0 { days = 1 }
        return Int((Double(left) / Double(days)).rounded(.up))
    }
    public static let milestones = [100, 60, 30, 14, 7, 3, 1]
    /// The milestone today is, if any ("30 days to go").
    public static func milestone(for exam: BoardExam, now: Date, calendar: Calendar = .current) -> Int? {
        let days = calendarDays(from: now, to: exam.date, calendar: calendar)
        return milestones.contains(days) ? days : nil
    }
    /// The countdown in the user's chosen unit: "42 days", "6 weeks", "31 study days",
    /// and hours and minutes inside the last day.
    public enum Unit: String, CaseIterable, Sendable { case days, weeks, studyDays
        public var title: String { switch self { case .days: "Days"; case .weeks: "Weeks"; case .studyDays: "Study days" } }
    }
    public static func countdown(for exam: BoardExam, unit: Unit, now: Date, calendar: Calendar = .current) -> (value: String, label: String) {
        let seconds = exam.date.timeIntervalSince(now)
        if seconds <= 0 { return ("Today", "good luck") }
        if seconds < 24 * 3600 {
            let minutes = Int(seconds / 60)
            return (minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m", "to go")
        }
        let days = calendarDays(from: now, to: exam.date, calendar: calendar)
        switch unit {
        case .days: return ("\(days)", days == 1 ? "day" : "days")
        case .weeks:
            let weeks = Double(days) / 7
            return (weeks < 2 ? "\(days)" : String(format: weeks.truncatingRemainder(dividingBy: 1) < 0.25 ? "%.0f" : "%.1f", weeks), weeks < 2 ? (days == 1 ? "day" : "days") : "weeks")
        case .studyDays:
            let study = studyDays(from: now, to: exam.date, daysOff: exam.daysOff, calendar: calendar)
            return ("\(study)", study == 1 ? "study day" : "study days")
        }
    }
}
