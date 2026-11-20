import Foundation
import WebKit
import CryptoKit

/// Trestly's own kUSDT transaction builders (kusdt-open `bridge/packages/core/pkg-web`, the same
/// WebAssembly their wallet runs), run inside KaPay (owner's call, 2026-11-19): a KCC-20 input's
/// unlock script and compute budget come from running the token contract, which only their
/// runtime does exactly.
///
/// How it's kept safe:
/// - The three files ship in the app (`Resources/KusdtCore/`) and are checked against the SHA-256s
///   below before anything loads; the WebAssembly's is the one in kusdt-open's PROVENANCE.json.
/// - They're served only through a private scheme (`kusdt-core://`) to a hidden, non-persistent web
///   view that's never shown and navigates nowhere else.
/// - KaPay hands it one request at a time (`run`) and reads back the signed transaction. A key goes
///   in only for the address being spent from, and only for that call.
/// - Trestly's wallet logic for the pool (`kusdt-wallet.js`, `wallet(_:request:)`) runs beside it for
///   trades on Trestly's site. Its HTTP goes through `KusdtNetRelay` (the Kaspa resolvers and the
///   Trestly API only); its node client opens a WebSocket to the public Kaspa node a resolver names
///   (wss://<name>.kaspa.stream, .red, .green or .blue, as their code requires).
@MainActor
final class KusdtCore: NSObject {
    static let shared = KusdtCore()

    /// kusdt-open b70707c: `kusdt_wasm_bg.wasm` (PROVENANCE.json `wasm`), its loader, and KaPay's page,
    /// by the name the page asks for: the bundle file (the loader ships as `.js.txt`, so Xcode copies
    /// it rather than treating it as source) and its SHA-256.
    private static let pinned: [String: (resource: String, ext: String, sha256: String)] = [
        "kusdt_wasm_bg.wasm": ("kusdt_wasm_bg", "wasm", "a7be48e962dab57902924ea71fbad31b073cd2ba2197ebcf0de83b0f2a54fd53"),
        "kusdt_wasm.js": ("kusdt_wasm.js", "txt", "be01841b7f2eb700acb38c7b36b9faef7d3deeefb7c86a233731afef0052dc78"),
        "kusdt-core.html": ("kusdt-core", "html", "b745a9a272cbf8fc593bea189af02f8ab4602c5f5a8c6317ae903e2ef12b8dc2"),
        // Trestly's own wallet logic for the pool (wallet/extension/src/kusdt at b70707c), bundled by
        // tools/kusdt-wallet (build.mjs prints this hash).
        "kusdt-wallet.js": ("kusdt-wallet.js", "txt", "6631a35d5c0fc2ceb00ac08611379442e6a8fe75aec36dbcb530343ffd439cb2"),
    ]
    private static let scheme = "kusdt-core"

