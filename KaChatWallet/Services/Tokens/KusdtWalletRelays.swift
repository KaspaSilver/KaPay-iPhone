import Foundation
import WebKit

/// HTTP for Trestly's wallet logic in the hidden core page (tools/kusdt-wallet/src/shims.ts replaces
/// its `fetch` with this). Only https, and only to:
/// - the public Kaspa node resolvers their node client asks (`<name>.kaspa.stream`, `.red`, `.green`,
///   `.blue`, the same rule as kusdt-open's `NODE_HOST`), and
/// - the Trestly API host set in Settings > Connection > Trestly.
/// Anything else is refused, and so is a redirect to anywhere else (each hop is checked again).
/// Requests carry at most 64 KB; answers are read only up to 4 MB.
@MainActor
final class KusdtNetRelay: NSObject, WKScriptMessageHandlerWithReply {
    private nonisolated static let resolverHost = try! NSRegularExpression(pattern: "^[a-z0-9-]+\\.kaspa\\.(stream|red|green|blue)$")
    private static let maxBytes = 4 * 1024 * 1024
    private static let maxRequestBytes = 64 * 1024

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
    }()

    nonisolated static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return false }
        if let api = URL(string: AppSettings.load().trestlyAPIURL)?.host?.lowercased(), host == api { return true }
        let range = NSRange(host.startIndex..., in: host)
        return resolverHost.firstMatch(in: host, range: range) != nil
    }

    /// Follows a redirect only to an allowed address: the first URL's check must hold for every hop.
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            if let url = request.url, KusdtNetRelay.allowed(url) {
                completionHandler(request)
            } else {
                completionHandler(nil)
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any],
              let text = body["url"] as? String, text.count <= 2048, let url = URL(string: text) else {
            return (["error": "bad request"], nil)
        }
        guard Self.allowed(url) else {
            AppLog.log("[kUSDT] wallet logic asked for %@: refused", url.host ?? "?")
            return (["error": "KaPay doesn't let this reach \(url.host ?? "that address")."], nil)
        }
        let method = ((body["method"] as? String) ?? "GET").uppercased()
        guard method == "GET" || method == "POST" else { return (["error": "method not allowed"], nil) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in (body["headers"] as? [String: String]) ?? [:] {
            let k = key.lowercased()
            // only what a JSON API needs: never cookies or credentials
            if (k == "content-type" || k == "accept"), value.count <= 200 { request.setValue(value, forHTTPHeaderField: key) }
        }
        if method == "POST", let payload = body["body"] as? String {
            guard payload.utf8.count <= Self.maxRequestBytes else { return (["error": "request too long"], nil) }
            request.httpBody = Data(payload.utf8)
        }
        do {
            let (bytes, response) = try await Self.session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return (["error": "no answer"], nil) }
            if http.expectedContentLength > Int64(Self.maxBytes) { return (["error": "answer too long"], nil) }
            // read up to the cap and no further, whatever the server says its length is
            var data = Data()
            data.reserveCapacity(max(0, min(Int(http.expectedContentLength), Self.maxBytes)))
            for try await byte in bytes {
                data.append(byte)
                if data.count > Self.maxBytes { return (["error": "answer too long"], nil) }
            }
            var headers: [String: String] = ["content-length": String(data.count)]
            if let type = http.value(forHTTPHeaderField: "Content-Type") { headers["content-type"] = type }
            if let etag = http.value(forHTTPHeaderField: "ETag") { headers["etag"] = etag }
            return (["status": http.statusCode, "headers": headers, "body": String(decoding: data, as: UTF8.self)], nil)
        } catch {
            return (["error": error.localizedDescription], nil)
        }
    }
}

/// `chrome.storage.local` for Trestly's wallet logic: what it keeps between runs (the liquidity
/// positions it made, coins it knows, transactions it's following), per network and owner key.
/// Kept as one JSON file in Application Support (not UserDefaults: it can grow), 2 MB at most in
/// all, only keys starting `kusdt.`. Nothing secret goes in it: their code keeps keys elsewhere,
/// and KaPay hands a key in only for one call. An account's entries go with the account
/// (`forget(ownerHex:)`, from `TokenWallet.forgetLocalData`).
@MainActor
final class KusdtStoreRelay: NSObject, WKScriptMessageHandlerWithReply {
    private static let legacyDefaultsKey = "kusdt_wallet_store"
    private static let maxEntryBytes = 512 * 1024
    private static let maxTotalBytes = 2 * 1024 * 1024

    /// Each value as its JSON text, by key.
    private static var cache: [String: String]?

    private static var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("kusdt-wallet-store.json")
    }

    private static func loadStore() -> [String: String] {
        if let cache { return cache }
        var stored: [String: String] = [:]
        if let url = fileURL, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            stored = decoded
        }
        // the first builds kept it in UserDefaults: moved over once
        if let legacy = UserDefaults.standard.dictionary(forKey: legacyDefaultsKey) as? [String: String] {
            stored.merge(legacy) { current, _ in current }
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
            save(stored)
        }
        cache = stored
        return stored
    }

    private static func save(_ values: [String: String]) {
        cache = values
        guard let url = fileURL, let data = try? JSONEncoder().encode(values) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Drops what Trestly's code kept for one owner key: entries named after it, and records in
    /// lists (positions) that name it as their owner.
    static func forget(ownerHex: String) {
        let owner = ownerHex.lowercased()
        var all = loadStore()
        for (key, text) in all {
            if key.lowercased().contains(owner) {
                all[key] = nil
            } else if text.lowercased().contains(owner),
                      let list = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] {
                let kept = list.filter { (($0["owner"] as? String)?.lowercased() ?? "") != owner }
                if let data = try? JSONSerialization.data(withJSONObject: kept) {
                    all[key] = String(decoding: data, as: UTF8.self)
                }
            }
        }
        save(all)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
            return (["error": "bad request"], nil)
        }
        switch op {
        case "get":
            let keys = ((body["keys"] as? [String]) ?? []).prefix(64)
            let all = Self.loadStore()
            var value: [String: Any] = [:]
            for key in keys {
                if let text = all[key], let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) {
                    value[key] = parsed
                }
            }
            return (["value": value], nil)
        case "set":
            var all = Self.loadStore()
            for (key, value) in (body["values"] as? [String: Any]) ?? [:] {
                guard key.hasPrefix("kusdt."), key.count <= 256, !(value is NSNull),
                      JSONSerialization.isValidJSONObject([value]),
                      let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
                      data.count <= Self.maxEntryBytes else { continue }
                all[key] = String(decoding: data, as: UTF8.self)
            }
            // over the total cap: refuse the write rather than grow without bound
            guard all.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= Self.maxTotalBytes else {
                return (["error": "store full"], nil)
            }
            Self.save(all)
            return (["value": [:]], nil)
        case "remove":
            var all = Self.loadStore()
            for key in ((body["keys"] as? [String]) ?? []) where key.hasPrefix("kusdt.") { all[key] = nil }
            Self.save(all)
            return (["value": [:]], nil)
        default:
            return (["error": "bad op"], nil)
        }
    }
}
