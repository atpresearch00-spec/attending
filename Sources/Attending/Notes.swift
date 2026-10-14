import AppKit
import SwiftUI
import AttendingCore

// MARK: - Quick notes

/// A scratchpad in the notch for the question to ask in PBL or a page number. Saved as
/// you type, to a plain text file in Attending's folder.
struct NotesView: View {
    @ObservedObject var model: AppModel
    @State private var text = NotesView.load()
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var focused: Bool
    static var url: URL { AppPaths.directory.appendingPathComponent("notes.txt") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ShelfSwitcher(model: model)
                Text("Saved as you type.").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                Spacer()
                if !text.isEmpty {
                    PillButton(title: "Copy", symbol: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                    PillButton(title: "Clear", symbol: nil) { text = "" }
                }
            }
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("A question for PBL, a page number, a thought for later…").font(.system(size: 13)).foregroundStyle(Theme.tertiary).padding(15).allowsHitTesting(false)
                    }
                }
        }
        .onAppear { focused = true }
        .onChange(of: text) { _, value in
            saveTask?.cancel()
            saveTask = Task { try? await Task.sleep(for: .milliseconds(400)); guard !Task.isCancelled else { return }; NotesView.save(value) }
        }
        .onDisappear { NotesView.save(text) }
    }
    static func load() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    static func save(_ text: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? text.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - Quick lookup

/// Look a term up in a medical source from the Study tab. Return uses the last source.
struct LookupBar: View {
    enum Source: String, CaseIterable {
        case amboss, pubmed, uptodate
        var title: String { switch self { case .amboss: "AMBOSS"; case .pubmed: "PubMed"; case .uptodate: "UpToDate" } }
        func url(_ term: String) -> URL? {
            let q = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
            switch self {
            case .amboss: return URL(string: "https://next.amboss.com/us/search?q=\(q)&v=overview")
            case .pubmed: return URL(string: "https://pubmed.ncbi.nlm.nih.gov/?term=\(q)")
            case .uptodate: return URL(string: "https://www.uptodate.com/contents/search?search=\(q)")
            }
        }
    }
    @State private var term = ""
    @AppStorage("lookupSource") private var last = Source.amboss.rawValue
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.tertiary)
            TextField("Look up a term…", text: $term).textFieldStyle(.plain).font(.system(size: 13))
                .onSubmit { open(Source(rawValue: last) ?? .amboss) }
            ForEach(Source.allCases, id: \.self) { source in
                Button(source.title) { open(source) }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8).frame(height: 22)
                    .foregroundStyle(source.rawValue == last ? Theme.primary : Theme.secondary)
                    .background(Capsule().fill(source.rawValue == last ? Theme.raised : .clear))
                    .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 12).frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
    }
    private func open(_ source: Source) {
        let query = term.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let url = source.url(query) else { return }
        last = source.rawValue
        NSWorkspace.shared.open(url)
        term = ""
    }
}
