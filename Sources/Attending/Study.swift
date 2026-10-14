import AppKit
import SQLite3
import Security
import AttendingCore
import SwiftUI

// MARK: - Anki

/// Review stats read directly from Anki's collection (read-only, short-lived
/// connections), so no add-on is needed. Counts follow Anki's own day boundary
/// (the rollover hour, 4 AM by default).
@MainActor final class AnkiService: ObservableObject {
    struct Stats: Equatable {
        var dueReviews = 0
        var learning = 0
        var dueTomorrow = 0
        var reviewedToday = 0
        var minutesToday = 0
        var streak = 0
        /// Reviews for the last 7 days, oldest first.
        var week: [Int] = []
        /// One card due today, the same all day: front and back as plain text.
        var cardOfDay: (front: String, back: String)?
        static func == (a: Stats, b: Stats) -> Bool {
            a.dueReviews == b.dueReviews && a.learning == b.learning && a.dueTomorrow == b.dueTomorrow && a.reviewedToday == b.reviewedToday
                && a.minutesToday == b.minutesToday && a.streak == b.streak && a.week == b.week && a.cardOfDay?.front == b.cardOfDay?.front
        }
    }
    struct Deck: Identifiable, Equatable { var id: String { name }; var name: String; var new: Int; var learning: Int; var review: Int; var total: Int { new + learning + review } }
    @Published private(set) var stats: Stats? {
        didSet { if let demoStats, stats != demoStats { stats = demoStats } }
    }
    /// Sample stats for video captures, kept over refreshes (never saved).
    var demoStats: Stats? { didSet { stats = demoStats } }
    /// Per-deck counts from AnkiConnect (as Anki's deck list shows them), when Anki is open.
    @Published private(set) var decks: [Deck] = []
    @Published private(set) var newCards: Int?
    @Published private(set) var profile: String?
    @Published private(set) var installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.ankiweb.anki") != nil
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var loading = false

