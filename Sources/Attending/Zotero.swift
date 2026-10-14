import AppKit

/// Sends PDFs to Zotero through its local connector (the same one the browser extension
/// uses). Zotero files it in the collection you have selected and looks up the paper's
/// details by itself. Opens Zotero first if needed.
enum ZoteroImporter {
    static var installed: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.zotero.zotero") != nil }
    private static let base = URL(string: "http://127.0.0.1:23119/connector")!

    static func add(_ file: URL) async throws {
        guard installed else { throw failure("Zotero isn't installed.") }
        if !(await ping()) {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.zotero.zotero") {
                _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: { let c = NSWorkspace.OpenConfiguration(); c.activates = false; return c }())
            }
            var ready = false
            for _ in 0..<30 where !ready { try? await Task.sleep(for: .milliseconds(500)); ready = await ping() }
            guard ready else { throw failure("Zotero didn't start. Open it and try again.") }
        }
        let data = try Data(contentsOf: file)
        guard data.count < 300_000_000 else { throw failure("That file is too large for Zotero's importer.") }
        var request = URLRequest(url: base.appendingPathComponent("saveStandaloneAttachment"), timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        request.setValue("3", forHTTPHeaderField: "X-Zotero-Connector-API-Version")
        request.setValue("Attending", forHTTPHeaderField: "User-Agent")
        let metadata: [String: String] = ["sessionID": UUID().uuidString, "title": file.deletingPathExtension().lastPathComponent, "url": file.absoluteString]
        request.setValue(String(data: try JSONSerialization.data(withJSONObject: metadata), encoding: .utf8), forHTTPHeaderField: "X-Metadata")
        request.httpBody = data
        let (_, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 201: return
        case 200: throw failure("The selected Zotero library can't be edited. Pick My Library or a collection you own.")
        default: throw failure("Zotero didn't accept the file.")
        }
    }
    private static func ping() async -> Bool {
        var request = URLRequest(url: base.appendingPathComponent("ping"), timeoutInterval: 2)
        request.httpMethod = "GET"
        return ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)?.statusCode == 200
    }
    private static func failure(_ message: String) -> NSError { NSError(domain: "Attending", code: 2, userInfo: [NSLocalizedDescriptionKey: message]) }
}
