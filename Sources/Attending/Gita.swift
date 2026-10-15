import AppKit
import AttendingCore
import SwiftUI

/// An offline daily reflection. Only opening a verse's source uses the network.
@MainActor final class GitaReflections: ObservableObject {
    @Published private(set) var quote = GitaQuotes.daily(on: Date())
    @Published private(set) var isToday = true
    private var index = GitaQuotes.index(on: Date())
    private var midnight: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var running = false

    func start() {
        guard !running else { return }
        running = true
        for name in [NSNotification.Name.NSCalendarDayChanged, NSNotification.Name.NSSystemTimeZoneDidChange, NSNotification.Name.NSSystemClockDidChange] {
            observe(NotificationCenter.default, name)
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification)
        today()
    }

    func stop() {
        running = false
        midnight?.cancel(); midnight = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    func today() {
        index = GitaQuotes.index(on: Date())
        quote = GitaQuotes.all[index]
        isToday = true
        scheduleMidnight()
    }

    func next() {
        index = (index + 1) % GitaQuotes.all.count
        quote = GitaQuotes.all[index]
        isToday = index == GitaQuotes.index(on: Date())
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(quote.copyText, forType: .string)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.today() }
        }
        observers.append((center, token))
    }

    private func scheduleMidnight() {
        midnight?.cancel()
        guard running, let next = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) else { return }
        midnight = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.today()
        }
    }
}

struct GitaCard: View {
    @ObservedObject var gita: GitaReflections

    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "book.closed.fill").foregroundStyle(Theme.attention)
                    SectionLabel(text: "Bhagavad Gita")
                    Spacer(minLength: 0)
                }
                Text(gita.isToday ? "Today's reflection" : "Reflection")
                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                Text(gita.quote.text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text("\(gita.quote.reference) · Paraphrase")
                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    IconButton(symbol: "doc.on.doc", help: "Copy reflection with its reference", size: 22) { gita.copy() }
                    Link(destination: gita.quote.sourceURL) {
                        Image(systemName: "arrow.up.right.square").font(.system(size: 12))
                    }.help("Read the verse and its context").foregroundStyle(Theme.secondary)
                    Spacer(minLength: 0)
                    if !gita.isToday {
                        Button("Today") { gita.today() }.buttonStyle(.plain)
                            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                    IconButton(symbol: "chevron.right", help: "Next reflection", size: 22) { gita.next() }
                }
            }
        }
    }
}

struct GitaChip: View {
    @ObservedObject var gita: GitaReflections
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            Label("Gita \(gita.quote.id)", systemImage: "book.closed.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.attention).lineLimit(1).fixedSize()
        }
        .buttonStyle(.plain)
        .help("Open the Bhagavad Gita reflection")
    }
}
