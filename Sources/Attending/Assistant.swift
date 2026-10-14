import AppKit
import SwiftUI
import WebKit
import AttendingCore

enum AssistantProvider: String, CaseIterable, Identifiable {
    case claude, chatGPT, gemini
    var id: String { rawValue }
    var title: String {
        switch self { case .claude: "Claude"; case .chatGPT: "ChatGPT"; case .gemini: "Gemini" }
    }
    var home: URL {
        switch self {
        case .claude: URL(string: "https://claude.ai/new")!
        case .chatGPT: URL(string: "https://chatgpt.com/")!
        case .gemini: URL(string: "https://gemini.google.com/app")!
        }
    }
    /// A link that opens a new chat with the prompt filled in. Gemini has none, so its
    /// prompt is typed into the page instead (see AssistantController.askHere).
    func promptURL(_ prompt: String) -> URL? {
        guard self != .gemini else { return nil }
        var components = URLComponents(url: home, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: prompt)]
        return components.url
    }
    /// Installed desktop apps, most specific first.
    var desktopBundleIDs: [String] {
        switch self { case .claude: ["com.anthropic.claudefordesktop"]; case .chatGPT: ["com.openai.chat", "com.openai.codex"]; case .gemini: [] }
    }
    var accent: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .chatGPT: Color(red: 0.45, green: 0.78, blue: 0.64)
        case .gemini: Color(red: 0.47, green: 0.6, blue: 0.98)
        }
    }
}

