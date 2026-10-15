import Foundation

/// Excerpts from Edwin Arnold's public-domain translation, The Song Celestial.
/// Wording, punctuation and poetic line breaks follow the linked edition.
public struct GitaQuote: Identifiable, Equatable, Sendable {
    public let chapter: Int
    public let verse: String
    public let text: String
    public var id: String { "\(chapter).\(verse)" }
    public var reference: String { "Bhagavad Gita \(id)" }
    public static let translation = "Edwin Arnold, The Song Celestial"
    public var sourceURL: URL {
        let anchor = String(format: "chap%02d", chapter)
        return URL(string: "https://www.gutenberg.org/cache/epub/2388/pg2388-images.html#\(anchor)")!
    }
    public var copyText: String { "\(text)\n— \(reference) (excerpt)\nTranslated by \(Self.translation)" }
}

public enum GitaQuotes {
    public static let all: [GitaQuote] = [
        .init(chapter: 2, verse: "47", text: "Let right deeds be\nThy motive, not the fruit which comes from them."),
        .init(chapter: 2, verse: "48", text: "Make thine acts\nThy piety, casting all self aside,\nContemning gain and merit; equable\nIn good or evil: equability\nIs Yog, is piety!"),
        .init(chapter: 4, verse: "39", text: "Believing, he receives it when the soul\nMasters itself, and cleaves to Truth, and comes--\nPossessing knowledge--to the higher peace,\nThe uttermost repose."),
        .init(chapter: 6, verse: "5", text: "Let each man raise\nThe Self by Soul, not trample down his Self,\nSince Soul that is Self's friend may grow Self's foe."),
        .init(chapter: 6, verse: "17", text: "Nay, Arjuna! call\nThat the true piety which most removes\nEarth-aches and ills, where one is moderate\nIn eating and in resting, and in sport;\nMeasured in wish and act; sleeping betimes,\nWaking betimes for duty."),
        .init(chapter: 6, verse: "26", text: "But, as often as the heart\nBreaks--wild and wavering--from control, so oft\nLet him re-curb it, let him rein it back\nTo the soul's governance;"),
        .init(chapter: 12, verse: "13", text: "Who hateth nought\nOf all which lives, living himself benign,\nCompassionate, from arrogance exempt,\nExempt from love of self,"),
        .init(chapter: 17, verse: "15", text: "Words causing no man woe, words ever true,\nGentle and pleasing words, and those ye say\nIn murmured reading of a Sacred Writ,--\nThese make the true religiousness of Speech.")
    ]

    /// Civil days, not elapsed 24-hour periods: the reflection changes at local midnight,
    /// including on daylight-saving days. The same date selects the same reflection.
    public static func index(on date: Date, calendar: Calendar = .current) -> Int {
        var civil = Calendar(identifier: .gregorian)
        civil.timeZone = calendar.timeZone
        let epoch = civil.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let days = civil.dateComponents([.day], from: epoch, to: civil.startOfDay(for: date)).day ?? 0
        return ((days % all.count) + all.count) % all.count
    }

    public static func daily(on date: Date, calendar: Calendar = .current) -> GitaQuote {
        all[index(on: date, calendar: calendar)]
    }
}
