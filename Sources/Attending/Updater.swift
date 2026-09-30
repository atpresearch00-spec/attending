import AppKit
import CryptoKit
import Foundation

/// Keeps downloaded copies of Attending up to date from GitHub Releases.
///
/// It checks about once a day, and says so in the notch when a newer version is out. On
/// "Update" it downloads the release zip, verifies its Ed25519 signature against the key
/// built in here (scripts/sign-release.swift makes the signature), checks the new app's
/// identity and code signature, swaps it in (the old copy goes to the Trash) and relaunches.
///
/// Only public builds update themselves. A build with a custom bundle ID
/// (scripts/local.env) is someone's own copy, so it's left alone.
@MainActor final class Updater: ObservableObject {
    static let repository = "med-abdullah/attending"
    /// Donation page, shown in Settings when set.
    static let supportURL: URL? = URL(string: "https://buymeacoffee.com/med.abdullah")
    static let publicBundleID = "app.attending.Attending"
    /// Public half of the release signing key.
    private static let publicKey = "uDIEutxtqRlvxNCOkyz7qPEhfE1u2+isgdWr4R7e+5I="

    struct Release: Equatable {
        var version: String
        var notes: String
        var zip: URL
        var signature: URL
        var page: URL
    }
    enum State: Equatable { case idle, checking, upToDate, available, downloading, installing, failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var release: Release?
    @Published var automatic = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automatic, forKey: "autoUpdate"); schedule() }
    }
    var onAvailable: ((Release) -> Void)?
    private var timer: Timer?

    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// Only public builds update themselves.
    var enabled: Bool { Bundle.main.bundleIdentifier == Self.publicBundleID }

    func start() { schedule() }

    private func schedule() {
        timer?.invalidate(); timer = nil
        guard enabled, automatic else { return }
        let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        if Date().timeIntervalSince(last) > 20 * 3600 { Task { await check() } }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
    }

    // MARK: Checking

    func check(userInitiated: Bool = false) async {
        guard enabled, state != .downloading, state != .installing else { return }
        state = .checking
        defer { UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck") }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Attending/\(current)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]] else { throw UpdateError.message("Couldn't read the latest release.") }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            func asset(_ suffix: String) -> URL? {
                assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true }.flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
            }
            guard Self.isNewer(version, than: current) else { release = nil; state = .upToDate; return }
            guard let zip = asset(".zip"), let signature = asset(".zip.sig") else { throw UpdateError.message("The new release has no signed download yet.") }
            let found = Release(version: version, notes: json["body"] as? String ?? "", zip: zip, signature: signature,
                                page: (json["html_url"] as? String).flatMap(URL.init(string:)) ?? URL(string: "https://github.com/\(Self.repository)/releases")!)
            let isNew = release?.version != found.version
            release = found
            state = .available
            if isNew || userInitiated { onAvailable?(found) }
        } catch {
            state = userInitiated ? .failed((error as? UpdateError)?.text ?? "No connection to GitHub.") : .idle
        }
    }

    /// Compares dotted versions numerically: 1.10.0 > 1.9.2.
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }, b = installed.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Installing

    func install() {
        guard let release, enabled else { return }
        state = .downloading
        Task {
            do {
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("attending-update-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let zip = work.appendingPathComponent("Attending.zip")
                let (downloaded, _) = try await URLSession.shared.download(from: release.zip)
                try FileManager.default.moveItem(at: downloaded, to: zip)
                let (signatureData, _) = try await URLSession.shared.data(from: release.signature)
                // The download must carry the release key's signature, or nothing is installed.
                guard let key = Data(base64Encoded: Self.publicKey).flatMap({ try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }),
                      let signature = Data(base64Encoded: String(decoding: signatureData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
                      key.isValidSignature(signature, for: try Data(contentsOf: zip)) else {
                    throw UpdateError.message("The download's signature didn't match, so it wasn't installed.")
                }
                state = .installing
                try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
                let fresh = work.appendingPathComponent("Attending.app")
                guard Bundle(url: fresh)?.bundleIdentifier == Self.publicBundleID else { throw UpdateError.message("The download wasn't Attending.") }
                try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", fresh.path])
                try replaceAndRelaunch(with: fresh)
            } catch {
                state = .failed((error as? UpdateError)?.text ?? error.localizedDescription)
            }
        }
    }

    /// Moves the running copy to the Trash, puts the new one in its place, and relaunches
    /// once this process has quit (the new copy won't start while this one runs).
    private func replaceAndRelaunch(with fresh: URL) throws {
        let installed = Bundle.main.bundleURL
        try FileManager.default.trashItem(at: installed, resultingItemURL: nil)
        do { try FileManager.default.moveItem(at: fresh, to: installed) } catch {
            throw UpdateError.message("Couldn't replace Attending in \(installed.deletingLastPathComponent().path). The old copy is in the Trash.")
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", installed.path]
        try relaunch.run()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.terminationHandler = { finished in
                if finished.terminationStatus == 0 { continuation.resume() } else { continuation.resume(throwing: UpdateError.message("The update couldn't be unpacked or verified.")) }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    enum UpdateError: Error { case message(String); var text: String { if case .message(let text) = self { return text }; return "" } }
}