    private var base: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Anki2") }
    /// The profile with the most recently modified collection.
    private var collection: URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return nil }
        return names.map { base.appendingPathComponent($0).appendingPathComponent("collection.anki2") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .max { modified($0) < modified($1) }
    }
    private func modified(_ url: URL) -> Date {
        let wal = URL(fileURLWithPath: url.path + "-wal")
        return [url, wal].compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max() ?? .distantPast
    }

    func start() {
        guard observers.isEmpty else { return }
        refresh()
        // Refresh when you leave or quit Anki, and every 10 minutes for the day rollover.
        for name in [NSWorkspace.didDeactivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == "net.ankiweb.anki" else { return }
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        let timer = Timer(timeInterval: 600, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    /// Reviews done today: AnkiConnect when Anki is open (live), otherwise the collection.
    func reviewsToday() async -> Int? {
        if let count = await Self.ankiConnect("getNumCardsReviewedToday", [:]) as? Int { return count }
        guard let path = collection?.path else { return nil }
        return await Task.detached(priority: .utility) { AnkiService.read(path: path)?.reviewedToday }.value
    }
    /// Opens a deck straight into review through AnkiConnect, or just opens Anki.
    func review(_ deck: Deck) {
        Task {
            if await Self.ankiConnect("guiDeckReview", ["name": deck.name]) == nil { openAnki() }
            else if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "net.ankiweb.anki").first { app.activate() }
        }
    }
    func openAnki() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.ankiweb.anki") { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
    }

    func refresh() {
        guard !loading, let url = collection else { return }
        loading = true
        profile = url.deletingLastPathComponent().lastPathComponent
        let path = url.path
        Task { await refreshDecks() }
        Task.detached(priority: .utility) {
            let result = AnkiService.read(path: path)
            await MainActor.run { [weak self] in
                self?.loading = false
                if let result { self?.stats = result }
            }
        }
    }

    private func refreshDecks() async {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "net.ankiweb.anki").first != nil,
              let names = await Self.ankiConnect("deckNames", [:]) as? [String] else { decks = []; newCards = nil; return }
        let top = names.filter { !$0.contains("::") }
        guard let result = await Self.ankiConnect("getDeckStats", ["decks": top]) as? [String: Any] else { return }
        decks = result.values.compactMap { value in
            guard let deck = value as? [String: Any], let name = deck["name"] as? String else { return nil }
            return Deck(name: name, new: deck["new_count"] as? Int ?? 0, learning: deck["learn_count"] as? Int ?? 0, review: deck["review_count"] as? Int ?? 0)
        }.filter { $0.total > 0 }.sorted { $0.total > $1.total }
        newCards = decks.reduce(0) { $0 + $1.new }
    }
    /// AnkiConnect (add-on 2055492159) on localhost; nil when Anki is closed or the call fails.
    private static func ankiConnect(_ action: String, _ params: [String: Any]) async -> Any? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765")!, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["action": action, "version": 6, "params": params])
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["error"] is NSNull || object["error"] == nil else { return nil }
        return object["result"]
    }

    /// Plain-text faces of a note: the first field is the front and the second the back; a
    /// cloze note shows its blanks as […] on the front and filled in on the back.
    nonisolated static func cardFaces(_ fields: String) -> (front: String, back: String)? {
        let parts = fields.components(separatedBy: "\u{1f}").map(plain)
        guard let first = parts.first, !first.isEmpty else { return nil }
        if first.contains("{{c") {
            let cloze = #"\{\{c\d+::(.*?)(::(.*?))?\}\}"#
            let front = first.replacingOccurrences(of: cloze, with: "[…]", options: .regularExpression)
            let back = first.replacingOccurrences(of: cloze, with: "$1", options: .regularExpression)
            return (clip(front), clip(back))
        }
        return (clip(first), clip(parts.count > 1 ? parts[1] : ""))
    }
    nonisolated private static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<br\\s*/?>|</div>|</p>|</li>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\[sound:[^\\]]*\\]", with: "", options: .regularExpression)
        for (entity, char) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] { text = text.replacingOccurrences(of: entity, with: char) }
        return text.replacingOccurrences(of: "\n{2,}", with: "\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    nonisolated private static func clip(_ text: String) -> String { text.count > 280 ? String(text.prefix(277)) + "…" : text }

    nonisolated private static func read(path: String) -> Stats? {
        var db: OpaquePointer?
        // Read-only opens of a WAL database fail when Anki is closed (no -wal/-shm files to
        // attach to). Anki isn't writing then, so fall back to an immutable snapshot.
        let uriPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) != SQLITE_OK || sqlite3_exec(db, "SELECT 1 FROM col LIMIT 1", nil, nil, nil) != SQLITE_OK {
            sqlite3_close(db); db = nil
            guard sqlite3_open_v2("file:\(uriPath)?immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        }
        guard let db else { return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 800)
        func scalar(_ sql: String, _ bind: [Int64] = []) -> Int64? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            for (index, value) in bind.enumerated() { sqlite3_bind_int64(statement, Int32(index + 1), value) }
            return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : nil
        }
        guard let crt = scalar("SELECT crt FROM col") else { return nil }
        var rollover = 4
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT val FROM config WHERE key = 'rollover'", -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW,
           let bytes = sqlite3_column_blob(statement, 0) {
            let text = String(decoding: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))), as: UTF8.self)
            rollover = Int(text.trimmingCharacters(in: .whitespaces)) ?? 4
        }
        sqlite3_finalize(statement)

        // Anki's day number: calendar days between the (rollover-shifted) creation day and today.
        let calendar = Calendar.current
        let now = Date()
        let shift = TimeInterval(rollover * 3600)
        let dayStart = calendar.startOfDay(for: now.addingTimeInterval(-shift)).addingTimeInterval(shift)
        let created = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(crt)).addingTimeInterval(-shift))
        let today = Int64(calendar.dateComponents([.day], from: created, to: calendar.startOfDay(for: now.addingTimeInterval(-shift))).day ?? 0)
        let learnAhead = Int64(now.timeIntervalSince1970) + 20 * 60

        var stats = Stats()
        stats.dueReviews = Int(scalar("SELECT count() FROM cards WHERE queue IN (2, 3) AND due <= ?", [today]) ?? 0)
        stats.learning = Int(scalar("SELECT count() FROM cards WHERE queue = 1 AND due <= ?", [learnAhead]) ?? 0)
        stats.dueTomorrow = Int(scalar("SELECT count() FROM cards WHERE queue IN (2, 3) AND due = ?", [today + 1]) ?? 0)
        let startMs = Int64(dayStart.timeIntervalSince1970 * 1000)
        stats.reviewedToday = Int(scalar("SELECT count() FROM revlog WHERE id >= ?", [startMs]) ?? 0)
        stats.minutesToday = Int((scalar("SELECT coalesce(sum(time), 0) FROM revlog WHERE id >= ?", [startMs]) ?? 0) / 60_000)

        // Days with reviews, as whole days before today's start (0 = today).
        var studied = Set<Int>()
        var week = [Int](repeating: 0, count: 7)
        let since = startMs - Int64(400) * 86_400_000
        let sql = "SELECT CASE WHEN id >= ?1 THEN 0 ELSE (?1 - id - 1) / 86400000 + 1 END, count() FROM revlog WHERE id >= ?2 GROUP BY 1"
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, startMs)
            sqlite3_bind_int64(statement, 2, since)
            while sqlite3_step(statement) == SQLITE_ROW {
                let daysAgo = Int(sqlite3_column_int64(statement, 0))
                studied.insert(daysAgo)
                if daysAgo < 7 { week[6 - daysAgo] += Int(sqlite3_column_int64(statement, 1)) }
            }
        }
        sqlite3_finalize(statement)
        stats.week = week
        // Card of the day: a due review card picked by today's date, so it holds all day.
        var card: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT n.flds FROM cards c JOIN notes n ON n.id = c.nid WHERE c.queue IN (2, 3) AND c.due <= ?1 ORDER BY (c.id % 1000003) * ?2 % 1000003 LIMIT 1", -1, &card, nil) == SQLITE_OK {
            sqlite3_bind_int64(card, 1, today)
            sqlite3_bind_int64(card, 2, today * 7919 + 1)
            if sqlite3_step(card) == SQLITE_ROW, let raw = sqlite3_column_text(card, 0) {
                stats.cardOfDay = AnkiService.cardFaces(String(cString: raw))
            }
        }
        sqlite3_finalize(card)
        var day = studied.contains(0) ? 0 : 1
        while studied.contains(day) { stats.streak += 1; day += 1 }
        return stats
    }
}

// MARK: - Boards and exams

/// Board and course exams: countdowns, the question-bank pace, practice exams, the
/// exam-day checklist and the reminders around them.
@MainActor final class ExamStore: ObservableObject {
    enum Calm: String, CaseIterable { case off, weeks, hideUntil30
        var title: String { switch self { case .off: "Off"; case .weeks: "Weeks only"; case .hideUntil30: "Hide until 30 days out" } }
    }
    static let checklist = ["Photo ID (two forms if required)", "Scheduling permit or admission letter", "Directions, parking and arrival time", "Snacks, water and lunch", "Layers (testing rooms run cold)", "Earplugs if allowed", "Sleep by 10 PM"]

