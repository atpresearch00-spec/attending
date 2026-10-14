import AppKit
import SwiftUI
import AttendingCore

/// A small per-day log behind the weekly recap: focus minutes, pages read and questions.
/// Anki reviews come from Anki. Kept for about two months.
@MainActor final class ActivityLog: ObservableObject {
    struct Week: Equatable {
        var focusMinutes = 0, pages = 0, questions = 0, reviews = 0
        /// Screen time in minutes.
        var studying = 0, ai = 0, distractions = 0
        var isEmpty: Bool { focusMinutes + pages + questions + reviews + studying == 0 }
    }
    @Published private(set) var days: [String: [String: Int]] = UserDefaults.standard.dictionary(forKey: "activityLog") as? [String: [String: Int]] ?? [:]
    @Published var sundayRecap = UserDefaults.standard.object(forKey: "weeklyRecap") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sundayRecap, forKey: "weeklyRecap"); schedule() }
    }
    var onRecap: (() -> Void)?
    private var timer: Task<Void, Never>?

    /// Sample days for video captures; shown in memory only, never saved.
    func showDemo(_ sample: [String: [String: Int]]) { demo = true; days = sample }
    private var demo = false
    func add(_ key: String, _ amount: Int) {
        guard amount != 0 else { return }
        let today = Self.dayKey(Date())
        days[today, default: [:]][key, default: 0] = max(0, days[today, default: [:]][key, default: 0] + amount)
        save()
    }
    /// For running totals that only grow during the day (pages read today).
    func record(_ key: String, _ value: Int) {
        let today = Self.dayKey(Date())
        guard value > days[today, default: [:]][key, default: 0] else { return }
        days[today, default: [:]][key] = value
        save()
    }
    func total(_ key: String, days count: Int = 7) -> Int {
        (0..<count).reduce(0) { sum, back in
            sum + (days[Self.dayKey(Calendar.current.date(byAdding: .day, value: -back, to: Date())!)]?[key] ?? 0)
        }
    }
    private func save() {
        guard !demo else { return }
        let cutoff = Self.dayKey(Date().addingTimeInterval(-60 * 86400))
        days = days.filter { $0.key >= cutoff }
        UserDefaults.standard.set(days, forKey: "activityLog")
    }
    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Sunday at 7 PM, once a week.
    func schedule() {
        timer?.cancel()
        guard sundayRecap, let next = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 19, minute: 0, weekday: 1), matchingPolicy: .nextTime) else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            onRecap?()
            schedule()
        }
    }
}

extension AppModel {
    var week: ActivityLog.Week {
        .init(focusMinutes: activity.total("focus"), pages: activity.total("pages"), questions: activity.total("questions"),
              reviews: anki.stats?.week.reduce(0, +) ?? 0,
              studying: activity.total(ScreenTime.Category.study.logKey) / 60, ai: activity.total(ScreenTime.Category.ai.logKey) / 60,
              distractions: activity.total(ScreenTime.Category.distraction.logKey) / 60)
    }
    /// Saves the week as a card image, on the Shelf and the clipboard.
    func shareWeek() {
        let renderer = ImageRenderer(content: RecapShareCard(week: week))
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Attending", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Week of \(Date().formatted(.iso8601.year().month().day())).png")
        guard (try? png.write(to: file)) != nil else { return }
        shelf.add([file])
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        raise(NotchAlert(title: "Your week is ready to share", subtitle: "On your Shelf and clipboard · Pictures › Attending", symbol: "photo.fill", color: Theme.done, target: .shelf, image: image, fileURL: file), sound: "Glass")
    }
}

/// This week at the bottom of the Study tab.
struct WeekCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var activity: ActivityLog
    var body: some View {
        let week = model.week
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel(text: "This week")
                    Spacer()
                    if !week.isEmpty { IconButton(symbol: "square.and.arrow.up", help: "Share your week", size: 20) { model.shareWeek() } }
                }
                if model.screenTime.enabled {
                    let today = { (category: ScreenTime.Category) in activity.total(category.logKey, days: 1) / 60 }
                    HStack(spacing: 10) {
                        Text("Today").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                        screen(today(.study), ScreenTime.Category.study, Theme.done)
                        screen(today(.ai), ScreenTime.Category.ai, Theme.working)
                        screen(today(.distraction), ScreenTime.Category.distraction, Theme.attention)
                        Spacer(minLength: 0)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    stat(Self.hours(week.focusMinutes), "focused")
                    if model.screenTime.enabled { stat(Self.hours(week.studying), "studying") }
                    stat(week.pages.formatted(), "pages read")
                    if week.questions > 0 { stat(week.questions.formatted(), "questions") }
                    stat(week.reviews.formatted(), "Anki reviews")
                    Spacer(minLength: 0)
                }
            }
        }
    }
    private func screen(_ minutes: Int, _ category: ScreenTime.Category, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text("\(Self.hours(minutes)) \(category == .ai ? "AI" : category.title.lowercased())").font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
    }
    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
        }
    }
    static func hours(_ minutes: Int) -> String { minutes < 60 ? "\(minutes)m" : minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m" }
}

struct RecapShareCard: View {
    let week: ActivityLog.Week
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "stethoscope").font(.system(size: 34, weight: .semibold))
                Text("Attending").font(.system(size: 34, weight: .semibold))
                Spacer()
            }.foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text("My week").font(.system(size: 60, weight: .semibold)).foregroundStyle(.white)
            Text(weekRange).font(.system(size: 34)).foregroundStyle(.white.opacity(0.5)).padding(.bottom, 60)
            VStack(alignment: .leading, spacing: 34) {
                row(WeekCard.hours(week.focusMinutes), "focused")
                if week.studying > 0 { row(WeekCard.hours(week.studying), "studying") }
                row(week.pages.formatted(), "pages read")
                if week.questions > 0 { row(week.questions.formatted(), "questions") }
                row(week.reviews.formatted(), "Anki reviews")
            }
            Spacer()
        }
        .padding(80)
        .frame(width: 1080, height: 1350)
        .background(LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.1), Color(red: 0.02, green: 0.02, blue: 0.03)], startPoint: .top, endPoint: .bottom))
    }
    private var weekRange: String {
        let start = Calendar.current.date(byAdding: .day, value: -6, to: Date())!
        return "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(Date().formatted(.dateTime.month(.abbreviated).day()))"
    }
    private func row(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(value).font(.system(size: 96, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
            Text(label).font(.system(size: 40, weight: .medium)).foregroundStyle(.white.opacity(0.65))
        }
    }
}