    enum CoreError: LocalizedError {
        case unavailable(String)
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let why): return why
            case .refused(let why): return why
            }
        }
    }

    private var webView: WKWebView?
    private var files: [String: Data] = [:]
    private var ready = false
    private var waiting: [CheckedContinuation<Void, Error>] = []
    private var loadError: String?
    /// Trestly's wallet logic (`window.kapayWallet`): loaded after the core, so a failure there never
    /// stops kUSDT sends.
    private var walletReady = false
    private var walletError: String?
    private var walletWaiting: [CheckedContinuation<Void, Error>] = []
    /// The pinned files are being checked (off the main thread) before the page exists.
    private var starting = false
    /// When the last start failed: a later call tries again after a short pause, so one failure
    /// (a page killed in the background, a slow start) doesn't turn kUSDT off for the session.
    private var loadFailedAt: Date?

    /// How long the page may take to come up, and the longest any one call may take: a review or
    /// trade never spins forever (audit, 2026-11-20). Execute covers Trestly's own waits (the pool
    /// coin aging up to a minute, then up to 30 s to see the trade accepted, merges first).
    private static let startTimeout: UInt64 = 25_000_000_000
    private static func callTimeout(_ function: String) -> UInt64 {
        switch function {
        case "execute": return 240_000_000_000
        case "prepare": return 90_000_000_000
        default: return 30_000_000_000
        }
    }

    /// Runs `body`, or throws after `nanoseconds` if it hasn't answered.
    private func withTimeout<T: Sendable>(_ nanoseconds: UInt64, _ body: @escaping @MainActor () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { @MainActor in try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                throw CoreError.unavailable(AppLocalization.string("kUSDT's transaction builder gave no answer."))
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// Runs one builder command on a JSON request; answers the result as JSON, or throws the
    /// builder's own error (`{"error": …}`).
    func run(_ command: String, request: [String: Any]) async throws -> [String: Any] {
        try await load()
        guard let webView else { throw CoreError.unavailable(AppLocalization.string("kUSDT's transaction builder couldn't start.")) }
        let data = try JSONSerialization.data(withJSONObject: request)
        guard let json = String(data: data, encoding: .utf8) else { throw CoreError.unavailable("bad request") }
        let answer = try await withTimeout(Self.callTimeout("run")) {
            try await webView.callAsyncJavaScript(
                "return window.kusdtCore.ready ? window.kusdtCore.run(command, request) : null",
                arguments: ["command": command, "request": json],
                in: nil,
                contentWorld: .page
            ) as? String
        }
        guard let text = answer,
              let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw CoreError.unavailable(AppLocalization.string("kUSDT's transaction builder gave no answer."))
        }
        if let error = parsed["error"] as? String { throw CoreError.refused(error) }
        return parsed
    }

    // MARK: Trestly's wallet logic

    /// Runs `window.kapayWallet.prepare` or `.execute` (tools/kusdt-wallet/src/entry.ts) on one
    /// request; answers its JSON, which carries `error` (and maybe `code`) when it refused.
    func wallet(_ function: String, request: [String: Any]) async throws -> [String: Any] {
        guard function == "prepare" || function == "execute" else { throw CoreError.unavailable("bad call") }
        try await load()
        try await loadWallet()
        guard let webView else { throw CoreError.unavailable(AppLocalization.string("kUSDT's transaction builder couldn't start.")) }
        let data = try JSONSerialization.data(withJSONObject: request)
        guard let json = String(data: data, encoding: .utf8) else { throw CoreError.unavailable("bad request") }
        let answer = try await withTimeout(Self.callTimeout(function)) {
            try await webView.callAsyncJavaScript(
                "return await window.kapayWallet[fn](request)",
                arguments: ["fn": function, "request": json],
                in: nil,
                contentWorld: .page
            ) as? String
        }
        guard let text = answer,
              let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw CoreError.unavailable(AppLocalization.string("Trestly's pool code gave no answer."))
        }
        return parsed
    }

    private func loadWallet() async throws {
        if walletReady { return }
        if let walletError { throw CoreError.unavailable(walletError) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            walletWaiting.append(continuation)
        }
    }

    /// The page never said whether Trestly's code loaded: give up rather than wait forever.
    private func armWalletTimeout() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.startTimeout)
            guard let self, !self.walletReady, self.walletError == nil, !self.walletWaiting.isEmpty || self.ready else { return }
            self.finishWallet(error: AppLocalization.string("Trestly's pool code couldn't start in KaPay."))
        }
    }

    private func finishWallet(error: String?) {
        if let error { walletError = error } else { walletReady = true }
        // the page has everything it asked for: the 8 MB of files needn't stay in memory
        if ready || error != nil { files = [:] }
        let continuations = walletWaiting
        walletWaiting = []
        for c in continuations {
            if let error { c.resume(throwing: CoreError.unavailable(error)) } else { c.resume() }
        }
    }

    // MARK: Loading

    private func load() async throws {
        if ready { return }
        if let loadError {
            // a start that failed a while ago is tried again; one that just failed answers at once
            guard let failed = loadFailedAt, Date().timeIntervalSince(failed) > 10 else { throw CoreError.unavailable(loadError) }
            self.loadError = nil
            walletError = nil
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiting.append(continuation)
            guard webView == nil, !starting else { return }
            start()
        }
    }

    private func start() {
        starting = true
        // every file read and hashed off the main thread (the WebAssembly is about 8 MB), and
        // checked before the web view exists
        let pinned = Self.pinned
        Task.detached(priority: .userInitiated) {
            var checked: [String: Data] = [:]
            var refused: String?
            for (name, file) in pinned {
                guard let url = Bundle.main.url(forResource: file.resource, withExtension: file.ext),
                      let data = try? Data(contentsOf: url),
                      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                    refused = name
                    break
                }
                checked[name] = data
            }
            await MainActor.run { [checked, refused] in
                self.starting = false
                if let refused {
                    AppLog.log("[kUSDT] the builder file %@ is missing or not the pinned one: refused", refused)
                    self.finish(error: AppLocalization.string("kUSDT's transaction builder isn't the pinned one, so it won't run."))
                    return
                }
                self.files = checked
                self.openPage()
            }
        }
    }

    private func openPage() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(self, forURLScheme: Self.scheme)
        configuration.userContentController.add(WeakMessageHandler(self), name: "kusdtCore")
        // the wallet logic's HTTP (allow-listed) and its kept records
        configuration.userContentController.addScriptMessageHandler(KusdtNetRelay(), contentWorld: .page, name: "kusdtNet")
        configuration.userContentController.addScriptMessageHandler(KusdtStoreRelay(), contentWorld: .page, name: "kusdtStore")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        guard let url = URL(string: "\(Self.scheme)://core/kusdt-core.html") else { return }
        view.load(URLRequest(url: url))
        // a page that never reports (its module failed to load before any code ran) fails here
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.startTimeout)
            guard let self, !self.ready, self.webView === view else { return }
            self.finish(error: AppLocalization.string("kUSDT's transaction builder couldn't start."))
        }
        armWalletTimeout()
    }

    private func finish(error: String?) {
        if let error {
            loadError = error
            loadFailedAt = Date()
            webView = nil
            files = [:]
            finishWallet(error: error)
        } else {
            ready = true
        }
        let continuations = waiting
        waiting = []
        for c in continuations {
            if let error { c.resume(throwing: CoreError.unavailable(error)) } else { c.resume() }
        }
    }

    fileprivate func received(_ body: Any) {
        guard let message = body as? [String: Any] else { return }
        if message["ready"] as? Bool == true {
            AppLog.log("[kUSDT] builder ready (%@)", (message["version"] as? String) ?? "?")
            finish(error: nil)
        } else if message["walletReady"] as? Bool == true {
            AppLog.log("[kUSDT] Trestly's wallet logic ready")
            finishWallet(error: nil)
        } else if let error = message["walletError"] as? String {
            AppLog.log("[kUSDT] Trestly's wallet logic failed to load: %@", error)
            finishWallet(error: AppLocalization.string("Trestly's pool code couldn't start in KaPay."))
        } else if let error = message["error"] as? String {
            AppLog.log("[kUSDT] builder failed to start: %@", error)
            finish(error: AppLocalization.string("kUSDT's transaction builder couldn't start."))
        }
    }
}

