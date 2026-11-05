import Foundation
import Combine

/// The Testnet toggle's choice, waiting for the next launch. The wallet address, the node pool and
/// every service are set up for one network at launch, so switching `networkType` live left the
/// app half on each: indexer, push and .kachat moved at once while the wallet and node stayed,
/// and incoming messages were dropped as "the other network" (IOS-002). The toggle only records
/// the choice here; `applyAtLaunch()` switches everything together when the app next starts.
enum PendingNetworkSwitch {
    private static let key = "kachat_pending_network_type"

    static var target: NetworkType? {
        get { UserDefaults.standard.string(forKey: key).flatMap(NetworkType.init(rawValue:)) }
        set {
            if let newValue { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    /// Call first thing at app launch, before anything reads the settings.
    static func applyAtLaunch() {
        guard let target else { return }
        self.target = nil
        var settings = AppSettings.load()
        guard target != settings.networkType else { return }
        settings.switchNetwork(to: target)
        AppSettings.save(settings)
    }
}

/// Thread-safe cache for `AppSettings.load()`, which is called from hot paths (per API request,
/// per row render). Invalidated whenever settings change (`.settingsDidChange` is posted by every
/// write path: `AppSettings.save` and `SettingsViewModel.saveSettings`).
private final class AppSettingsCache: @unchecked Sendable {
    static let shared = AppSettingsCache()
    private let lock = NSLock()
    private var cached: AppSettings?
    private var observer: NSObjectProtocol?
    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .settingsDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            self?.invalidate()
        }
    }
    func get() -> AppSettings? { lock.lock(); defer { lock.unlock() }; return cached }
    func set(_ settings: AppSettings) { lock.lock(); defer { lock.unlock() }; cached = settings }
    func invalidate() { lock.lock(); defer { lock.unlock() }; cached = nil }
}

/// Extension to load settings from any context (not MainActor-isolated)
extension AppSettings {
    /// Biometrics for Account Login went from on to off by default (owner's call, 2026-11-05) and
    /// saved settings hold the old `true`. Switched off once per install, so turning it back on
    /// sticks. It runs ahead of the first read, and every in-memory copy of the settings starts
    /// from `load()`, so nothing can save the old value back over it. A `static let` so one thread
    /// does this while any others wait, which is also why it posts no change notification: an
    /// observer calling `load()` from inside this would never return.
    private static let accountLoginBiometricsOffMigration: Void = {
        let defaults = UserDefaults.standard
        let doneKey = "kachat_account_login_biometrics_off_migrated"
        guard !defaults.bool(forKey: doneKey) else { return }
        if let data = defaults.data(forKey: "kachat_app_settings"),
           var settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings.biometricAccountLoginEnabled = false
            if let updated = try? JSONEncoder().encode(settings) {
                defaults.set(updated, forKey: "kachat_app_settings")
            }
        }
        defaults.set(true, forKey: doneKey)
    }()

