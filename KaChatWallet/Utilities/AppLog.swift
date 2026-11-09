import Foundation
import os

/// Drop-in replacement for `NSLog` with the same variadic format-string signature, so every
/// existing call site can be migrated by literally renaming `NSLog(` to `AppLog.log(` with no
/// other changes.
///
/// Why this exists: plain `NSLog` calls were not showing up at all in the exported diagnostics
/// archive (`SettingsView.collectAppLogs()` queries `OSLogStore(scope: .currentProcessIdentifier)`)
/// - only system-framework log lines (which all use the structured `Logger`/`os_log` API) came
/// through. Routing our own logging through `Logger` with an explicit subsystem makes it
/// reliably queryable the same way, so future diagnostics exports actually contain the app's own
/// `[Tag] ...` lines instead of being silently empty.
enum AppLog {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kachat.wallet",
        category: "app"
    )

    /// A full Kaspa address (`kaspa:`, `kaspatest:`, or the `_` form used in keys and file names).
    private static let addressPattern = try? NSRegularExpression(
        pattern: "(?<![a-z0-9])(?:kaspa|kaspatest|kaspasim|kaspadev)[:_]([a-z0-9]{12,})", options: [.caseInsensitive]
    )

    /// Every address in a log line is cut to "…" and its last 8 characters, wherever it came from
    /// (a format argument, a URL, a key name), so call sites need no care of their own.
    static func shortenAddresses(_ message: String) -> String {
        guard let addressPattern else { return message }
        let ns = message as NSString
        var out = message
        for match in addressPattern.matches(in: message, range: NSRange(location: 0, length: ns.length)).reversed() {
            let payload = ns.substring(with: match.range(at: 1))
            guard let range = Range(match.range, in: out) else { continue }
            out.replaceSubrange(range, with: "…" + payload.suffix(8))
        }
        return out
    }

    static func log(_ format: String, _ args: CVarArg...) {
        let message = shortenAddresses(String(format: format, arguments: args))
        // The whole message is marked public (not per-argument private, os_log's default) since
        // this mirrors NSLog's own behavior - everything logged here was already visible in
        // Console before, and none of these call sites log secrets (keys/seed phrases/decrypted
        // message content are never passed to NSLog/AppLog anywhere in this codebase).
        logger.log("\(message, privacy: .public)")
    }
}
