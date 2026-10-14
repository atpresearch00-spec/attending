import AppKit
import SwiftUI

/// How many people have downloaded Attending, from the public GitHub Releases. Only the
/// maker's own build (any bundle ID other than the public one) tracks this.
///
/// New installs are the DMG downloads (the zip before there was a DMG). The in-app
/// updater fetches each release's .sig once per update, so .sig downloads after the first
/// release count updates; the first release's are people who clicked the wrong file.
@MainActor final class DownloadStats: ObservableObject {
    struct Release: Identifiable, Equatable {
        var id: String { tag }
        var tag: String
        var published: Date
        var installs: Int
        var updates: Int
        var wrongFile: Int
    }

    @Published private(set) var releases: [Release] = []
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var failed = false
    /// Total installs by day (yyyy-MM-dd), kept for the sparkline and "today".
    @Published private(set) var history: [String: Int] = UserDefaults.standard.dictionary(forKey: "downloadHistory") as? [String: Int] ?? [:]
    var onMilestone: ((Int) -> Void)?
    private var timer: Timer?

    static let milestones = [10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 25000, 50000, 100000]
    var enabled: Bool { Bundle.main.bundleIdentifier != Updater.publicBundleID }
    var installs: Int { releases.reduce(0) { $0 + $1.installs } }
    var updates: Int { releases.reduce(0) { $0 + $1.updates } }
    var today: Int {
        let yesterday = Self.dayKey(Calendar.current.date(byAdding: .day, value: -1, to: Date())!)
        guard let before = history[yesterday] ?? history.filter({ $0.key < Self.dayKey(Date()) }).max(by: { $0.key < $1.key })?.value else { return 0 }
        return max(0, installs - before)
    }
    /// The last two weeks of totals, oldest first.
    var trend: [Double] {
        (0..<14).reversed().compactMap { back in
            history[Self.dayKey(Calendar.current.date(byAdding: .day, value: -back, to: Date())!)].map(Double.init)
        }
    }
    var pageURL: URL { URL(string: "https://github.com/\(Updater.repository)/releases")! }

    func start() {
        guard enabled, timer == nil else { return }
        Task { await refresh() }
        let timer = Timer(timeInterval: 3 * 3600, repeats: true) { [weak self] _ in Task { @MainActor in await self?.refresh() } }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() async {
        guard enabled else { return }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Updater.repository)/releases?per_page=100")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Attending", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { failed = true; return }
        failed = false
        releases = Self.parse(list)
        fetchedAt = Date()
        record()
    }

    static func parse(_ list: [[String: Any]]) -> [Release] {
        let iso = ISO8601DateFormatter()
        let parsed: [Release] = list.compactMap { item in
            guard let tag = item["tag_name"] as? String, item["draft"] as? Bool != true else { return nil }
            let assets = item["assets"] as? [[String: Any]] ?? []
            func count(_ suffix: String) -> Int {
                assets.filter { ($0["name"] as? String)?.hasSuffix(suffix) == true }.reduce(0) { $0 + ($1["download_count"] as? Int ?? 0) }
            }
            let dmg = count(".dmg"), zip = count(".zip"), sig = count(".zip.sig")
            let hasDMG = assets.contains { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
            return Release(tag: tag, published: (item["published_at"] as? String).flatMap(iso.date(from:)) ?? .distantPast,
                           installs: hasDMG ? dmg : zip, updates: sig, wrongFile: 0)
        }.sorted { $0.published > $1.published }
        // The first release had nothing to update from: its .sig downloads were people.
        guard var first = parsed.last else { return parsed }
        first.wrongFile = first.updates; first.updates = 0
        return Array(parsed.dropLast()) + [first]
    }

    /// Saves today's total and celebrates a newly passed milestone.
    private func record() {
        let total = installs
        history[Self.dayKey(Date())] = total
        let cutoff = Self.dayKey(Calendar.current.date(byAdding: .day, value: -90, to: Date())!)
        history = history.filter { $0.key >= cutoff }
        UserDefaults.standard.set(history, forKey: "downloadHistory")
        let celebrated = UserDefaults.standard.integer(forKey: "downloadMilestone")
        if let reached = Self.milestones.last(where: { $0 <= total }), reached > celebrated {
            UserDefaults.standard.set(reached, forKey: "downloadMilestone")
            // The first fetch only sets the baseline, so an existing count isn't announced.
            if celebrated > 0 || history.count > 1 { onMilestone?(reached) }
        }
    }
    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// Settings › Downloads, in the maker's build.
struct DownloadsSection: View {
    @ObservedObject var stats: DownloadStats
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(stats.installs.formatted()).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
            VStack(alignment: .leading, spacing: 1) {
                Text("downloads").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                if stats.today > 0 { Text("+\(stats.today) today").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.done) }
            }
            Spacer()
            if stats.trend.count > 1 { Sparkline(values: stats.trend).frame(width: 90, height: 24) }
            IconButton(symbol: "arrow.clockwise", help: "Refresh", size: 20) { Task { await stats.refresh() } }
        }
        ForEach(stats.releases) { release in
            HStack(spacing: 8) {
                Text(release.tag).font(.system(size: 12, weight: .semibold))
                Text(release.published, format: .dateTime.month(.abbreviated).day()).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                Spacer()
                Text("\(release.installs) installs").font(.system(size: 11)).monospacedDigit()
                if release.updates > 0 { Text("· \(release.updates) updates").font(.system(size: 11)).foregroundStyle(Theme.secondary).monospacedDigit() }
                if release.wrongFile > 0 { Text("· \(release.wrongFile) took the .sig").font(.system(size: 11)).foregroundStyle(Theme.attention).monospacedDigit() }
            }
        }
        HStack {
            Text(stats.failed ? "Couldn't reach GitHub." : stats.fetchedAt.map { "Updated \($0.formatted(.relative(presentation: .named)))" } ?? "Loading…")
                .font(.system(size: 11)).foregroundStyle(stats.failed ? Theme.attention : Theme.tertiary)
            Spacer()
            Link("Releases on GitHub", destination: stats.pageURL).font(.system(size: 11))
        }
        Text("Installs count DMG downloads (zip before there was a DMG). Updates are in-app updates. Only your own build shows this, and the notch drops down at 10, 25, 50, 100 and up.")
            .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
    }
}