// MARK: - Serving the pinned files

extension KusdtCore: WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let name = urlSchemeTask.request.url?.lastPathComponent ?? ""
        guard let data = files[name] else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = name.hasSuffix(".wasm") ? "application/wasm" : name.hasSuffix(".js") ? "text/javascript" : "text/html"
        let response = HTTPURLResponse(url: urlSchemeTask.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

extension KusdtCore: WKNavigationDelegate {
    /// The page goes nowhere but its own files.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.scheme == Self.scheme ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if !ready { finish(error: AppLocalization.string("kUSDT's transaction builder couldn't start.")) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if !ready { finish(error: AppLocalization.string("kUSDT's transaction builder couldn't start.")) }
    }

    /// The hidden page's process was killed (memory pressure, the app in the background): start
    /// over on the next call instead of answering "no answer" until a relaunch.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        AppLog.log("[kUSDT] builder page was terminated: it starts again on the next use")
        self.webView = nil
        ready = false
        walletReady = false
        walletError = nil
        loadError = nil
        files = [:]
        let continuations = waiting
        waiting = []
        for c in continuations { c.resume(throwing: CoreError.unavailable(AppLocalization.string("kUSDT's transaction builder couldn't start."))) }
        let walletContinuations = walletWaiting
        walletWaiting = []
        for c in walletContinuations { c.resume(throwing: CoreError.unavailable(AppLocalization.string("Trestly's pool code couldn't start in KaPay."))) }
    }
}

/// The content controller holds its handler strongly; this keeps the core from holding itself.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var core: KusdtCore?
    init(_ core: KusdtCore) { self.core = core }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        Task { @MainActor in self.core?.received(body) }
    }
}