    /// Load settings from UserDefaults (can be called from any context). Cached - see
    /// `AppSettingsCache`.
    static func load() -> AppSettings {
        _ = accountLoginBiometricsOffMigration
        if let cached = AppSettingsCache.shared.get() { return cached }
        guard let data = UserDefaults.standard.data(forKey: "kachat_app_settings"),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            AppSettingsCache.shared.set(.default)
            return .default
        }
        // Decoding moved a superseded default indexer (`supersededIndexerURLs`) forward: store
        // the migrated values so they stick.
        let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if raw?["indexerURL"] as? String != settings.indexerURL
            || raw?["pushIndexerURL"] as? String != settings.pushIndexerURL {
            save(settings)
        }
        AppSettingsCache.shared.set(settings)
        return settings
    }

    /// Symmetric write path for services that don't hold a `SettingsViewModel` reference - same
    /// storage key/notification as `SettingsViewModel.saveSettings()`, just callable without an
    /// instance.
    static func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: "kachat_app_settings")
        NotificationCenter.default.post(name: .settingsDidChange, object: settings)
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var settings: AppSettings

    private let userDefaults = UserDefaults.standard
    private let settingsKey = "kachat_app_settings"

    /// The network the app started on. The node pool, the wallet address and every service are
    /// set up for it at launch, so a switch in Connection Settings takes effect on the next
    /// launch - this is what tells the Testnet tab to say so.
    let launchNetworkType: NetworkType

    init() {
        let loaded = AppSettings.load()
        self.settings = loaded
        self.launchNetworkType = loaded.networkType
        // A change made elsewhere posts .settingsDidChange with a nil object, so this instance
        // reloads. Saves post WITH the settings object - skipped here, this instance already
        // holds those values.
        NotificationCenter.default.addObserver(
            forName: .settingsDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard notification.object == nil else { return }
            Task { @MainActor [weak self] in
                self?.settings = AppSettings.load()
            }
        }
    }

    /// Load settings (MainActor convenience)
    static func loadSettings() -> AppSettings {
        return AppSettings.load()
    }

    func saveSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        userDefaults.set(data, forKey: settingsKey)

        // Notify other services of settings changes
        NotificationCenter.default.post(name: .settingsDidChange, object: settings)
    }

    /// Settings > Connection > Testnet. Only records the choice: the switch, with each network's
    /// own connection settings (`AppSettings.switchNetwork(to:)`), happens at the next launch
    /// (`PendingNetworkSwitch`). Choosing the network the app runs on cancels a pending switch.
    func switchNetwork(to network: NetworkType) {
        objectWillChange.send()
        PendingNetworkSwitch.target = network == launchNetworkType ? nil : network
    }

    /// The network the Testnet toggle shows: the pending choice, else the one running.
    var selectedNetworkType: NetworkType { PendingNetworkSwitch.target ?? settings.networkType }

    // MARK: - Convenience Methods
    var networkType: NetworkType {
        get { settings.networkType }
        set {
            settings.networkType = newValue
            saveSettings()
        }
    }

    var notificationsEnabled: Bool {
        get { settings.notificationsEnabled }
        set {
            settings.notificationsEnabled = newValue
            saveSettings()
        }
    }

    var backgroundFetchEnabled: Bool {
        get { settings.backgroundFetchEnabled }
        set {
            settings.backgroundFetchEnabled = newValue
            saveSettings()
        }
    }

    var notificationMode: NotificationMode {
        get { settings.notificationMode }
        set {
            settings.notificationMode = newValue
            saveSettings()
        }
    }

    var indexerURL: String {
        get { settings.indexerURL }
        set {
            settings.indexerURL = newValue
            saveSettings()
        }
    }

    var pushIndexerURL: String {
        get { settings.pushIndexerURL }
        set {
            settings.pushIndexerURL = newValue
            saveSettings()
        }
    }

    /// Read-only: the KNS endpoint is fixed to the network's default (see `AppSettings`).
    var knsBaseURL: String { settings.knsBaseURL }

    var kaspaRestAPIURL: String {
        get { settings.kaspaRestAPIURL }
        set {
            settings.kaspaRestAPIURL = newValue
            saveSettings()
        }
    }

    var kaspaExplorer: KaspaExplorer {
        get { settings.kaspaExplorer }
        set {
            settings.kaspaExplorer = newValue
            saveSettings()
        }
    }

    /// Validates and applies a new trusted-node address (empty = automatic discovery instead of a
    /// pinned node). Returns a user-facing error message and leaves `settings` untouched if
    /// `value` is non-empty but not a valid endpoint; returns `nil` on success. Keeps
    /// `NodePoolService` in step, not just `AppSettings`.
    @discardableResult
    func applyTrustedNode(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || Endpoint(url: trimmed) != nil else {
            return "Enter as host:port or grpcs://host"
        }
        guard trimmed != settings.trustedNodeAddress else { return nil }
        settings.trustedNodeAddress = trimmed
        saveSettings()
        Task {
            await NodePoolService.shared.setTrustedNodeAddress(trimmed)
        }
        return nil
    }

    /// Sets or clears the standard `AppleLanguages` preferred-language override. The app picks up
    /// a language change at once via `.environment(\.locale, ...)` in `KaChatApp.swift`; this is
    /// for the OS's own Bundle-driven resolution (alerts, system strings) on the next launch.
    func applyLanguagePreference(_ language: AppLanguage) {
        if let code = language.appleLanguageCode {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }
}

extension Notification.Name {
    static let settingsDidChange = Notification.Name("settingsDidChange")
}
