import Foundation

/// Short original English paraphrases, not verbatim quotations from a translation.
/// Each reflection links to its verse for the Sanskrit, translation and context.
public struct GitaQuote: Identifiable, Equatable, Sendable {
    public let chapter: Int
    public let verse: String
    public let text: String
    public var id: String { "\(chapter).\(verse)" }
    public var reference: String { "Bhagavad Gita \(id)" }
    public var sourceURL: URL {
        URL(string: "https://www.holy-bhagavad-gita.org/chapter/\(chapter)/verse/\(verse)/")!
    }
    public var copyText: String { "\(text)\n— \(reference) (paraphrase)" }
}

public enum GitaQuotes {
    public static let all: [GitaQuote] = [
        .init(chapter: 2, verse: "47", text: "Give yourself to the work before you, without claiming its fruits. Do not let attachment to results lead you into inaction."),
        .init(chapter: 2, verse: "48", text: "Do your work with a steady mind, releasing attachment to success and failure. This evenness is yoga."),
        .init(chapter: 4, verse: "39", text: "Faith, dedication and mastery of the senses open the way to wisdom. With that wisdom comes deep peace."),
        .init(chapter: 6, verse: "5", text: "Use your mind to lift yourself, not to bring yourself down. It can become your ally or your adversary."),
        .init(chapter: 6, verse: "17", text: "A balanced rhythm of food, recreation, effort and rest supports the practice of yoga and the easing of sorrow."),
        .init(chapter: 6, verse: "26", text: "Each time the restless mind strays, guide it back toward the Divine, returning patiently to your practice."),
        .init(chapter: 12, verse: "13-14", text: "Krishna cherishes the devotee who is compassionate, forgiving and free from hatred, steady in joy and sorrow, with mind and understanding offered to him."),
        .init(chapter: 17, verse: "15", text: "Discipline in speech means words that are honest, kind and helpful, without causing distress, together with regular study of sacred teachings.")
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