    @Published private(set) var exams: [BoardExam] = []
    @Published var unit: BoardsMath.Unit { didSet { defaults.set(unit.rawValue, forKey: "boardsUnit") } }
    @Published var calm: Calm { didSet { defaults.set(calm.rawValue, forKey: "boardsCalm") } }
    @Published var amberDays: Int { didSet { defaults.set(amberDays, forKey: "boardsAmber") } }
    @Published var redDays: Int { didSet { defaults.set(redDays, forKey: "boardsRed") } }
    @Published var milestoneAlerts: Bool { didSet { defaults.set(milestoneAlerts, forKey: "boardsMilestones") } }
    @Published var pinToNotch: Bool { didSet { defaults.set(pinToNotch, forKey: "boardsPinNotch") } }
    @Published var checklistReminder: Bool { didSet { defaults.set(checklistReminder, forKey: "boardsChecklist") } }
    @Published var bedtimeNudge: Bool { didSet { defaults.set(bedtimeNudge, forKey: "boardsBedtime"); schedule() } }
    /// Bedtime before exams, as minutes after midnight (11 PM unless set).
    @Published var bedtimeMinutes: Int { didSet { defaults.set(bedtimeMinutes, forKey: "boardsBedtimeAt"); schedule() } }
    var onBedtime: ((BoardExam, Int) -> Void)?
    @Published var pinnedID: UUID? { didSet { if !demo { defaults.set(pinnedID?.uuidString, forKey: "boardsPinned") } } }
    var onMilestone: ((BoardExam, Int) -> Void)?
    var onExamMorning: ((BoardExam) -> Void)?
    var onChecklist: ((BoardExam) -> Void)?
    var onFinished: ((BoardExam) -> Void)?
    private let defaults = UserDefaults.standard
    private var timer: Task<Void, Never>?
    /// Question-bank count at the start of each day, per exam, so today's target holds steady.
    private var dayStarts: [String: [String: Int]]

