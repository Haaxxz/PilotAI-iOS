import Foundation

/// Shared by native navigation, redirects, popups, and tool input validation.
public enum BrowserURLPolicy {
    public static func allowedURL(_ text: String) -> URL? {
        guard !text.isEmpty, text.utf8.count <= 2048,
              text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              text.rangeOfCharacter(from: .controlCharacters) == nil,
              !text.contains("\\"),
              let parts = URLComponents(string: text),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              let url = parts.url else { return nil }
        return url
    }

    public static func addressURL(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = allowedURL(text) { return url }
        guard !text.isEmpty, text.utf8.count <= 2048,
              text.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        // Never turn a rejected file:, javascript:, data:, credential URL, etc. into a search.
        if text.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil { return nil }
        if !text.contains(" "), text.contains(".") { return allowedURL("https://" + text) }
        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: text)]
        return search.url.flatMap { allowedURL($0.absoluteString) }
    }
}

#if canImport(WebKit) && canImport(UIKit)
import Combine
import UIKit
import WebKit

/// The native Browser and agent share the same persistent website store and WKWebView.
/// All WebKit state and approval continuations are confined to the main actor.
@MainActor
public final class IOSBrowserService: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    public static let shared = IOSBrowserService()
    @Published public private(set) var webView: WKWebView
    @Published public private(set) var currentURL: URL?
    @Published public private(set) var title = ""
    @Published public private(set) var canGoBack = false
    @Published public private(set) var canGoForward = false
    @Published public private(set) var isLoading = false
    @Published public private(set) var progress = 0.0
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var isResetting = false
    @Published public private(set) var isTakenOver = false
    @Published public private(set) var pendingApproval: Approval?

    public struct Approval: Identifiable {
        public let id: UUID
        public let title: String
        public let detail: String
        public let pageURL: String
    }

    private struct Observation {
        let id: String
        let epoch: UUID
        let url: String
        let created: Date
        let controls: [String: [String: Any]]
    }

    private var observations: [NSKeyValueObservation] = []
    private var epoch = UUID()
    private var pageObservation: Observation?
    private var visibleViews = 0
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    private var approvalTimeout: Task<Void, Never>?
    private var toolInFlight = false
    private var evaluations: [UUID: CheckedContinuation<[String: Any], Error>] = [:]
    private var evaluationTimeouts: [UUID: Task<Void, Never>] = [:]
    private var resetContinuation: CheckedContinuation<Void, Never>?
    private var resetTimeout: Task<Void, Never>?
    private var resetNavigation: WKNavigation?

    private override init() {
        webView = Self.makeWebView()
        super.init()
        attachWebView()
    }

    private static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        return view
    }

    private func attachWebView() {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState() } }
        ]
        syncState()
    }

    private func syncState() {
        if currentURL != webView.url { invalidatePage() }
        currentURL = webView.url
        title = String((webView.title ?? "").prefix(200))
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        progress = webView.estimatedProgress
    }

    private func invalidatePage() {
        epoch = UUID()
        pageObservation = nil
        resolveApproval(accepted: false)
    }

    public func browserAppeared() { visibleViews += 1 }
    public func browserDisappeared() {
        visibleViews = max(0, visibleViews - 1)
        if visibleViews == 0 { invalidatePage() }
    }

    public func suspendApprovals() { invalidatePage() }

    public func setTakeover(_ active: Bool) {
        isTakenOver = active
        invalidatePage()
        statusMessage = active ? "You have control. Agent browser requests are paused." : "Agent requests require approval here for each action."
    }

    public func navigate(address: String) {
        guard !isResetting else { return }
        guard let url = BrowserURLPolicy.addressURL(address) else {
            errorMessage = "Enter a valid HTTP or HTTPS address. Local files, custom schemes and embedded credentials are not allowed."
            return
        }
        load(url)
    }

    private func load(_ url: URL) {
        invalidatePage()
        errorMessage = nil; statusMessage = nil
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        webView.load(request)
        syncState()
    }

    public func goBack() { guard !isResetting, webView.canGoBack else { return }; invalidatePage(); errorMessage = nil; webView.goBack() }
    public func goForward() { guard !isResetting, webView.canGoForward else { return }; invalidatePage(); errorMessage = nil; webView.goForward() }
    public func reloadOrStop() {
        guard !isResetting else { return }
        invalidatePage()
        if webView.isLoading { webView.stopLoading(); statusMessage = "Loading stopped." }
        else { errorMessage = nil; webView.reload() }
        syncState()
    }

    public func approve(_ id: UUID) {
        guard pendingApproval?.id == id, visibleViews > 0, UIApplication.shared.applicationState == .active,
              !isTakenOver, !isResetting else { resolveApproval(accepted: false); return }
        resolveApproval(accepted: true)
    }

    public func deny(_ id: UUID) { if pendingApproval?.id == id { resolveApproval(accepted: false) } }

    private func resolveApproval(accepted: Bool) {
        let continuation = approvalContinuation
        approvalContinuation = nil
        pendingApproval = nil
        approvalTimeout?.cancel(); approvalTimeout = nil
        continuation?.resume(returning: accepted)
    }

    private func requestApproval(title: String, detail: String) async throws {
        try Task.checkCancellation()
        guard !isTakenOver, !isResetting else { throw BrowserError.unavailable("Browser is paused for manual takeover or session reset.") }
        let request = Approval(id: UUID(), title: title, detail: detail, pageURL: currentURL?.absoluteString ?? "No page open")
        let accepted = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                approvalContinuation = continuation
                pendingApproval = request
                approvalTimeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: 120_000_000_000) } catch { return }
                    if self?.pendingApproval?.id == request.id { self?.resolveApproval(accepted: false) }
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in if self?.pendingApproval?.id == request.id { self?.resolveApproval(accepted: false) } }
        })
        try Task.checkCancellation()
        guard accepted, visibleViews > 0, UIApplication.shared.applicationState == .active, !isTakenOver, !isResetting else {
            throw BrowserError.unavailable("The action was not approved in Browser (denied, dismissed, expired or cancelled). No action was dispatched.")
        }
    }

    /// Called only after BrowserView's destructive confirmation. The blank-page transition
    /// stops scripts from repopulating storage while the persistent store is being cleared.
    public func resetSession() async {
        guard !isResetting else { return }
        isResetting = true
        invalidatePage()
        for id in Array(evaluations.keys) { finishEvaluation(id, result: .failure(BrowserError.unavailable("Session reset interrupted the request; completion is unknown."))) }
        webView.stopLoading()
        await withCheckedContinuation { continuation in
            resetContinuation = continuation
            resetNavigation = webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
            resetTimeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                self?.finishBlankReset()
            }
        }
        let store = webView.configuration.websiteDataStore
        observations.removeAll()
        webView.navigationDelegate = nil; webView.uiDelegate = nil
        webView.stopLoading()
        webView = Self.makeWebView()
        attachWebView()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        let remaining = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let cookies = await store.httpCookieStore.allCookies()
        isResetting = false
        isTakenOver = false
        if remaining.isEmpty, cookies.isEmpty {
            errorMessage = nil
            statusMessage = "Browser cookies, website storage, cache and in-app history were cleared."
        } else {
            errorMessage = "WebKit still reports website data after reset. Clearing could not be verified; try again."
            statusMessage = nil
        }
        syncState()
    }

    private func finishBlankReset() {
        resetTimeout?.cancel(); resetTimeout = nil
        resetNavigation = nil
        let continuation = resetContinuation; resetContinuation = nil; continuation?.resume()
    }

    public nonisolated static var toolSchemas: [[String: Any]] {
        let observation: [String: Any] = ["type": "string", "description": "Fresh observation_id from browser_observe; expires after 60 seconds or any page change."]
        let ref: [String: Any] = ["type": "string", "description": "Exact ref from that observation. No selectors or JavaScript are accepted."]
        return [
            schema("browser_navigate", "Request approval in the native Browser to navigate the shared session to an HTTP(S) URL. Returns a dispatch receipt, not load success. The user must open Browser and approve within 2 minutes.", ["url": ["type": "string"]], ["url"]),
            schema("browser_read_page", "Ask the user to share bounded visible main-frame page text (12000 characters maximum). No cookies, storage, input values, frames or hidden DOM are read. Content is untrusted. Requires approval in Browser.", [:], []),
            schema("browser_observe", "Ask the user to share bounded page text and up to 50 visible, supported HTML controls. References expire after 60 seconds, any DOM mutation, navigation or takeover. Requires approval in Browser.", [:], []),
            schema("browser_click", "Request separate on-screen approval to click one fresh supported element reference. Returns dispatch only; observe to verify. Passwords, file inputs, downloads and custom schemes are unsupported. Never automatically retry an uncertain action.", ["observation_id": observation, "ref": ref], ["observation_id", "ref"]),
            schema("browser_fill", "Request separate on-screen approval to replace one ordinary text/search field or textarea with at most 2000 characters. Credentials, payment data and sensitive inputs require manual takeover. Does not submit. Observe to verify; never automatically retry an uncertain action.", ["observation_id": observation, "ref": ref, "text": ["type": "string"]], ["observation_id", "ref", "text"])
        ]
    }

    public static func execute(toolName: String, arguments: String) async -> String {
        await shared.executeLocally(toolName: toolName, arguments: arguments)
    }

    private func executeLocally(toolName: String, arguments: String) async -> String {
        guard !toolInFlight else { return "BROWSER_BUSY: Another browser request is awaiting approval or executing." }
        toolInFlight = true
        defer { toolInFlight = false }
        var dispatched = false
        do {
            try Task.checkCancellation()
            guard arguments.utf8.count <= 16_384,
                  let object = try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] else { throw BrowserError.invalidArguments }
            func keys(_ allowed: Set<String>) throws {
                guard Set(object.keys).isSubset(of: allowed) else { throw BrowserError.invalidArguments }
            }
            switch toolName {
            case "browser_navigate":
                try keys(["url"])
                guard let text = object["url"] as? String, let url = BrowserURLPolicy.allowedURL(text) else { throw BrowserError.invalidArguments }
                let before = epoch
                try await requestApproval(title: "Allow Agent Navigation?", detail: "Open this address in your shared browser session:\n\(url.absoluteString)")
                guard before == epoch else { throw BrowserError.stale }
                load(url)
                return try json(["dispatched": true, "requested_url": url.absoluteString, "load_verified": false, "next_step": "Read or observe after loading to verify the resulting page."])
            case "browser_read_page", "browser_observe":
                try keys([])
                try requirePage()
                let before = epoch
                try await requestApproval(title: "Share Page with Agent?", detail: "Share up to 12000 characters of visible page text\(toolName == "browser_observe" ? " and up to 50 supported controls" : ""). The page may contain private information from your signed-in session. Input values and website storage are excluded.")
                guard before == epoch else { throw BrowserError.stale }
                try requirePage()
                let id = UUID().uuidString
                var result = try await evaluate(Self.observeScript, arguments: ["observationID": id, "includeControls": toolName == "browser_observe"])
                guard before == epoch, result["url"] as? String == currentURL?.absoluteString else { throw BrowserError.stale }
                if toolName == "browser_observe" {
                    let controls = result["controls"] as? [[String: Any]] ?? []
                    pageObservation = Observation(id: id, epoch: epoch, url: currentURL!.absoluteString, created: Date(),
                                                  controls: Dictionary(uniqueKeysWithValues: controls.compactMap { item in (item["ref"] as? String).map { ($0, item) } }))
                    result["observation_id"] = id
                } else { pageObservation = nil }
                result["untrusted_content"] = true
                result["scope"] = "Main frame only; bounded visible text; no input values, cookies or storage."
                return try json(result)
            case "browser_click", "browser_fill":
                try keys(toolName == "browser_fill" ? ["observation_id", "ref", "text"] : ["observation_id", "ref"])
                guard let id = object["observation_id"] as? String, let ref = object["ref"] as? String,
                      let observation = pageObservation, observation.id == id,
                      let control = observation.controls[ref] else { throw BrowserError.stale }
                try validate(observation)
                let isFill = toolName == "browser_fill"
                guard control[isFill ? "can_fill" : "can_click"] as? Bool == true else {
                    throw BrowserError.unavailable("This control is not supported for this action. Use manual takeover.")
                }
                let text = object["text"] as? String ?? ""
                if isFill { guard object["text"] is String, text.count <= 2000, text.utf8.count <= 8000 else { throw BrowserError.invalidArguments } }
                let label = control["label"] as? String ?? ref
                let detail = isFill ? "Replace the text in “\(label)” (\(ref)) with:\n\(text)\n\nThis does not submit the form. Use Take Over for passwords, codes, payment or other sensitive data."
                    : "Click “\(label)” (\(ref)) on this page. This may submit a form or make a change on the website."
                try await requestApproval(title: isFill ? "Allow Agent Fill?" : "Allow Agent Click?", detail: detail)
                try validate(observation)
                pageObservation = nil
                dispatched = true
                let result = try await evaluate(Self.actionScript, arguments: ["observationID": id, "ref": ref, "action": isFill ? "fill" : "click", "text": text])
                if let rejection = result["rejected"] as? String { return "BROWSER_NOT_DISPATCHED: \(rejection) Observe again; no automatic retry." }
                return try json(["dispatched": true, "action": isFill ? "fill" : "click", "outcome_verified": false,
                                 "next_step": "Observe the resulting page to verify the outcome. Never automatically repeat the action."])
            default: return "TOOL_UNAVAILABLE: This browser action is not implemented."
            }
        } catch is CancellationError {
            return dispatched ? "TOOL_CANCELLED: The browser action may have run. Inspect the page; do not automatically retry." : "TOOL_CANCELLED: No browser action was dispatched."
        } catch {
            let detail = (error as? BrowserError)?.localizedDescription ?? "WebKit could not complete the request."
            return "BROWSER_ERROR: \(detail)" + (dispatched ? " The action may have run. Inspect the page; do not automatically retry." : "")
        }
    }

    private func requirePage() throws {
        guard !isResetting, !isTakenOver, !webView.isLoading, let url = webView.url,
              BrowserURLPolicy.allowedURL(url.absoluteString) != nil else {
            throw BrowserError.unavailable("Open an HTTP(S) page in Browser and wait for loading to finish. Agent access must not be paused.")
        }
    }

    private func validate(_ observation: Observation) throws {
        try Task.checkCancellation()
        try requirePage()
        guard observation.epoch == epoch, observation.url == webView.url?.absoluteString,
              Date().timeIntervalSince(observation.created) < 60 else { throw BrowserError.stale }
    }

    private func evaluate(_ script: String, arguments: [String: Any]) async throws -> [String: Any] {
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                evaluations[id] = continuation
                evaluationTimeouts[id] = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                    self?.finishEvaluation(id, result: .failure(BrowserError.unavailable("WebKit evaluation timed out.")))
                }
                // Fixed app-owned scripts, parameterized values, isolated namespace, main frame.
                // Neither the model nor page content can supply executable JavaScript.
                webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .defaultClient) { [weak self] result in
                    Task { @MainActor in
                        let parsed = result.flatMap { value -> Result<[String: Any], Error> in
                            guard let object = value as? [String: Any] else { return .failure(BrowserError.unavailable("Invalid WebKit result.")) }
                            return .success(object)
                        }
                        self?.finishEvaluation(id, result: parsed)
                    }
                }
            }
        }, onCancel: { [weak self] in Task { @MainActor in self?.finishEvaluation(id, result: .failure(CancellationError())) } })
    }

    private func finishEvaluation(_ id: UUID, result: Result<[String: Any], Error>) {
        evaluationTimeouts.removeValue(forKey: id)?.cancel()
        evaluations.removeValue(forKey: id)?.resume(with: result)
    }

    private func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= 256 * 1024 else { throw BrowserError.unavailable("Page response exceeded the bounded output limit.") }
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func schema(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String]) -> [String: Any] {
        ["type": "function", "function": ["name": name, "description": description,
            "parameters": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]]
    }

    private enum BrowserError: LocalizedError {
        case invalidArguments, stale, unavailable(String)
        var errorDescription: String? {
            switch self {
            case .invalidArguments: return "Invalid browser arguments. Only the advertised bounded HTTP(S)/reference actions are supported."
            case .stale: return "The page or element reference changed or expired. Observe again and request new approval."
            case .unavailable(let reason): return reason
            }
        }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard webView === self.webView else { decisionHandler(.cancel); return }
        if isResetting {
            decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
            return
        }
        guard let url = navigationAction.request.url, BrowserURLPolicy.allowedURL(url.absoluteString) != nil else {
            errorMessage = "Navigation was blocked: only HTTP and HTTPS pages are supported."
            decisionHandler(.cancel); return
        }
        if navigationAction.shouldPerformDownload {
            errorMessage = "Downloads are not supported in the agent browser. Open the page in Safari to download manually."
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.canShowMIMEType else {
            errorMessage = "This response requires a download or external viewer. Open it in Safari."
            decisionHandler(.cancel); return
        }
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
            errorMessage = "The website returned HTTP \(response.statusCode)."
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        invalidatePage(); errorMessage = nil; statusMessage = nil; syncState()
    }
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { syncState() }
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        syncState()
        if let expected = resetNavigation, navigation === expected { finishBlankReset() }
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error, navigation: navigation) }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error, navigation: navigation) }
    private func failed(_ error: Error, navigation: WKNavigation?) {
        syncState()
        if (error as NSError).code != NSURLErrorCancelled { errorMessage = "Page failed to load: " + String(error.localizedDescription.prefix(300)) }
        if let expected = resetNavigation, navigation === expected { finishBlankReset() }
    }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        invalidatePage(); syncState(); errorMessage = "The web content process ended. Reload the page to continue."
        if isResetting { finishBlankReset() }
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if !isResetting, navigationAction.targetFrame == nil, let url = navigationAction.request.url,
           BrowserURLPolicy.allowedURL(url.absoluteString) != nil {
            // Keep explicit target=_blank navigation in the same visible, approved session.
            invalidatePage()
            errorMessage = nil; statusMessage = nil
            webView.load(navigationAction.request)
        }
        return nil
    }

    // Fixed bounded extractor. No HTML, cookies, storage, field values or cross-origin frames
    // are serialized. Main-frame DOM data is explicitly labelled untrusted in native output.
    private static let observeScript = #"""
    if (window.__pilotObservation?.observer) window.__pilotObservation.observer.disconnect();
    const visible = e => {
      if (!e || e.closest('[hidden],[aria-hidden="true"],script,style,noscript,template')) return false;
      const r = e.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) return false;
      let ancestor = e, depth = 0;
      while (ancestor && depth++ < 40) {
        const s = getComputedStyle(ancestor);
        if (s.visibility !== 'visible' || s.display === 'none' || s.opacity === '0') return false;
        ancestor = ancestor.parentElement;
      }
      return !ancestor;
    };
    const sensitive = e => /password|passcode|one.?time|otp|token|secret|credential|credit|card|cc-|cvc|cvv|ssn|social.?security|username|login|auth/i.test(
      [e.type,e.name,e.id,e.autocomplete,e.getAttribute('aria-label'),e.getAttribute('placeholder')].join(' '));
    const smallText = e => {
      const w = document.createTreeWalker(e, NodeFilter.SHOW_TEXT); let s = '', n, count = 0;
      while ((n = w.nextNode()) && count++ < 20 && s.length < 160) {
        const p = n.parentElement;
        if (p && !p.closest('input,textarea,select,[contenteditable]') && visible(p)) s += (n.nodeValue || '').slice(0, 160 - s.length);
      }
      return s.replace(/\s+/g, ' ').trim();
    };
    const describe = e => {
      const r = e.getBoundingClientRect();
      const tag = e.tagName, type = (e.type || '').toLowerCase();
      const label = (e.getAttribute('aria-label') || e.getAttribute('placeholder') || e.getAttribute('title') ||
        (['INPUT','TEXTAREA'].includes(tag) ? '' : smallText(e)) || tag).slice(0,160);
      const protectedField = sensitive(e);
      const canFill = !protectedField && !e.disabled && !e.readOnly && (tag === 'TEXTAREA' || (tag === 'INPUT' && ['text','search'].includes(type)));
      let canClick = !protectedField && !e.disabled && (tag === 'BUTTON' || (tag === 'INPUT' && ['button','submit','reset','checkbox','radio'].includes(type)));
      if (tag === 'A' && !e.hasAttribute('download')) {
        try { const u = new URL(e.href); canClick = ['http:','https:'].includes(u.protocol) && !u.username && !u.password; } catch (_) {}
      }
      const mark = JSON.stringify([tag,type,label,e.id,e.name,e.getAttribute('href'),e.getAttribute('onclick'),e.form?.action,e.form?.method,
        e.disabled,e.readOnly,e.autocomplete,e.getAttribute('style'),r.x,r.y,r.width,r.height,(canFill ? e.value : '').slice(0,2001)]);
      return { label, can_fill: canFill, can_click: canClick, mark, type, tag };
    };
    let text = '', scanned = 0, node;
    const root = document.body || document.documentElement;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    while ((node = walker.nextNode()) && scanned++ < 3000 && text.length < 12000) {
      const parent = node.parentElement;
      if (!parent || parent.closest('input,textarea,select,[contenteditable]') || !visible(parent)) continue;
      const value = (node.nodeValue || '').slice(0,12000 - text.length).replace(/\s+/g,' ').trim();
      if (value) text += (text ? '\n' : '') + value.slice(0,12000 - text.length - (text ? 1 : 0));
    }
    const registry = { id: observationID, url: location.href, created: Date.now(), dirty: false, elements: {}, visible, describe };
    const controls = [];
    if (includeControls) {
      const elements = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT); let e, count = 0;
      while ((e = elements.nextNode()) && count++ < 2000 && controls.length < 50) {
        if (!['A','BUTTON','INPUT','TEXTAREA'].includes(e.tagName) || !visible(e)) continue;
        const r = e.getBoundingClientRect();
        if (r.bottom <= 0 || r.top >= innerHeight || r.right <= 0 || r.left >= innerWidth) continue;
        const d = describe(e); if (!d.can_click && !d.can_fill) continue;
        const ref = 'e' + controls.length;
        registry.elements[ref] = { element: e, mark: d.mark };
        controls.push({ref, label: d.label, tag: d.tag, type: d.type, can_click: d.can_click, can_fill: d.can_fill});
      }
    }
    registry.observer = new MutationObserver(() => { registry.dirty = true; });
    registry.observer.observe(document.documentElement, {subtree:true,childList:true,attributes:true,characterData:true});
    window.__pilotObservation = registry;
    return {url: location.href.slice(0,2048), title: document.title.slice(0,200), text, controls,
      text_truncated: text.length >= 12000 || scanned >= 3000, controls_bounded: true};
    """#

    private static let actionScript = #"""
    const state = window.__pilotObservation;
    const reject = reason => ({rejected: reason});
    if (document.visibilityState !== 'visible') return reject('Browser is no longer visible.');
    if (!state || state.id !== observationID || state.dirty || state.url !== location.href || Date.now() - state.created > 60000)
      return reject('The page changed or the observation expired.');
    if (state.observer.takeRecords().length) return reject('The DOM changed.');
    const saved = state.elements[ref], e = saved?.element;
    if (!e || !e.isConnected || !state.visible(e)) return reject('The element is no longer visible.');
    const d = state.describe(e);
    if (d.mark !== saved.mark) return reject('The element changed.');
    const r = e.getBoundingClientRect(), x = Math.max(0,Math.min(innerWidth - 1,r.x + r.width / 2)), y = Math.max(0,Math.min(innerHeight - 1,r.y + r.height / 2));
    const top = document.elementFromPoint(x,y);
    if (!top || !(top === e || e.contains(top))) return reject('The element is obscured.');
    if ((action === 'fill' && !d.can_fill) || (action === 'click' && !d.can_click)) return reject('Use manual takeover for this control.');
    state.dirty = true; state.observer.disconnect();
    if (action === 'fill') {
      const prototype = e.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(prototype,'value').set;
      setter.call(e,text);
      e.dispatchEvent(new Event('input',{bubbles:true}));
      e.dispatchEvent(new Event('change',{bubbles:true}));
    } else {
      HTMLElement.prototype.click.call(e);
    }
    return {dispatched:true};
    """#
}
#else

/// Linux/unit-test fallback. Native iOS builds use the WebKit implementation above; this
/// keeps pure model/runtime tests honest instead of pretending a browser exists off-device.
public enum IOSBrowserService {
    public static let toolSchemas: [[String: Any]] = []
    public static func execute(toolName: String, arguments: String) async -> String {
        "BROWSER_UNAVAILABLE: WebKit browser tools require the native iOS runtime and a visible Browser view."
    }
}
#endif