/// Owns one persistent web view per provider so conversations survive switching
/// tabs and collapsing the notch. Web views are created lazily on first use.
/// Sign-in happens on the provider's own page; cookies live in WebKit's
/// default persistent store for this app.
@MainActor final class AssistantController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    @Published var provider: AssistantProvider = AssistantProvider(rawValue: UserDefaults.standard.string(forKey: "assistantProvider") ?? "") ?? .claude {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "assistantProvider") }
    }
    @Published var prompt = ""
    /// Providers shown in Ask AI, in order. Hidden ones are never loaded.
    @Published private(set) var enabled: [AssistantProvider] = {
        let hidden = Set(UserDefaults.standard.stringArray(forKey: "assistantHidden") ?? [])
        let shown = AssistantProvider.allCases.filter { !hidden.contains($0.rawValue) }
        return shown.isEmpty ? [.claude] : shown
    }()
    /// Typed into Gemini's page once it loads, since Gemini has no prompt link.
    private var pendingPrompt: [AssistantProvider: String] = [:]
    /// Providers whose page is mid-navigation; the spinner shows for the visible one.
    @Published private var loadingPages: Set<AssistantProvider> = []
    var loading: Bool { loadingPages.contains(provider) }
    @Published var notice: String?
    /// Called when a claude.ai page finishes loading (e.g. right after signing in).
    var onClaudeLoaded: (() -> Void)?
    /// Called when a provider finishes writing an answer (its Stop button goes away).
    var onAnswered: ((AssistantProvider) -> Void)?
    private var views: [AssistantProvider: WKWebView] = [:]
    /// The container currently allowed to host the web views; see AssistantWebView.
    fileprivate weak var host: NSView?
    private var preloadTask: Task<Void, Never>?
    /// The chat each provider was showing when it was unloaded, reopened next time.
    private var lastURL: [AssistantProvider: URL] = [:]
    private var unloadTask: Task<Void, Never>?
    override init() {
        super.init()
        if !enabled.contains(provider) { provider = enabled[0] }
    }
    // Safari's identity keeps provider sign-in flows (including Google) from rejecting the embedded view.
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Safari/605.1.15"

    func setEnabled(_ item: AssistantProvider, _ on: Bool) {
        var shown = Set(enabled)
        if on { shown.insert(item) } else { shown.remove(item) }
        guard !shown.isEmpty else { return }   // Keep at least one.
        enabled = AssistantProvider.allCases.filter { shown.contains($0) }
        UserDefaults.standard.set(AssistantProvider.allCases.filter { !shown.contains($0) }.map(\.rawValue), forKey: "assistantHidden")
        if !on {
            // Free its page; it stays unloaded until it's turned back on.
            views[item]?.stopLoading(); views[item]?.removeFromSuperview(); views[item] = nil
            loadingPages.remove(item); pendingPrompt[item] = nil
            if provider == item { provider = enabled[0] }
        }
    }

    func webView(for provider: AssistantProvider) -> WKWebView {
        if let view = views[provider] { return view }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController.addUserScript(WKUserScript(source: Self.answerWatcher, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        configuration.userContentController.add(self, name: "attending")
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
        if let url = provider.promptURL(text) {
            webView(for: provider).load(URLRequest(url: url))
        } else {
            // A new chat, then the prompt is typed in and sent when the page is ready.
            pendingPrompt[provider] = text
            webView(for: provider).load(URLRequest(url: provider.home))
        }
        prompt = ""
    }
    /// Types the prompt into the page's message box and presses Send. If the page's
    /// layout isn't recognized, the prompt goes on the clipboard instead.
    private func typePrompt(_ text: String, into webView: WKWebView) {
        let script = """
        for (let i = 0; i < 40; i++) {
          const box = document.querySelector('rich-textarea .ql-editor, div.ql-editor[contenteditable="true"], [contenteditable="true"][role="textbox"], textarea');
          if (box) {
            box.focus();
            if (box.tagName === 'TEXTAREA') { box.value = text; box.dispatchEvent(new Event('input', { bubbles: true })); }
            else { document.execCommand('insertText', false, text); }
            for (let j = 0; j < 10; j++) {
              await new Promise(r => setTimeout(r, 200));
              const send = document.querySelector('button[aria-label*="Send" i]:not([disabled]), button.send-button:not([disabled])');
              if (send) { send.click(); return 'sent'; }
            }
            return 'typed';
          }
          await new Promise(r => setTimeout(r, 250));
        }
        return 'missing';
        """
        webView.callAsyncJavaScript(script, arguments: ["text": text], in: nil, in: .page) { [weak self] result in
            MainActor.assumeIsolated {
                if case .success(let value) = result, value as? String == "sent" { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self?.showNotice(value(result) == "typed" ? "Press Return to send" : "Prompt copied. Press ⌘V in the message box")
            }
        }
        func value(_ result: Result<Any, Error>) -> String? { if case .success(let v) = result { return v as? String }; return nil }
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
            NSWorkspace.shared.open(text.flatMap(provider.promptURL) ?? provider.home)
            if let text, provider.promptURL(text) == nil {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                showNotice("Prompt copied. Press ⌘V in \(provider.title)")
            }
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
    /// Puts every loaded page in the container, showing only the selected one. Switching
    /// providers toggles visibility instead of moving pages between views, so a page never
    /// has to re-render or reload, and the other provider loads in the background.
    fileprivate func show(_ provider: AssistantProvider, in container: NSView) {
        _ = webView(for: provider)
        for (item, view) in views {
            if view.superview !== container {
                view.removeFromSuperview()
                view.frame = container.bounds
                view.autoresizingMask = [.width, .height]
                container.addSubview(view)
            }
            view.isHidden = item != provider
        }
        preloadOthers(in: container)
    }
    private func preloadOthers(in container: NSView) {
        guard enabled.contains(where: { views[$0] == nil }), preloadTask == nil else { return }
        preloadTask = Task { [weak self, weak container] in
            // Let the visible page start first.
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            preloadTask = nil
            guard let container, host === container else { return }
            for item in enabled where views[item] == nil { _ = webView(for: item) }
            show(provider, in: container)
        }
    }
    /// Runs a script in a provider's page (dev checks only).
    func evaluate(_ script: String, in item: AssistantProvider) async -> Any? {
        guard let view = views[item] else { return nil }
        return try? await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }
    private func provider(of webView: WKWebView) -> AssistantProvider? { views.first { $0.value === webView }?.key }

    /// Watches for the page's Stop button: present while an answer streams, gone when it's
    /// done. Reads nothing else from the page and sends only the word "answered".
    private static let answerWatcher = """
    (() => {
      if (window.__attendingWatch) return; window.__attendingWatch = true;
      const stop = '[data-testid="stop-button"], button[aria-label="Stop response"], button[aria-label="Stop streaming"], button[aria-label*="Stop generating" i]';
      let busy = false, since = 0;
      setInterval(() => {
        const now = !!document.querySelector(stop);
        if (now && !busy) since = Date.now();
        if (!now && busy && Date.now() - since > 1500) window.webkit.messageHandlers.attending.postMessage('answered');
        busy = now;
      }, 700);
    })();
    """
    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard message.body as? String == "answered", let webView = message.webView, let item = provider(of: webView) else { return }
            onAnswered?(item)
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
        loadingPages.removeAll()
        preloadTask?.cancel(); preloadTask = nil
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
        case .gemini: return cookies.contains { $0.domain.hasSuffix("google.com") && $0.name == "__Secure-1PSID" }
        }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if let item = provider(of: webView) { loadingPages.insert(item) }
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
        if let item = provider(of: webView) {
            loadingPages.remove(item)
            if let text = pendingPrompt.removeValue(forKey: item) { typePrompt(text, into: webView) }
        }
        Self.log("finish \(Self.describe(webView.url))")
        if webView.url?.host == "claude.ai" { onClaudeLoaded?() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if let item = provider(of: webView) { loadingPages.remove(item) }; Self.log("fail \(Self.describe(webView.url)) \((error as NSError).domain) \((error as NSError).code)")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if let item = provider(of: webView) { loadingPages.remove(item) }; Self.log("fail-provisional \(Self.describe(webView.url)) \((error as NSError).domain) \((error as NSError).code)")
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
        // The newest container owns the web views. During a tab crossfade SwiftUI keeps the
        // outgoing container alive briefly; without an owner the two could trade the pages
        // back and forth and leave them in the one being removed (the page "disappeared").
        controller.host = container
        return container
    }
    func updateNSView(_ container: NSView, context: Context) {
        guard controller.host === container else { return }
        controller.show(provider, in: container)
    }
}

struct AssistantView: View {
    @ObservedObject var assistant: AssistantController
    @FocusState private var promptFocused: Bool
    var focusToken: Int

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(assistant.enabled.count > 1 ? assistant.enabled : []) { item in
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