    init() {
        unit = BoardsMath.Unit(rawValue: defaults.string(forKey: "boardsUnit") ?? "") ?? .days
        calm = Calm(rawValue: defaults.string(forKey: "boardsCalm") ?? "") ?? .off
        amberDays = defaults.object(forKey: "boardsAmber") as? Int ?? 30
        redDays = defaults.object(forKey: "boardsRed") as? Int ?? 7
        milestoneAlerts = defaults.object(forKey: "boardsMilestones") as? Bool ?? true
        pinToNotch = defaults.bool(forKey: "boardsPinNotch")
        checklistReminder = defaults.object(forKey: "boardsChecklist") as? Bool ?? true
        pinnedID = defaults.string(forKey: "boardsPinned").flatMap(UUID.init)
        bedtimeNudge = defaults.object(forKey: "boardsBedtime") as? Bool ?? true
        bedtimeMinutes = defaults.object(forKey: "boardsBedtimeAt") as? Int ?? 23 * 60
        dayStarts = (defaults.dictionary(forKey: "boardsDayStarts") as? [String: [String: Int]]) ?? [:]
        if let data = defaults.data(forKey: "boardExams"), let saved = try? JSONDecoder().decode([BoardExam].self, from: data) {
            exams = saved.sorted { $0.date < $1.date }
        } else if let data = defaults.data(forKey: "exams"), let old = try? JSONDecoder().decode([OldExam].self, from: data) {
            // Exams from before boards mode: keep them, guessing the preset from the name.
            exams = old.map { BoardExam(kind: Self.guessKind($0.name), date: Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: $0.date) ?? $0.date, customName: $0.name) }.sorted { $0.date < $1.date }
            save()
        }
    }
    private struct OldExam: Codable { var name: String; var date: Date }
    private static func guessKind(_ name: String) -> BoardExam.Kind {
        let lower = name.lowercased()
        if lower.contains("level 1") { return .comlex1 }
        if lower.contains("level 2") { return .comlex2 }
        if lower.contains("level 3") { return .comlex3 }
        if lower.contains("step 1") { return .step1 }
        if lower.contains("step 2") { return .step2 }
        if lower.contains("step 3") { return .step3 }
        if lower.contains("shelf") || lower.contains("comat") || lower.contains("nbme") { return .shelf }
        return .block
    }

    /// Upcoming exams (including today's until it's over).
    var upcoming: [BoardExam] { exams.filter { BoardsMath.phase(for: $0, now: Date()) != .finished } }
    var next: BoardExam? { upcoming.first }
    /// Exams that are over, newest first, for the score tracker.
    var past: [BoardExam] { exams.filter { BoardsMath.phase(for: $0, now: Date()) == .finished }.sorted { $0.date > $1.date } }
    func setResult(_ value: Double?, for exam: BoardExam) {
        guard var updated = exams.first(where: { $0.id == exam.id }) else { return }
        updated.result = value
        save(updated)
    }
    /// Logs a past exam and its score in one go.
    func logPast(kind: BoardExam.Kind, name: String, date: Date, result: Double) {
        var exam = BoardExam(kind: kind, date: Calendar.current.startOfDay(for: date), customName: name)
        exam.result = result
        exam.logged = true
        save(exam)
    }
    /// The exam shown in the notch and on Home: the pinned one, else the next.
    var pinned: BoardExam? { upcoming.first { $0.id == pinnedID } ?? next }
    /// Calm mode can hide a countdown until 30 days out.
    func visible(_ exam: BoardExam) -> Bool { calm != .hideUntil30 || BoardsMath.calendarDays(from: Date(), to: exam.date) <= 30 }
    func countdown(_ exam: BoardExam, now: Date = Date()) -> (value: String, label: String) {
        BoardsMath.countdown(for: exam, unit: calm == .weeks ? .weeks : unit, now: now)
    }
    /// "42d" style label for small spaces.
    func compact(_ exam: BoardExam) -> String {
        let (value, label) = countdown(exam)
        if label == "to go" || value == "Today" { return value }
        return value + (label.hasPrefix("week") ? "w" : label.hasPrefix("study") ? " sd" : "d")
    }
    func urgency(_ exam: BoardExam) -> Color {
        let days = BoardsMath.calendarDays(from: Date(), to: exam.date)
        return days <= redDays ? Theme.failed : days <= amberDays ? Theme.attention : Theme.primary
    }

    // MARK: Editing

    func save(_ exam: BoardExam) {
        if let index = exams.firstIndex(where: { $0.id == exam.id }) { exams[index] = exam } else { exams.append(exam) }
        exams.sort { $0.date < $1.date }
        save(); schedule()
    }
    func remove(_ exam: BoardExam) { exams.removeAll { $0.id == exam.id }; if pinnedID == exam.id { pinnedID = nil }; save(); schedule() }
    /// Logs question-bank questions (negative to undo).
    var onQuestions: ((Int) -> Void)?
    func logQuestions(_ count: Int, for exam: BoardExam) {
        guard var updated = exams.first(where: { $0.id == exam.id }) else { return }
        _ = doneAtDayStart(updated)
        let before = updated.bankDone
        updated.bankDone = max(0, min(updated.bankTotal ?? Int.max, updated.bankDone + count))
        if !demo { onQuestions?(updated.bankDone - before) }
        save(updated)
    }
    func toggleChecklist(_ item: String, for exam: BoardExam) {
        guard var updated = exams.first(where: { $0.id == exam.id }) else { return }
        if updated.checklistDone.contains(item) { updated.checklistDone.remove(item) } else { updated.checklistDone.insert(item) }
        save(updated)
    }
    /// The bank count when today began, recorded the first time it's asked for each day.
    func doneAtDayStart(_ exam: BoardExam) -> Int {
        let day = Self.dayKey(Date()), key = exam.id.uuidString
        if let start = dayStarts[key]?[day] { return start }
        dayStarts[key] = [day: exam.bankDone]   // Only today's entry is kept.
        if !demo { defaults.set(dayStarts, forKey: "boardsDayStarts") }
        return exam.bankDone
    }
    func questionsToday(_ exam: BoardExam) -> (done: Int, target: Int?) {
        let start = doneAtDayStart(exam)
        return (max(0, exam.bankDone - start), BoardsMath.questionsPerDay(for: exam, doneAtDayStart: start, now: Date()))
    }
    private func save() { guard !demo else { return }; defaults.set(try? JSONEncoder().encode(exams), forKey: "boardExams") }
    /// For screenshots and videos: sample exams that are never saved.
    private var demo = false
    func showDemo(_ sample: [BoardExam]) { demo = true; exams = sample; pinnedID = nil; timer?.cancel() }
    private static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: Reminders

    /// Sleeps until the next reminder: a milestone morning ("30 days to go"), the checklist
    /// the evening before, good luck on exam morning, and "you did it" after. Each fires once.
    func schedule() {
        timer?.cancel()
        let now = Date(), calendar = Calendar.current
        var fired = Set(defaults.stringArray(forKey: "boardsFired") ?? [])
        var upcomingEvents: [(Date, String, () -> Void)] = []
        for exam in exams where !exam.logged {
            let id = exam.id.uuidString
            let examDay = calendar.startOfDay(for: exam.date)
            if milestoneAlerts {
                for days in BoardsMath.milestones {
                    if let day = calendar.date(byAdding: .day, value: -days, to: examDay), let at = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) {
                        upcomingEvents.append((at, "\(id)-m\(days)", { [weak self] in self?.onMilestone?(exam, days) }))
                    }
                }
            }
            if bedtimeNudge {
                // Two nights before and the night before: half an hour before bedtime.
                for days in [2, 1] {
                    if let night = calendar.date(byAdding: .day, value: -days, to: examDay) {
                        let at = night.addingTimeInterval(TimeInterval(bedtimeMinutes * 60 - 30 * 60))
                        upcomingEvents.append((at, "\(id)-bed\(days)", { [weak self] in self?.onBedtime?(exam, days) }))
                    }
                }
            }
            if checklistReminder, let eve = calendar.date(byAdding: .day, value: -1, to: examDay), let at = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: eve) {
                upcomingEvents.append((at, "\(id)-list", { [weak self] in self?.onChecklist?(exam) }))
            }
            let morning = max(exam.date.addingTimeInterval(-2 * 3600), calendar.date(bySettingHour: 6, minute: 0, second: 0, of: examDay) ?? exam.date)
            upcomingEvents.append((min(morning, exam.date), "\(id)-luck", { [weak self] in self?.onExamMorning?(exam) }))
            upcomingEvents.append((exam.date.addingTimeInterval(8 * 3600), "\(id)-done", { [weak self] in self?.onFinished?(exam) }))
        }
        // Reminders missed by less than three hours (the Mac was asleep) still show; older ones don't.
        for (at, key, action) in upcomingEvents where at <= now && !fired.contains(key) {
            fired.insert(key)
            if now.timeIntervalSince(at) < 3 * 3600 { action() }
        }
        defaults.set(Array(fired), forKey: "boardsFired")
        guard let soonest = upcomingEvents.filter({ $0.0 > now && !fired.contains($0.1) }).min(by: { $0.0 < $1.0 }) else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, soonest.0.timeIntervalSinceNow + 1)))
            guard !Task.isCancelled else { return }
            self?.schedule()
        }
    }
}

// MARK: - PBL trackers (Google Sheets)

