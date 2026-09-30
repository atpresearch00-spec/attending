import AppKit
import SwiftUI
import WebKit
import AttendingCore

enum AssistantProvider: String, CaseIterable, Identifiable {
    case claude, chatGPT
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude" : "ChatGPT" }
    var home: URL { URL(string: self == .claude ? "https://claude.ai/new" : "https://chatgpt.com/")! }
    func promptURL(_ prompt: String) -> URL {
        var components = URLComponents(url: home, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: prompt)]
        return components.url!
    }
    /// Installed desktop apps, most specific first.
    var desktopBundleIDs: [String] { self == .claude ? ["com.anthropic.claudefordesktop"] : ["com.openai.chat", "com.openai.codex"] }
    var accent: Color { self == .claude ? Color(red: 0.85, green: 0.47, blue: 0.34) : Color(red: 0.45, green: 0.78, blue: 0.64) }
}

/// Owns one persistent web view per provider so conversations survive switching
/// tabs and collapsing the notch. Web views are created lazily on first use.
/// Sign-in happens on the provider's own page; cookies live in WebKit's
/// default persistent store for this app.
@MainActor final class AssistantController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var provider: AssistantProvider = AssistantProvider(rawValue: UserDefaults.standard.string(forKey: "assistantProvider") ?? "") ?? .claude {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "assistantProvider") }
    }
    @Published var prompt = ""
    @Published var loading = false
    @Published var notice: String?
    /// Called when a claude.ai page finishes loading (e.g. right after signing in).
    var onClaudeLoaded: (() -> Void)?
    private var views: [AssistantProvider: WKWebView] = [:]
    /// The container currently allowed to host each provider's web view; see AssistantWebView.
    fileprivate var hosts: [AssistantProvider: NSView] = [:]
    /// The chat each provider was showing when it was unloaded, reopened next time.
    private var lastURL: [AssistantProvider: URL] = [:]
    private var unloadTask: Task<Void, Never>?
    // Safari's identity keeps provider sign-in flows (including Google) from rejecting the embedded view.
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Safari/605.1.15"

    func webView(for provider: AssistantProvider) -> WKWebView {
        if let view = views[provider] { return view }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = userAgent
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.setValue(false, forKey: "drawsBackground")
        view.load(URLRequest(url: lastURL[provider] ?? provider.home))
        views[provider] = view
        return view
    }

    /// Enter: ask inside the notch window.
    func askHere() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        webView(for: provider).load(URLRequest(url: provider.promptURL(text)))
        prompt = ""
    }
    /// ⌘Enter: hand off to the desktop app.
    func askInDesktopApp() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        openDesktopApp(prompt: text.isEmpty ? nil : text)
        prompt = ""
    }
    func openDesktopApp(prompt text: String? = nil) {
        guard let appURL = provider.desktopBundleIDs.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first else {
            // No desktop app: open the provider in the default browser instead.
            NSWorkspace.shared.open(text.map(provider.promptURL) ?? provider.home)
            return
        }
        if let text {
            // The prompt also goes on the clipboard in case the app ignores the deep link.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            if provider == .claude, let deepLink = URL(string: "claude://claude.ai/new?q=" + (text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")) {
                NSWorkspace.shared.open(deepLink)
            } else {
                NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
            }
            showNotice("Prompt copied — press ⌘V if it isn't filled in")
        } else {
            NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
        }
    }
    func reload() { views[provider]?.reload() }
    func goHome() { views[provider]?.load(URLRequest(url: provider.home)) }
    func openInBrowser() { NSWorkspace.shared.open(views[provider]?.url ?? provider.home) }
    /// Frees the web content processes (roughly 100–300 MB each).
    func unload() {
        for (provider, view) in views {
            if let url = view.url, url.host?.hasSuffix(provider.home.host ?? "") == true { lastURL[provider] = url }
            view.stopLoading(); view.removeFromSuperview()
        }
        views.removeAll()
    }
    /// Web pages keep running scripts while hidden, so unload them after 10 minutes
    /// out of sight; the open chat is restored when Ask AI is shown again.
    func scheduleUnload() {
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled else { return }
            self?.unload()
        }
    }
    func cancelUnload() { unloadTask?.cancel(); unloadTask = nil }

    private func showNotice(_ text: String) {
        notice = text
        Task { try? await Task.sleep(for: .seconds(4)); if notice == text { notice = nil } }
    }

    // MARK: Sign-in popups

    /// Google, Apple and SSO sign-in open a popup that reports back to the page that
    /// opened it (window.opener). Loading it in the same view breaks that handoff, so
    /// each popup gets a real window built from WebKit's own configuration.
    @Published private(set) var popupOpen = false
    private var popups: [NSWindow] = []
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let size = CGSize(width: max(460, windowFeatures.width?.doubleValue ?? 500), height: max(560, windowFeatures.height?.doubleValue ?? 640))
        let popupView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
        popupView.customUserAgent = userAgent
        popupView.uiDelegate = self
        popupView.navigationDelegate = self
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Sign in"
        window.contentView = popupView
        window.level = .statusBar + 1
        window.isReleasedWhenClosed = false
        window.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                self?.popups.removeAll { $0 === window }
                self?.popupOpen = !(self?.popups.isEmpty ?? true)
            }
        }
        popups.append(window)
        popupOpen = true
        Self.log("popup opened for \(Self.describe(navigationAction.request.url))")
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return popupView
    }
    /// The provider closes its popup (window.close()) when sign-in finishes. The page
    /// that opened it completes the login itself; reloading here would abort that
    /// request and bounce back to the login screen.
    func webViewDidClose(_ webView: WKWebView) {
        Self.log("popup closed by page")
        popups.first { $0.contentView === webView }?.close()
        // Wait until the provider has stored its session, then open the chat page and
        // tell listeners (the usage meter) that Claude is signed in.
        Task { [weak self] in
            for _ in 0..<24 {
                if await Self.hasSession(for: .claude) { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            try? await Task.sleep(for: .milliseconds(800))
            guard let self else { return }
            Self.log("session ready; opening home")
            views[provider]?.load(URLRequest(url: provider.home))
            if provider == .claude { onClaudeLoaded?() }
        }
    }
    /// Whether WebKit holds the provider's login cookie (claude.ai's `sessionKey`).
    static func hasSession(for provider: AssistantProvider) async -> Bool {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        switch provider {
        case .claude: return cookies.contains { $0.domain.hasSuffix("claude.ai") && $0.name == "sessionKey" }
        case .chatGPT: return cookies.contains { $0.domain.hasSuffix("chatgpt.com") && $0.name.hasPrefix("__Secure-next-auth.session-token") }
        }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
        Self.log("start \(Self.describe(webView.url)) popup=\(popups.contains { $0.contentView === webView })")
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http = navigationResponse.response as? HTTPURLResponse, http.statusCode >= 400 {
            Self.log("HTTP \(http.statusCode) \(Self.describe(http.url))")
        }
        return .allow
    }
    /// Sign-in diagnostics: host and path only — never query strings, form data or cookies.
    static func describe(_ url: URL?) -> String { url.map { "\($0.host ?? "?")\($0.path)" } ?? "nil" }
    static func log(_ message: String) {
        let url = AppPaths.directory.appendingPathComponent("assistant.log")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        text += "\(Date().formatted(.iso8601)) \(message)\n"
        let lines = text.split(separator: "\n")
        if lines.count > 300 { text = lines.suffix(300).joined(separator: "\n") + "\n" }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        Self.log("finish \(Self.describe(webView.url))")
        if webView.url?.host == "claude.ai" { onClaudeLoaded?() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading = false; Self.log("fail \(Self.describe(webView.url)) \((error as NSError).domain) \((error as NSError).code)")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false; Self.log("fail-provisional \(Self.describe(webView.url)) \((error as NSError).domain) \((error as NSError).code)")
    }
}

struct AssistantWebView: NSViewRepresentable {
    let controller: AssistantController
    let provider: AssistantProvider
    func makeNSView(context: Context) -> NSView {
        // AppKit views ignore SwiftUI clip shapes, so the container clips the web view
        // itself; otherwise the page could spill over the tab bar while the island animates.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.layer?.cornerRadius = 14
        // The newest container owns the web view. During a tab crossfade SwiftUI keeps the
        // outgoing container alive briefly; without an owner the two could trade the page
        // back and forth and leave it in the one being removed (the page "disappeared").
        controller.hosts[provider] = container
        return container
    }
    func updateNSView(_ container: NSView, context: Context) {
        guard controller.hosts[provider] === container else { return }
        let view = controller.webView(for: provider)
        guard view.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }
}

struct AssistantView: View {
    @ObservedObject var assistant: AssistantController
    @FocusState private var promptFocused: Bool
    var focusToken: Int

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(AssistantProvider.allCases) { item in
                    Button { assistant.provider = item } label: {
                        HStack(spacing: 6) {
                            Circle().fill(item.accent).frame(width: 6, height: 6)
                            Text(item.title).font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 12).frame(height: 26)
                        .background(Capsule().fill(assistant.provider == item ? Theme.raised : .clear))
                        .foregroundStyle(assistant.provider == item ? Theme.primary : Theme.secondary)
                    }.buttonStyle(.plain)
                }
                Spacer()
                if assistant.loading { ProgressView().controlSize(.small).scaleEffect(0.7) }
                IconButton(symbol: "house", help: "New chat") { assistant.goHome() }
                IconButton(symbol: "arrow.clockwise", help: "Reload") { assistant.reload() }
                IconButton(symbol: "safari", help: "Open in browser") { assistant.openInBrowser() }
                IconButton(symbol: "arrow.up.forward.app", help: "Open the \(assistant.provider.title) app") { assistant.openDesktopApp() }
            }
            HStack(spacing: 8) {
                Image(systemName: "sparkle").font(.system(size: 12, weight: .semibold)).foregroundStyle(assistant.provider.accent)
                TextField("Ask \(assistant.provider.title)…", text: $assistant.prompt)
                    .textFieldStyle(.plain).font(.system(size: 14))
                    .focused($promptFocused)
                    .onSubmit { assistant.askHere() }
                Button { assistant.askInDesktopApp() } label: {
                    Text("App ⌘↩").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiary)
                }.buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command).help("Send to the \(assistant.provider.title) desktop app")
                Text("↩ here").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(promptFocused ? assistant.provider.accent.opacity(0.6) : .clear, lineWidth: 1))
            if let notice = assistant.notice {
                Text(notice).font(.caption).foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            AssistantWebView(controller: assistant, provider: assistant.provider)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        }
        .onAppear { promptFocused = true; assistant.cancelUnload() }
        .onDisappear { assistant.scheduleUnload() }
        .onChange(of: focusToken) { promptFocused = true }
    }
}
