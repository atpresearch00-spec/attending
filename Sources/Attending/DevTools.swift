import AppKit
import SwiftUI
import AttendingCore
import WebKit

/// Command-line development aids. Each flag runs a self-check or renders images,
/// prints what it found (never secrets) and quits; normal launches skip all of this.
///
///   --expanded             open the full panel at launch
///   --event-title TEXT     show TEXT instead of real calendar event titles
///   --snapshot DIR         render every panel state to PNG
///   --pet-previews DIR     render each notch mark in every mood
///   --render-icons DIR     write the 1024 px app icon
///   --mirror-test, --activity-test, --spectrum-test, --claude-test,
///   --spotify-test, --tracker-test, --smoke-test   print diagnostics for 10–30 s
extension AppDelegate {
    func runDevelopmentFlags() {
        if let index = CommandLine.arguments.firstIndex(of: "--event-title"), index + 1 < CommandLine.arguments.count {
            model.calendar.titleOverride = CommandLine.arguments[index + 1]
        }
    if CommandLine.arguments.contains("--expanded") { model.setMode(.expanded) }
    if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count { runSnapshots(URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)) }
    if CommandLine.arguments.contains("--mirror-test") {
        // Development aid: reports camera pipeline state without the UI.
        Task {
            model.holdOpen = true
            model.open(.mirror)
            for second in 1...8 {
                try? await Task.sleep(for: .seconds(1))
                print("MIRROR t=\(second) \(model.mirror.diagnostics)")
                // With --capture, one photo at 3 s; reports its size, not its contents.
                if second == 3 && CommandLine.arguments.contains("--capture") { model.mirror.zoom = 1.5; model.mirror.shutter() }
                if second == 6, let index = CommandLine.arguments.firstIndex(of: "--mirror-snapshot"), index + 1 < CommandLine.arguments.count {
                    snapshot(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                }
            }
            if let url = model.mirror.lastPhoto, let rep = NSImageRep(contentsOf: url) {
                let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                print("MIRROR photo \(url.lastPathComponent) \(rep.pixelsWide)x\(rep.pixelsHigh) \(bytes / 1024) KB")
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    if let index = CommandLine.arguments.firstIndex(of: "--pet-previews"), index + 1 < CommandLine.arguments.count {
        // Development aid: renders every notch mark in every mood, large, on black.
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = UserDefaults.standard.string(forKey: "pet")
        for pet in PetKind.allCases {
            UserDefaults.standard.set(pet.rawValue, forKey: "pet")
            let sheet = HStack(spacing: 28) {
                ForEach([SessionStatus.idle, .working, .attention, .completed], id: \.self) { mood in
                    VStack(spacing: 10) {
                        NotchMark(mood: mood, animate: false, height: 110)
                        Text(mood.title).font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .padding(30).background(Color.black)
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(pet.rawValue).png"))
            }
        }
        UserDefaults.standard.set(original, forKey: "pet")
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
    if CommandLine.arguments.contains("--activity-test") {
        // Development aid: prints live activities once a second.
        Task {
            for second in 1...28 {
                try? await Task.sleep(for: .seconds(1))
                let line = model.activities.activities.map { "\($0.name) \($0.kind) \($0.state) \($0.fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "-") \($0.sizeText)" }.joined(separator: " | ")
                print("ACT t=\(second) \(line.isEmpty ? "none" : line) alert=\(model.alert?.title ?? "-")")
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    if let index = CommandLine.arguments.firstIndex(of: "--render-icons"), index + 1 < CommandLine.arguments.count {
        // Development aid: writes the 1024 px app icon (AppIcon.png).
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let renderer = ImageRenderer(content: AppIconArt())
        renderer.scale = 1
        if let image = renderer.cgImage {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("AppIcon.png"))
        }
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
    if CommandLine.arguments.contains("--spectrum-test") {
        // Development aid: prints visualizer levels while media plays.
        Task {
            for second in 1...10 {
                try? await Task.sleep(for: .seconds(1))
                model.media.updateSpectrum(awake: true)
                let levels = model.media.spectrum.levels.map { String(format: "%.2f", $0) }.joined(separator: " ")
                print("SPECTRUM t=\(second) playing=\(model.media.track?.playing ?? false) running=\(model.media.spectrum.running) live=\(model.media.spectrum.live) \(levels)")
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    if CommandLine.arguments.contains("--claude-test") {
        // Development aid: what claude.ai shows this session, and whether usage reads.
        Task {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Safari/605.1.15"
            view.load(URLRequest(url: URL(string: "https://claude.ai/new")!))
            try? await Task.sleep(for: .seconds(12))
            let probe = """
            const t = document.body ? document.body.innerText : '';
            return {title: document.title, path: location.pathname, login: /log in|continue with google|continue with email/i.test(t), verify: /verify you are human|checking your browser|cloudflare/i.test(t), unsupported: /unsupported|update your browser/i.test(t), chars: t.length};
            """
            let page = try? await view.callAsyncJavaScript(probe, contentWorld: .defaultClient)
            print("CLAUDE page \(String(describing: page))")
            let usage = """
            const r = await fetch('/api/organizations', {credentials: 'include'});
            let orgs = null; try { orgs = await r.json(); } catch (e) {}
            if (!Array.isArray(orgs) || !orgs.length) return {orgsStatus: r.status};
            const org = orgs.find(o => (o.capabilities || []).some(c => String(c).startsWith('claude_'))) || orgs[0];
            const u = await fetch(`/api/organizations/${org.uuid}/usage`, {credentials: 'include'});
            let body = null; try { body = await u.json(); } catch (e) {}
            return {orgsStatus: r.status, usageStatus: u.status, keys: body ? Object.keys(body) : null, five: body && body.five_hour ? body.five_hour.utilization : null};
            """
            let result = try? await view.callAsyncJavaScript(usage, contentWorld: .defaultClient)
            print("CLAUDE usage \(String(describing: result))")
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    if CommandLine.arguments.contains("--spotify-test") {
        // Development aid: read-only Spotify checks (no playback or library changes).
        Task {
            let spotify = model.media.spotify
            print("SPOTIFY connected=\(spotify.connected)")
            await spotify.refreshPlayer()
            print("SPOTIFY smartShuffle=\(spotify.smartShuffle) context=\(spotify.context?.name ?? "none") smartPick=\(spotify.isSmartPick) liked=\(String(describing: spotify.liked))")
            await spotify.loadPlaylists()
            print("SPOTIFY playlists=\(spotify.playlists.count)")
            await spotify.refreshQueue()
            print("SPOTIFY queue=\(spotify.spotifyQueue.count) notice=\(spotify.notice ?? "-")")
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    if CommandLine.arguments.contains("--tracker-test") {
        // Development aid: prints each tracker's parsed state (no secrets).
        Task {
            let started = Date()
            print("ANKI stats=\(model.anki.stats.map { "due \($0.dueReviews) done \($0.reviewedToday)" } ?? "nil") profile=\(model.anki.profile ?? "nil")")
            model.sheets.refreshAll()
            defer {
                print("TRACKER elapsed \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                print("ANKI after load: \(model.anki.stats.map { "due \($0.dueReviews) done \($0.reviewedToday) streak \($0.streak)" } ?? "nil")")
            }
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                if model.sheets.trackers.allSatisfy({ if case .loading = model.sheets.states[$0.id] ?? .loading { return false }; return true }) { break }
            }
            for tracker in model.sheets.trackers {
                switch model.sheets.states[tracker.id] ?? .idle {
                case .loaded(let summary):
                    print("TRACKER \(summary.title): \(summary.items.count) readings, \(summary.chaptersDone) done, \(summary.pagesLeft)/\(summary.pagesTotal) pages left, \(Int(summary.fractionLeft * 100))% left, days \(summary.daysLeft.map(String.init) ?? "-")")
                    for item in summary.items.prefix(40) { print("  [\(item.done ? "x" : " ")] r\(item.row) \(item.label) | \(item.book) | \(item.pages)p | \(item.section ?? "-")") }
                case let other: print("TRACKER \(tracker.label): \(other)")
                }
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    if CommandLine.arguments.contains("--smoke-test") {
        Task {
            try? await Task.sleep(for: .seconds(2))
            let f = panel.frame
            print("ATTENDING_SMOKE screens=\(NSScreen.screens.count) frame=\(f) visible=\(panel.isVisible) mode=\(model.mode)")
            // Leave the Swift task before AppKit enters its termination loop.
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    }

    /// Renders each panel state to PNG without screen-recording access.
    func runSnapshots(_ directory: URL) {
        Task {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            model.holdOpen = true
            // --no-media: leave out what's playing (a browser video, say). Otherwise, when
            // something plays, wait for its artwork so the player isn't captured blank.
            if CommandLine.arguments.contains("--no-media") { model.media.hiddenForCapture = true }
            for _ in 0..<32 where model.media.track != nil && model.media.artwork == nil { try? await Task.sleep(for: .milliseconds(250)) }
            // --salah-demo: Fajr and Dhuhr prayed, twenty minutes into Asr, so the card reads in order.
            if CommandLine.arguments.contains("--salah-demo") {
                for _ in 0..<20 where model.salah.times[.asr] == nil { try? await Task.sleep(for: .milliseconds(250)) }
                if let asr = model.salah.times[.asr] { model.salah.showDemo(prayed: [.fajr, .dhuhr], at: asr.addingTimeInterval(20 * 60)) }
            }
            let states: [(String, PanelMode, Tab)] = [("idle", .idle, .home), ("home", .expanded, .home), ("agents", .expanded, .agents), ("assistant", .expanded, .assistant), ("study", .expanded, .study), ("preview", .preview, .home), ("shelf", .expanded, .shelf), ("clipboard", .expanded, .clipboard), ("settings", .expanded, .settings)]
            try? await Task.sleep(for: .seconds(2))
            for (name, mode, tab) in states {
                model.selectedTab = tab; model.setMode(mode)
                try? await Task.sleep(for: .seconds(name == "assistant" || name == "study" ? 6 : 1.2))
                snapshot(to: directory.appendingPathComponent("\(name).png"))
            }
            model.setMode(.idle)
            try? await Task.sleep(for: .seconds(1))
            model.showHUD(HUDState(kind: .volume, value: 0.6, symbol: "speaker.wave.2.fill", tint: Theme.primary))
            try? await Task.sleep(for: .seconds(0.9))
            snapshot(to: directory.appendingPathComponent("hud.png"))
            try? await Task.sleep(for: .seconds(1.5))
            // A file dragged over the notch: the drop targets.
            model.dragActive = true; model.setMode(.preview)
            try? await Task.sleep(for: .seconds(1.2))
            snapshot(to: directory.appendingPathComponent("drop.png"))
            model.dragActive = false; model.setMode(.idle)
            try? await Task.sleep(for: .seconds(1))
            // AirPods battery, a screenshot landing on the Shelf, and an SSD with Eject.
            model.showHUD(HUDState(kind: .headphones, value: 0.82, symbol: "airpodspro", tint: Theme.primary, label: "L 82%  R 85%  Case 60%"), seconds: 4)
            try? await Task.sleep(for: .seconds(1))
            snapshot(to: directory.appendingPathComponent("airpods-hud.png"))
            try? await Task.sleep(for: .seconds(4))
            var shot = NotchAlert(title: "Screenshot saved", subtitle: "On your Shelf · drag it anywhere", symbol: "camera.viewfinder", color: Theme.working, target: .shelf, actionTitle: "Copy", action: {})
            shot.image = NSImage(contentsOf: directory.appendingPathComponent("home.png"))
            model.raise(shot)
            try? await Task.sleep(for: .seconds(1.2))
            snapshot(to: directory.appendingPathComponent("screenshot-alert.png"))
            model.raise(NotchAlert(title: "Samsung T7 connected", subtitle: "412 GB free", symbol: "externaldrive.fill", color: Theme.working, target: .home, actionTitle: "Eject", action: {}))
            try? await Task.sleep(for: .seconds(1.2))
            snapshot(to: directory.appendingPathComponent("drive-alert.png"))
            model.alert = nil; model.setMode(.idle)
            try? await Task.sleep(for: .seconds(1))
            // A focus timer counting down in the wings.
            model.timer.start(minutes: 25, label: "Focus")
            try? await Task.sleep(for: .seconds(1.5))
            snapshot(to: directory.appendingPathComponent("timer-wings.png"))
            model.timer.cancel()
            try? await Task.sleep(for: .seconds(1))
            // An agent at work: the mark becomes the ECG, and the Agents tab lists it.
            // The session is in memory only and removed before quitting.
            let started = Date().addingTimeInterval(-240)
            model.state.apply(AgentEvent(provider: .claudeCode, sessionID: "snapshot-demo", projectPath: "/Users/demo/Attending", kind: .started, timestamp: started))
            model.state.apply(AgentEvent(provider: .claudeCode, sessionID: "snapshot-demo", projectPath: "/Users/demo/Attending", kind: .working))
            let demoID = ProviderID.claudeCode.rawValue + ":snapshot-demo"
            try? await Task.sleep(for: .seconds(1.5))
            snapshot(to: directory.appendingPathComponent("agents-wings.png"))
            model.selectedTab = .agents; model.setMode(.expanded)
            try? await Task.sleep(for: .seconds(1.5))
            snapshot(to: directory.appendingPathComponent("agents-working.png"))
            model.state.sessions.removeAll { $0.id == demoID }
            model.setMode(.idle)
            try? await Task.sleep(for: .seconds(1.2))
            // A prayer-time alert, as it drops from the notch.
            if let asr = model.salah.times[.asr] {
                model.raise(NotchAlert(title: "Time for Asr", subtitle: asr.formatted(date: .omitted, time: .shortened), symbol: "moon.stars.fill", color: Theme.done, target: .home, actionTitle: "Prayed", action: {}))
                try? await Task.sleep(for: .seconds(1.2))
                snapshot(to: directory.appendingPathComponent("salah-alert.png"))
                model.alert = nil; model.setMode(.idle)
                try? await Task.sleep(for: .seconds(1))
            }
            // A frame mid-spring, to check the transition path.
            model.selectedTab = .home; model.setMode(.expanded)
            try? await Task.sleep(for: .milliseconds(140))
            snapshot(to: directory.appendingPathComponent("transition.png"))
            try? await Task.sleep(for: .seconds(1))
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    private func snapshot(to url: URL) {
        guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