/// Reads and updates Google Sheets trackers through a small Apps Script web app the
/// user deploys once in their own Google account ("Execute as: Me"). Attending never
/// sees a Google password or token; requests carry a random secret the script checks,
/// and the script only serves spreadsheets whose names contain "Tracker" or "PBL" and
/// only ever flips checkbox cells.
@MainActor final class SheetTracker: ObservableObject {
    struct Tracker: Identifiable, Codable, Equatable {
        var id = UUID()
        var link: String
        var label: String
    }
    /// One reading: a row with a Status checkbox and a chapter title.
    struct Item: Identifiable, Equatable {
        var id: Int { row }
        var row: Int
        var statusColumn: Int
        var book: String
        var chapter: String
        var title: String
        var pages: Int
        var done: Bool
        var section: String?
        var label: String { chapter.isEmpty ? title : "\(chapter) · \(title)" }
    }
    struct Summary: Equatable {
        var title = ""
        var items: [Item] = []
        var examDate: Date?
        var preview: [[String]] = []
        var fetchedAt = Date()
        /// Set when the latest refresh or update failed and older data is shown.
        var problem: String?
        var chaptersDone: Int { items.filter(\.done).count }
        var pagesTotal: Int { items.reduce(0) { $0 + $1.pages } }
        var pagesLeft: Int { items.filter { !$0.done }.reduce(0) { $0 + $1.pages } }
        /// Share of readings left, by pages when the tracker has page counts (as the sheet does).
        var fractionLeft: Double {
            if pagesTotal > 0 { return Double(pagesLeft) / Double(pagesTotal) }
            return items.isEmpty ? 0 : Double(items.count - chaptersDone) / Double(items.count)
        }
        var daysLeft: Int? {
            examDate.map { max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: $0)).day ?? 0) }
        }
        var pending: [Item] { items.filter { !$0.done } }
        var fractionDone: Double { 1 - fractionLeft }
        var pagesDone: Int { pagesTotal - pagesLeft }
        /// "Exam 2" from "Fall 2026 PBL Exam 2 Reading Tracker".
        var shortName: String {
            title.range(of: #"Exam\s*\d+"#, options: [.regularExpression, .caseInsensitive]).map { String(title[$0]) } ?? title
        }
    }
    enum State: Equatable { case idle, loading, needsBridge, failed(String), loaded(Summary) }
    /// Today's share of the remaining reading: the pages left this morning spread
    /// evenly over the days until the exam, counted against pages checked off today.
    struct DailyGoal: Equatable {
        var target: Int
        var done: Int
        var met: Bool { done >= target }
        var fraction: Double { min(1, Double(done) / Double(max(1, target))) }
    }
    /// Where a tracker stood the first time it loaded today.
    private struct DayStart: Codable { var day: String; var pagesDone: Int; var pagesLeft: Int; var daysLeft: Int; var celebrated = false }

    @Published private(set) var trackers: [Tracker] = []
    @Published private(set) var states: [UUID: State] = [:] { didSet { noteDayStarts() } }
    private var dayStarts: [UUID: DayStart] = [:]
    private let dayStartsKey = "readingDayStarts"
    /// Called once a day per tracker when the day's reading goal is reached.
    var onGoalMet: ((Summary, DailyGoal) -> Void)?
    /// Pages read today across trackers, reported as trackers refresh.
    var onPagesToday: ((Int) -> Void)?
    @Published private(set) var bridgeURL: String?
    private let key = "sheetTrackers"
    /// Latest request per tracker; older responses are dropped so they can't undo newer check-offs.
    private var requestSerial: [UUID: Int] = [:]
    @Published private(set) var refreshing: Set<UUID> = []

    init() {
        if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode([Tracker].self, from: data) { trackers = saved }
        if let data = UserDefaults.standard.data(forKey: dayStartsKey), let saved = try? JSONDecoder().decode([UUID: DayStart].self, from: data) { dayStarts = saved }
        // Show the last good copy of each tracker immediately; refreshes update it.
        for tracker in trackers {
            if let (data, date) = TrackerCache.load(for: tracker.id), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                var summary = Self.summarize(values: object["values"] as? [[String]] ?? [], raw: object["raw"] as? [[Any]] ?? [])
                summary.title = object["title"] as? String ?? tracker.label
                summary.fetchedAt = date
                states[tracker.id] = .loaded(summary)
            }
        }
        bridgeURL = BridgeStore.read("url")
    }
    var connected: Bool { bridgeURL != nil && BridgeStore.read("secret") != nil }
    private static func dayKey(_ date: Date = Date()) -> String { date.formatted(.iso8601.year().month().day()) }

    /// Today's reading goal for a tracker; nil when it has no page counts or nothing is left.
    func goal(for tracker: Tracker, _ summary: Summary) -> DailyGoal? {
        guard summary.pagesTotal > 0, let days = summary.daysLeft else { return nil }
        // Before today's start is recorded (just after midnight), today starts from now.
        let start = dayStarts[tracker.id].flatMap { $0.day == Self.dayKey() ? $0 : nil }
            ?? DayStart(day: Self.dayKey(), pagesDone: summary.pagesDone, pagesLeft: summary.pagesLeft, daysLeft: days)
        guard start.pagesLeft > 0 else { return nil }
        let target = Int((Double(start.pagesLeft) / Double(max(1, start.daysLeft))).rounded(.up))
        return DailyGoal(target: target, done: max(0, summary.pagesDone - start.pagesDone))
    }
    var primaryGoal: DailyGoal? { primaryTracker.flatMap { goal(for: $0.tracker, $0.summary) } }

    /// Records each tracker's first state of the day and reports a goal reached.
    private func noteDayStarts() {
        guard !demo else { return }
        let today = Self.dayKey()
        var changed = false
        for tracker in trackers {
            guard case .loaded(let summary) = states[tracker.id], summary.pagesTotal > 0, let days = summary.daysLeft else { continue }
            if dayStarts[tracker.id]?.day != today {
                dayStarts[tracker.id] = DayStart(day: today, pagesDone: summary.pagesDone, pagesLeft: summary.pagesLeft, daysLeft: days)
                changed = true
            } else if dayStarts[tracker.id]?.celebrated == false, let goal = goal(for: tracker, summary), goal.met, goal.done > 0 {
                dayStarts[tracker.id]?.celebrated = true
                changed = true
                onGoalMet?(summary, goal)
            }
        }
        if changed, let data = try? JSONEncoder().encode(dayStarts) { UserDefaults.standard.set(data, forKey: dayStartsKey) }
        let pages = trackers.reduce(0) { total, tracker in
            guard case .loaded(let summary) = states[tracker.id] else { return total }
            return total + (goal(for: tracker, summary)?.done ?? 0)
        }
        onPagesToday?(pages)
    }

    /// The tracker picked in the Study tab (its id). The hover glance, Home and the daily
    /// reading goal follow it too.
    @Published var pickedID = UserDefaults.standard.string(forKey: "shownTracker") ?? "" {
        didSet {
            UserDefaults.standard.set(pickedID, forKey: "shownTracker")
            UserDefaults.standard.set(Date(), forKey: "shownTrackerAt")
        }
    }
    var picked: Tracker? { trackers.first { $0.id.uuidString == pickedID } }
    /// A pick lapses once its exam has passed since you picked it; picking a past
    /// tracker on purpose (to look back) keeps it.
    func pickLapsed(_ summary: Summary) -> Bool {
        guard let exam = summary.examDate else { return false }
        let today = Calendar.current.startOfDay(for: Date())
        let pickedAt = Calendar.current.startOfDay(for: UserDefaults.standard.object(forKey: "shownTrackerAt") as? Date ?? .distantPast)
        return exam < today && exam >= pickedAt
    }

    /// The tracker in focus: your pick unless its exam has passed, otherwise the loaded
    /// tracker with the soonest upcoming exam.
    var primary: Summary? { primaryTracker?.summary }
    var primaryTracker: (tracker: Tracker, summary: Summary)? {
        if let picked, case .loaded(let summary) = states[picked.id], !pickLapsed(summary) { return (picked, summary) }
        let today = Calendar.current.startOfDay(for: Date())
        let loaded = trackers.compactMap { tracker -> (tracker: Tracker, summary: Summary)? in
            if case .loaded(let summary) = states[tracker.id] { return (tracker, summary) }
            return nil
        }
        // Soonest upcoming exam; then a tracker with no exam date in its sheet yet.
        return loaded.filter { ($0.summary.examDate ?? .distantPast) >= today }.min { $0.summary.examDate! < $1.summary.examDate! }
            ?? loaded.first { $0.summary.examDate == nil }
    }

    // MARK: Bridge setup

    /// The Apps Script to paste into script.google.com, with a fresh secret.
    func setupScript() -> String {
        let secret = BridgeStore.read("secret") ?? {
            let value = (0..<32).map { _ in "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789".randomElement()! }.map(String.init).joined()
            BridgeStore.write("secret", value)
            return value
        }()
        return Self.script.replacingOccurrences(of: "__SECRET__", with: secret)
    }
    func connect(url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("https://script.google.com/"), trimmed.hasSuffix("/exec") else { return "Paste the Web app URL ending in /exec." }
        guard BridgeStore.read("secret") != nil else { return "Copy the script first so it has your secret." }
        BridgeStore.write("url", trimmed)
        bridgeURL = trimmed
        refreshAll()
        return nil
    }
    func disconnect() { BridgeStore.delete("url"); bridgeURL = nil; states.removeAll() }

    // MARK: Trackers

    func add(link: String, label: String) -> Bool {
        guard Self.sheetID(in: link) != nil else { return false }
        let tracker = Tracker(link: link.trimmingCharacters(in: .whitespacesAndNewlines), label: label.trimmingCharacters(in: .whitespaces).isEmpty ? "PBL tracker" : label)
        trackers.insert(tracker, at: 0); save(); refresh(tracker)
        return true
    }
    func remove(_ tracker: Tracker) { trackers.removeAll { $0.id == tracker.id }; states[tracker.id] = nil; save() }
    func refreshAll() { trackers.forEach(refresh) }
    func open(_ tracker: Tracker) { if let url = URL(string: tracker.link) { NSWorkspace.shared.open(url) } }
    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(trackers), forKey: key) }

    /// Sample progress for video captures: the first readings checked off, in memory only.
    /// Refreshes and day records stop, so nothing reaches the sheet or settings.
    private(set) var demo = false
    func showDemo(done fraction: Double) {
        demo = true
        for tracker in trackers {
            guard case .loaded(var summary) = states[tracker.id] else { continue }
            let target = Int(Double(summary.pagesTotal) * fraction)
            var pages = 0
            for index in summary.items.indices {
                summary.items[index].done = pages < target
                if summary.items[index].done { pages += summary.items[index].pages }
            }
            states[tracker.id] = .loaded(summary)
        }
    }

    func refresh(_ tracker: Tracker) {
        guard !demo else { return }
        guard connected else { states[tracker.id] = .needsBridge; return }
        if case .loaded = states[tracker.id] {} else { states[tracker.id] = .loading }
        Task { await call(tracker, extra: []) }
    }
    /// Checks or unchecks a reading's Status box in the sheet; the view updates
    /// immediately and reconciles with the sheet's response.
    func toggle(_ tracker: Tracker, _ item: Item) {
        guard !demo else { return }
        guard case .loaded(var summary) = states[tracker.id], let index = summary.items.firstIndex(where: { $0.row == item.row }) else { return }
        // Toggle from the current state, not the view's possibly stale copy.
        let before = summary
        summary.items[index].done.toggle()
        summary.problem = nil
        let value = summary.items[index].done
        states[tracker.id] = .loaded(summary)
        Task { await call(tracker, extra: [.init(name: "action", value: "set"), .init(name: "row", value: "\(item.row)"), .init(name: "col", value: "\(item.statusColumn)"), .init(name: "value", value: value ? "true" : "false")], restoreOnFailure: before) }
    }

    /// Talks to the bridge with retries: Google's script service intermittently answers
    /// slowly or with an error page, so one bad response must not strand the tracker.
    /// The last good response is cached on disk and shown immediately on launch.
    private func call(_ tracker: Tracker, extra: [URLQueryItem], restoreOnFailure previous: Summary? = nil) async {
        guard let bridgeURL, let secret = BridgeStore.read("secret"), let id = Self.sheetID(in: tracker.link),
              var components = URLComponents(string: bridgeURL) else { states[tracker.id] = .needsBridge; return }
        components.queryItems = [.init(name: "secret", value: secret), .init(name: "id", value: id), .init(name: "gid", value: Self.gid(in: tracker.link) ?? "")] + extra
        guard let url = components.url else { return }
        let serial = (requestSerial[tracker.id] ?? 0) + 1
        requestSerial[tracker.id] = serial
        refreshing.insert(tracker.id)
        defer { if requestSerial[tracker.id] == serial { refreshing.remove(tracker.id) } }
        var lastProblem = "Couldn't reach Google."
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(Double(attempt) * 1.5)) }
            guard requestSerial[tracker.id] == serial else { return }
            guard let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 40)) else { continue }
            guard requestSerial[tracker.id] == serial else { return }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                lastProblem = status == 200 ? "The script didn't answer. Check that the deployment's access is set to \"Anyone\"." : "Google's script service had a hiccup (\(status))."
                continue
            }
            if let error = object["error"] as? String {
                // Configuration errors won't fix themselves by retrying.
                show(tracker, problem: error == "unauthorized" ? "The script's secret doesn't match. Copy the script again and redeploy." : error, restoring: previous)
                return
            }
            var summary = Self.summarize(values: object["values"] as? [[String]] ?? [], raw: object["raw"] as? [[Any]] ?? [])
            summary.title = object["title"] as? String ?? tracker.label
            states[tracker.id] = .loaded(summary)
            TrackerCache.save(data, for: tracker.id)
            return
        }
        show(tracker, problem: lastProblem, restoring: previous)
    }
    /// Keeps showing the last good data with a note, rather than replacing it with an error.
    private func show(_ tracker: Tracker, problem: String, restoring previous: Summary?) {
        if var summary = previous ?? { if case .loaded(let s) = states[tracker.id] { return s }; return nil }() {
            summary.problem = previous != nil ? "Couldn't update the sheet. Your check-off was undone; try again." : "Couldn't refresh (\(problem)) Showing data from \(summary.fetchedAt.formatted(date: .omitted, time: .shortened))."
            states[tracker.id] = .loaded(summary)
        } else {
            states[tracker.id] = .failed(problem)
        }
    }

    static func sheetID(in link: String) -> String? {
        guard let range = link.range(of: #"/spreadsheets/d/([A-Za-z0-9_-]{20,})"#, options: .regularExpression) else { return nil }
        return link[range].replacingOccurrences(of: "/spreadsheets/d/", with: "")
    }
    static func gid(in link: String) -> String? {
        link.range(of: #"gid=\d+"#, options: .regularExpression).map { String(link[$0].dropFirst(4)) }
    }

    /// Reads a reading tracker laid out as: a header row (Status | Book | Ch # |
    /// Chapter Title | Pages …), section rows such as "PBL GROUP ASSIGNED READINGS",
    /// and an "Exam Date" label with the date beside it. Columns are found by header
    /// name, so reordering columns in the sheet doesn't break it.
    static func summarize(values: [[String]], raw: [[Any]]) -> Summary {
        var summary = Summary()
        func text(_ r: Int, _ c: Int) -> String { r < values.count && c < values[r].count ? values[r][c].trimmingCharacters(in: .whitespacesAndNewlines) : "" }
        func bool(_ r: Int, _ c: Int) -> Bool? { r < raw.count && c < raw[r].count ? raw[r][c] as? Bool : nil }
        func date(_ r: Int, _ c: Int) -> Date? {
            guard r < raw.count, c < raw[r].count, let value = raw[r][c] as? String else { return nil }
            return ISO8601DateFormatter.fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        }
        let width = values.map(\.count).max() ?? 0

        // Exam date: the date next to an "Exam Date" label.
        outer: for r in values.indices {
            for c in 0..<width where text(r, c).lowercased().contains("exam date") || text(r, c).lowercased() == "exam" {
                for offset in 1...2 { if let found = date(r, c + offset) { summary.examDate = found; break outer } }
                if let found = date(r + 1, c) { summary.examDate = found; break outer }
            }
        }

        // Header row: contains "Status", or is the last multi-label row above the first checkbox.
        let firstCheck = raw.indices.first { r in (0..<width).contains { bool(r, $0) != nil } }
        let header = values.indices.first { r in (0..<width).contains { text(r, $0).lowercased() == "status" } }
            ?? firstCheck.flatMap { first in (0..<first).reversed().first { r in (0..<width).filter { !text(r, $0).isEmpty }.count >= 3 } }
        func column(_ matches: (String) -> Bool) -> Int? {
            guard let header else { return nil }
            return (0..<width).first { matches(text(header, $0).lowercased()) }
        }
        let status = column { $0 == "status" || $0 == "done" || $0 == "read" }
        let book = column { $0 == "book" || $0 == "subject" || $0 == "source" }
        let chapter = column { $0.hasPrefix("ch") && !$0.contains("title") && $0.count <= 9 }
        let title = column { $0.contains("title") || $0 == "chapter" || $0 == "reading" || $0 == "topic" }
        let pages = column { $0 == "pages" || $0 == "pgs" || $0.hasPrefix("page") }

        // A section row is a single stretch of text with no checkbox, e.g. "PRE-ASSIGNED READINGS".
        func sectionName(_ r: Int) -> String? {
            let filled = (0..<width).filter { !text(r, $0).isEmpty }
            guard filled.count == 1, !(0..<width).contains(where: { bool(r, $0) != nil }) else { return nil }
            // Title-case, but keep short acronyms like PBL and OMM.
            return text(r, filled[0]).split(separator: " ").map { $0.count <= 3 ? String($0) : $0.capitalized }.joined(separator: " ")
        }
        var section: String? = header.flatMap { h in h > 0 ? sectionName(h - 1) : nil }
        let start = (header ?? -1) + 1
        for r in start..<values.count {
            if let name = sectionName(r) { section = name; continue }
            let statusColumn = status.flatMap { bool(r, $0) != nil ? $0 : nil } ?? (0..<width).first { bool(r, $0) != nil }
            guard let statusColumn, let done = bool(r, statusColumn) else { continue }
            let titleText = title.map { text(r, $0) } ?? ""
            let fallback = (0..<width).first { c in
                let value = text(r, c)
                return !value.isEmpty && bool(r, c) == nil && value.uppercased() != "FALSE" && value.uppercased() != "TRUE"
            }.map { text(r, $0) } ?? ""
            let label = titleText.isEmpty ? fallback : titleText
            guard !label.isEmpty else { continue } // empty template rows
            let pageCount = pages.flatMap { Int(text(r, $0).filter(\.isNumber)) } ?? 0
            summary.items.append(Item(row: r + 1, statusColumn: statusColumn + 1, book: book.map { text(r, $0) } ?? "", chapter: chapter.map { text(r, $0) } ?? "",
                                      title: label, pages: pageCount, done: done, section: section))
        }
        summary.preview = values.prefix(6).map { Array($0.prefix(4)) }.filter { $0.contains { !$0.isEmpty } }
        return summary
    }

    static let script = """
    // Attending tracker bridge. Lets Attending read your tracker spreadsheets and tick
    // their checkboxes. It runs as you, only answers requests carrying the secret
    // below, only opens spreadsheets whose names contain "Tracker" or "PBL", and only
    // ever changes checkbox cells.
    //
    // Deploy: Deploy > New deployment > Select type: Web app
    //         Execute as: Me    Who has access: Anyone
    // Then copy the Web app URL (ending in /exec) into Attending.
    const SECRET = '__SECRET__';

    function doGet(e) {
      const p = e.parameter || {};
      if (p.secret !== SECRET) return json({ error: 'unauthorized' });
      let book;
      try { book = SpreadsheetApp.openById(p.id); } catch (err) { return json({ error: 'Spreadsheet not found or not shared with this Google account.' }); }
      if (!/tracker|pbl/i.test(book.getName())) return json({ error: 'Only spreadsheets with "Tracker" or "PBL" in the name are available to Attending.' });
      const sheet = p.gid ? book.getSheets().find(s => String(s.getSheetId()) === String(p.gid)) : book.getSheets()[0];
      if (!sheet) return json({ error: 'That tab no longer exists.' });
      if (p.action === 'set') {
        const cell = sheet.getRange(Number(p.row), Number(p.col));
        if (typeof cell.getValue() !== 'boolean') return json({ error: 'Only checkbox cells can be changed from Attending.' });
        cell.setValue(p.value === 'true');
        SpreadsheetApp.flush();
      }
      const range = sheet.getDataRange();
      const raw = range.getValues().map(row => row.map(v => typeof v === 'boolean' ? v : (v instanceof Date ? v.toISOString() : null)));
      return json({ title: book.getName(), tab: sheet.getName(), values: range.getDisplayValues(), raw: raw });
    }

    function json(object) {
      return ContentService.createTextOutput(JSON.stringify(object)).setMimeType(ContentService.MimeType.JSON);
    }
    """

    // MARK: Drive suggestions

    struct DriveSheet: Identifiable, Equatable { var id: String { link }; var name: String; var link: String; var modified: Date }
    /// Tracker spreadsheets found in Google Drive for desktop, newest first, minus ones already added.
    @Published private var driveSheets: [DriveSheet] = []
    var driveSuggestions: [DriveSheet] {
        let added = Set(trackers.compactMap { Self.sheetID(in: $0.link) })
        return driveSheets.filter { !added.contains(Self.sheetID(in: $0.link) ?? "") }
    }
    private var lastScan = Date.distantPast
    /// Walks Drive off the main thread (Drive folders can be slow to enumerate).
    func scanDrive() {
        guard let root = GoogleDrive.folder, Date().timeIntervalSince(lastScan) > 300 else { return }
        lastScan = Date()
        Task.detached(priority: .utility) {
            let found = SheetTracker.findSheets(in: root)
            await MainActor.run { [weak self] in self?.driveSheets = found }
        }
    }
    nonisolated private static func findSheets(in root: URL) -> [DriveSheet] {
        var found: [DriveSheet] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = enumerator?.nextObject() as? URL {
            // My Drive and one folder level down: where trackers live, without walking everything.
            if enumerator!.level >= 2, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator!.skipDescendants() }
            if enumerator!.level > 2 { continue }
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "gsheet", name.localizedCaseInsensitiveContains("tracker") || name.localizedCaseInsensitiveContains("PBL"),
                  let data = try? Data(contentsOf: url), data.count < 4096,
                  let stub = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = stub["doc_id"] as? String else { continue }
            found.append(DriveSheet(name: name, link: "https://docs.google.com/spreadsheets/d/\(id)/edit",
                                    modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast))
        }
        return found.sorted { $0.modified > $1.modified }
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// Sheets connector settings (web app URL and shared secret) in a private file
/// (0600) in Attending's data folder, cached in memory. The login keychain is not
/// used: it ties items to each build's exact signature, so a self-signed app that
/// updates often got a password prompt on every read.
enum BridgeStore {
    nonisolated(unsafe) private static var cache: [String: String]?
    private static var file: URL { AppPaths.directory.appendingPathComponent("sheets-bridge.json") }

    static func read(_ key: String) -> String? { load()[key] }
    static func write(_ key: String, _ value: String) { var values = load(); values[key] = value; save(values) }
    static func delete(_ key: String) { var values = load(); values[key] = nil; save(values) }

    private static func load() -> [String: String] {
        if let cache { return cache }
        let values = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        cache = values
        return values
    }
    private static func save(_ values: [String: String]) {
        cache = values
        try? FileManager.default.createDirectory(at: AppPaths.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? data.write(to: file, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// Last good bridge response per tracker (0600, in the data folder).
enum TrackerCache {
    private static var folder: URL { AppPaths.directory.appendingPathComponent("trackers", isDirectory: true) }
    static func save(_ data: Data, for id: UUID) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent("\(id.uuidString).json")
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func load(for id: UUID) -> (Data, Date)? {
        let url = folder.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (data, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date())
    }
}
