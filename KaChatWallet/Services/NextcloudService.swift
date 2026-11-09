import CryptoKit
import Foundation
import UIKit

/// A connected Nextcloud account (server + login + app password), persisted as one Keychain blob.
struct NextcloudAccount: Codable, Equatable {
    var serverURLString: String
    var username: String
    var appPassword: String
    /// Where the contacts file lives - nil means the default "KaChat" folder at the files root.
    /// Optional so blobs stored before this field existed still decode.
    var backupFolder: String? = nil

    var serverURL: URL? { URL(string: serverURLString) }
    var displayName: String {
        let host = URL(string: serverURLString)?.host ?? serverURLString
        return "\(username)@\(host)"
    }
}

/// One entry from a WebDAV folder listing.
struct NextcloudFile: Identifiable, Equatable {
    /// Path relative to the user's files root, e.g. "Photos/cat.jpg".
    let path: String
    let name: String
    let isDirectory: Bool
    let contentType: String?
    let size: Int64?
    let modified: Date?

    var id: String { path }

}

extension Array where Element == NextcloudFile {
    /// The one ordering every Nextcloud listing surface uses: phone-gallery order.
    ///
    /// Folders stay grouped ahead of files (so a folder never lands in the middle of the
    /// thumbnail grid), and within each group entries run newest-first by `getlastmodified`.
    /// Entries whose date the server omitted or that failed to parse sort last rather than
    /// interleaving randomly, and name is the tiebreak so equal timestamps stay deterministic.
    ///
    /// Applied once in `NextcloudService.listFolder`; views only filter, never re-sort.
    func sortedNewestFirst() -> [NextcloudFile] {
        sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            switch (lhs.modified, rhs.modified) {
            case let (left?, right?):
                if left != right { return left > right }
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            case (nil, nil):
                break
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

enum NextcloudError: LocalizedError {
    case invalidServerURL
    case httpNotSupported
    case badCredentials
    case httpError(Int)
    case malformedResponse
    case truncatedDownload(received: Int64, expected: Int64)
    case backupNotFound
    case noActiveWallet
    /// The app is running on testnet, where Nextcloud is off (see `isOffForTestnet`).
    case offOnTestnet
    /// HTTP 423 on the file after the retries: Nextcloud's lock on the file did not clear.
    case backupLocked
    /// The upload finished but the server stored fewer bytes than were sent (a relay cut it).
    case uploadCutOff(sent: Int, stored: Int64)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "That doesn't look like a valid server URL."
        case .httpNotSupported:
            return "Use https. Unencrypted connections are not supported."
        case .badCredentials:
            return "Nextcloud rejected the username or app password."
        case .noActiveWallet:
            return "Sign in to an account before connecting Nextcloud."
        case .offOnTestnet:
            return String(localized: "Nextcloud is off while Testnet is on.")
        case .httpError(let code):
            return "Nextcloud returned HTTP \(code)."
        case .malformedResponse:
            return "Unexpected response from the Nextcloud server."
        case .truncatedDownload(let received, let expected):
            return "The backup download stopped early (\(received) of \(expected) bytes). "
                + "Nothing on the server was changed, so trying again is safe."
        case .backupNotFound:
            return "No backup was found in the KaChat folder."
        case .backupLocked:
            return "Nextcloud has the backup file locked (HTTP 423): another device or sync is reading "
                + "or writing it right now. Try again in a minute. If it keeps happening, the lock is "
                + "stale on the server - clear it with occ (maintenance mode on, empty the file locks, off)."
        case .uploadCutOff(let sent, let stored):
            return "The backup upload was cut off: the server stored \(stored) of \(sent) bytes. "
                + "Something between this device and Nextcloud is ending large uploads early."
        }
    }
}

/// The user's own Nextcloud server, for one thing: backing up Contacts and the Portfolio.
/// Connect with an app password. The files:
/// - `backupFileName` in the backup folder: the contacts, encrypted (`BackupEnvelope`). It's the same
///   file KaChat uses, with the same key, so both apps and all of an account's devices sync through
///   it: read, merge, then write only if the file is missing something this device has. With
///   Automatic Sync on it uploads after a contact changes and a foreground ETag poll brings in other
///   devices' changes. KaChat's NEXTCLOUD_SYNC.md, "Contacts only", is the contract.
/// - One file per portfolio in the backup folder, named what the portfolio is named ("Long Term.json"):
///   its transactions and fees plus what was deleted (`PortfolioBackupFile`), encrypted with the
///   contacts' key (`BackupEnvelope`). A file this account can't decrypt is another account's, or
///   not a portfolio, and is left alone; an earlier plain one of this account's is read, then
///   written encrypted with the next backup. Exports (Export CSV, Export to Nextcloud) stay plain
///   CSV, for a spreadsheet. With Automatic Sync on they
///   upload a few seconds after a change and merge in what's on the server when the app opens.
/// A backup merges what is on the server in first, so it never overwrites another device's changes,
/// and a fresh connection merges both in once. The contacts' earlier plain files are merged in once
/// and never written again, as is the one Portfolio file the app used to write. Import / Export in
/// Contacts and Portfolio also reach the KaChat folder.
///
/// Everything here is scoped to the ACTIVE WALLET ACCOUNT: credentials live in a per-wallet
/// Keychain entry (`KeychainService.saveNextcloudCredentials(_:walletAddress:)`), the toggle and
/// last-backup stamp in per-wallet UserDefaults keys, and `setCurrentWallet` (called by
/// WalletManager) swaps the whole state on account switch/logout so one account's login never
/// leaks into another.
@MainActor
final class NextcloudService: ObservableObject {
    static let shared = NextcloudService()

    @Published private(set) var account: NextcloudAccount?

    /// Settings > Storage > Nextcloud > "Automatic Sync", per wallet account. Default off: a
    /// connection is not a request to start uploading.
    @Published private(set) var autoBackupEnabled = false

    /// When the active wallet's backup last uploaded (nil = never).
    @Published private(set) var lastBackupAt: Date?

    /// When the active wallet's contacts last synced automatically (nil = never): Settings' "Last
    /// synced", and the floor between automatic uploads.
    @Published private(set) var lastAutoSyncAt: Date?

    /// One-line result of the silent restore on connect. MainTabView renders it as a toast; nil
    /// hides it.
    @Published var syncStatusToast: String?

    /// Nextcloud refused this login (a revoked app password, say). Automatic Sync stops asking until
    /// the next launch or connection, and Settings says what to do.
    @Published private(set) var needsReconnect = false

    /// True when the app is running on testnet. Nextcloud is a mainnet-only feature: the backup
    /// file is one per account across both networks, so on testnet the service holds no account
    /// at all, and the mainnet connection comes back on the next mainnet launch. Fixed per launch,
    /// like the network itself.
    @Published private(set) var isOffForTestnet = false

    /// The active wallet's address - every credential/settings read and write is scoped to it.
    private(set) var currentWalletAddress: String?
    /// Same 8-byte SHA256 hex as the Keychain entry, for the UserDefaults keys.
    private var currentWalletHashSuffix: String?

    /// The pending Portfolio upload after a change, and any upload in flight - cancelled on an account
    /// switch so one account's data never uploads while another is active.
    private var backupTask: Task<Void, Never>?
    /// The Portfolio changed since the last successful upload. Persisted, so a kill before the upload
    /// still backs up on the next background or launch.
    private var pendingBackup = false
    /// When the app last looked for another device's Portfolio changes.
    private var lastServerCheck: Date?

    /// The in-flight on-background or catch-up contacts sync.
    private var autoBackupTask: Task<Void, Never>?
    /// The quiet-time timer armed by `noteContactActivity`, so a run of edits becomes one upload.
    private var syncDebounceTask: Task<Void, Never>?
    /// The foreground ETag poll loop (see `startChangeWatcherIfNeeded`).
    private var changeWatcherTask: Task<Void, Never>?
    /// Bumped on every watcher start/stop so a superseded loop can never clear (or keep alive)
    /// its successor's `changeWatcherTask` slot.
    private var changeWatcherEpoch = 0
    /// The server ETag of the last contacts file this device merged or wrote, normalized. Persisted
    /// per wallet, so a change that lands while the app is in the background is caught by the first
    /// poll after it comes back, and a device never downloads its own write. nil = never seen.
    private var lastKnownBackupETag: String?
    /// In-memory mirror of the active wallet's persisted dirty flag.
    private var pendingSyncDirty = false
    /// Serializes automatic uploads and the watcher's merges; a skipped run leaves the dirty flag set.
    private var syncInFlight = false
    /// Contacts backups run one at a time on this device: two uploads of the same file at once get
    /// HTTP 423. A caller arriving while one runs waits for it, then merges on top of what it wrote.
    private var backupChain: Task<Void, Error>?
    /// The same for the Portfolio files.
    private var portfolioChain: Task<Void, Error>?
    /// The Portfolio files last read, so an unchanged file isn't downloaded again. A nil backup is a
    /// file that isn't a portfolio.
    private var portfolioFileCache: [String: (modified: Date?, size: Int64?, read: PortfolioFileRead)] = [:]

    private nonisolated static let autoBackupKey = "kachat_nextcloud_auto_backup"
    private nonisolated static let lastBackupKey = "kachat_nextcloud_last_address_book_backup"
    /// The Portfolio's dirty flag.
    private nonisolated static let pendingBackupKey = "kachat_nextcloud_pending_address_book_backup"
    private nonisolated static let lastAutoBackupKey = "kachat_nextcloud_last_auto_backup"
    /// The contacts' dirty flag: a contact changed after the last successful automatic upload.
    private nonisolated static let pendingSyncKey = "kachat_nextcloud_pending_sync"
    private nonisolated static let lastETagKey = "kachat_nextcloud_last_etag"
    /// This wallet's earlier plain contacts files have been merged into its contacts.
    private nonisolated static let plainContactsMergedKey = "kachat_nextcloud_plain_contacts_merged"
    /// This wallet's earlier single Portfolio file has been merged in.
    private nonisolated static let singlePortfolioMergedKey = "kachat_nextcloud_single_portfolio_merged"
    /// Every Nextcloud login (server and user, on this device) whose single Portfolio file, which
    /// had no owner inside, has been merged: it goes to one account, not every one on that login.
    private nonisolated static let singlePortfolioLoginsKey = "kachat_nextcloud_single_portfolio_logins"
    /// This wallet's Portfolio files are all encrypted now: a plain one isn't read any more.
    private nonisolated static let plainPortfoliosRetiredKey = "kachat_nextcloud_plain_portfolios_retired"
    /// Every key this service has ever stored per wallet - KaChat's chat-sync keys included, so a
    /// disconnect or account removal clears them too.
    private nonisolated static let storedKeys = [
        autoBackupKey, lastBackupKey, pendingBackupKey, lastAutoBackupKey, pendingSyncKey, lastETagKey,
        plainContactsMergedKey, singlePortfolioMergedKey, plainPortfoliosRetiredKey,
        "kachat_nextcloud_media_send", "kachat_nextcloud_auto_restore_done", "kachat_nextcloud_auto_sync_chosen",
        "kachat_nextcloud_talk_calls"
    ]
    /// Quiet time after a Portfolio change before the upload, so a burst of edits is one.
    private nonisolated static let backupDebounce: TimeInterval = 5
    /// Going in and out of the app quickly checks the server once.
    private nonisolated static let serverCheckInterval: TimeInterval = 60
    /// An on-background contacts sync with no change owed runs at most this often.
    nonisolated static let autoBackupMinInterval: TimeInterval = 3600
    /// If the last automatic sync is older than this (the app was force-quit for days), sync on
    /// becoming active instead of waiting for the next background.
    private nonisolated static let autoBackupCatchUpInterval: TimeInterval = 86_400
    /// Quiet time after the last contact change before the automatic merge upload runs.
    nonisolated static let syncDebounceInterval: TimeInterval = 15
    /// Floor between automatic contact uploads; a debounce firing earlier re-arms itself. Back Up
    /// Contacts Now isn't held to it.
    nonisolated static let autoSyncMinInterval: TimeInterval = 90
    nonisolated static let autoSyncMinIntervalExpensive: TimeInterval = 300
    /// How often the contacts file's ETag is polled while the app is active (a tiny Depth-0 PROPFIND).
    nonisolated static let changeWatchInterval: TimeInterval = 30
    nonisolated static let changeWatchIntervalExpensive: TimeInterval = 60
    /// Failed polls back off (x3 per consecutive failure, interval capped here) and snap back on
    /// the next success.
    private nonisolated static let changeWatchBackoffMax: TimeInterval = 60
    private nonisolated static let changeWatchBackoffFactorMax: Double = 12
    /// Pauses between PUT attempts while the file is locked - half a minute in all.
    private static let lockRetryDelays: [Double] = [1, 2, 4, 8, 15]
    /// Bounds for `discoverExistingBackupFolder` - a connect must not turn into a full crawl.
    private static let folderDiscoveryMaxFolders = 40
    private static let folderDiscoveryMaxDepth = 3

    static let backupFolderName = "KaChat"
    /// The contacts, encrypted, shared with KaChat. Its `kachat-backup.json` may share the folder,
    /// and KaPay never touches it.
    static let backupFileName = "kachat-contacts.json"
    /// The plain files the contacts were kept in before, newest first: "KaPay Contacts.json" until
    /// 2026-11-05, "KaPay Address Book.json" (the Address Book became Contacts, 2026-10-28) and the
    /// KaChat Wallet name (the app's name until 2026-10-27). Read once, never written.
    static let plainContactsFileNames = ["KaPay Contacts.json", "KaPay Address Book.json", "KaChat Wallet Address Book.json"]
    /// The one file the Portfolio used to be kept in, newest name first. Read once, never written.
    static let singlePortfolioFileNames = ["KaPay Portfolio.json", "KaChat Wallet Portfolio.json"]

    private init() {
        // No credential load here: state stays empty until WalletManager reports the active
        // wallet via setCurrentWallet (every login/switch path calls it). Backgrounding uploads
        // what's still owed, inside a background task so iOS gives the upload time to finish.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                // The flush takes over from any quiet-time timer: the dirty flag is persisted, and
                // autoBackupIfDue skips the hourly throttle while it is set.
                let service = NextcloudService.shared
                service.syncDebounceTask?.cancel()
                service.syncDebounceTask = nil
                service.stopChangeWatcher()
                service.scheduleAutoBackup()
                service.backUpPendingInBackground()
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                let service = NextcloudService.shared
                service.scheduleAutoBackup(minInterval: Self.autoBackupCatchUpInterval)
                service.startChangeWatcherIfNeeded()
                service.syncWithServerOnOpen()
            }
        }
    }

    // MARK: - Wallet scoping

    /// Points the service at `walletAddress`'s stored Nextcloud state, or clears everything for
    /// nil. Called by WalletManager on every wallet load, account switch, logout and delete.
    func setCurrentWallet(_ requestedAddress: String?) {
        isOffForTestnet = AppSettings.load().networkType == .testnet
        let walletAddress = isOffForTestnet ? nil : requestedAddress
        guard walletAddress != currentWalletAddress else { return }

        backupTask?.cancel()
        backupTask = nil
        autoBackupTask?.cancel()
        autoBackupTask = nil
        syncDebounceTask?.cancel()
        syncDebounceTask = nil
        stopChangeWatcher()
        portfolioFileCache = [:]
        needsReconnect = false
        currentWalletAddress = walletAddress
        currentWalletHashSuffix = walletAddress.map { KeychainService.walletHashSuffix($0) }

        guard let walletAddress else {
            account = nil
            autoBackupEnabled = false
            pendingBackup = false
            lastBackupAt = nil
            lastAutoSyncAt = nil
            pendingSyncDirty = false
            lastKnownBackupETag = nil
            return
        }

        migrateLegacyGlobalStateIfNeeded(for: walletAddress)
        if let data = try? KeychainService.shared.loadNextcloudCredentials(walletAddress: walletAddress) {
            account = try? JSONDecoder().decode(NextcloudAccount.self, from: data)
        } else {
            account = nil
        }
        let defaults = UserDefaults.standard
        autoBackupEnabled = scopedKey(Self.autoBackupKey).map { defaults.bool(forKey: $0) } ?? false
        pendingBackup = scopedKey(Self.pendingBackupKey).map { defaults.bool(forKey: $0) } ?? false
        let stamp = scopedKey(Self.lastBackupKey).map { defaults.double(forKey: $0) } ?? 0
        lastBackupAt = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        pendingSyncDirty = scopedKey(Self.pendingSyncKey).map { defaults.bool(forKey: $0) } ?? false
        let lastSync = scopedKey(Self.lastAutoBackupKey).map { defaults.double(forKey: $0) } ?? 0
        lastAutoSyncAt = lastSync > 0 ? Date(timeIntervalSince1970: lastSync) : nil
        lastKnownBackupETag = scopedKey(Self.lastETagKey).flatMap { defaults.string(forKey: $0) }
        lastServerCheck = nil
        // Watch the contacts file for other devices' writes. A new device's first poll sees an ETag
        // it doesn't know, so this is also how it gets the contacts.
        startChangeWatcherIfNeeded()
        syncWithServerOnOpen()
        // Not on the encrypted file yet: the first sync brings the plain file in and writes it.
        if !plainContactsMerged { noteContactActivity() }
    }

    /// Settings' Automatic Sync toggle.
    func setAutoBackupEnabled(_ enabled: Bool) {
        if let key = scopedKey(Self.autoBackupKey) {
            UserDefaults.standard.set(enabled, forKey: key)
        }
        autoBackupEnabled = enabled
        if enabled {
            setPendingBackup(true)
            scheduleBackup(after: 0)
            noteContactActivity()
            startChangeWatcherIfNeeded()
        } else {
            backupTask?.cancel()
            backupTask = nil
            syncDebounceTask?.cancel()
            syncDebounceTask = nil
            stopChangeWatcher()
        }
    }

    /// Revokes the app password the user made for KaPay on their Nextcloud, so
    /// disconnecting or deleting the wallet leaves nothing that can still log in. Best effort:
    /// the local copy is deleted whatever the server says. `captured` is for a caller that clears the
    /// account before this runs.
    func revokeAppPassword(using captured: NextcloudAccount? = nil) async {
        guard let account = captured ?? account, let server = account.serverURL else { return }
        var request = URLRequest(url: server.appendingPathComponent("ocs/v2.php/core/apppassword"))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 8 // best effort, and an account removal waits on it
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        applyAuth(&request, account: account)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            AppLog.log("%@", "[Nextcloud] App password revoke answered HTTP \(status)")
        } catch {
            AppLog.log("%@", "[Nextcloud] App password revoke failed: \(error.localizedDescription)")
        }
    }

    /// Revokes the app password a wallet's stored Nextcloud login holds: for removing an account,
    /// signed in or not, before `purgeStoredState` deletes the login.
    func revokeStoredAppPassword(forWalletAddress walletAddress: String) async {
        guard let data = try? KeychainService.shared.loadNextcloudCredentials(walletAddress: walletAddress),
              let stored = try? JSONDecoder().decode(NextcloudAccount.self, from: data) else { return }
        await revokeAppPassword(using: stored)
    }

    /// Deletes a wallet's stored Nextcloud login and settings outright - used when that account
    /// is removed from this device entirely. Storage only; the in-memory state is cleared by the
    /// setCurrentWallet(nil) that always follows.
    func purgeStoredState(forWalletAddress walletAddress: String) {
        try? KeychainService.shared.deleteNextcloudCredentials(walletAddress: walletAddress)
        let suffix = KeychainService.walletHashSuffix(walletAddress)
        for base in Self.storedKeys {
            UserDefaults.standard.removeObject(forKey: "\(base)_\(suffix)")
        }
    }

    /// The active wallet's UserDefaults key for `base`, or nil when signed out (in which case
    /// nothing is read or written).
    private func scopedKey(_ base: String) -> String? {
        guard let suffix = currentWalletHashSuffix else { return nil }
        return "\(base)_\(suffix)"
    }

    /// One-time migration off the pre-per-wallet storage: the single global Keychain blob moves
    /// to the active wallet's scoped entry, then the global entry is deleted so no other account
    /// ever sees it again.
    private func migrateLegacyGlobalStateIfNeeded(for walletAddress: String) {
        guard let legacyBlob = try? KeychainService.shared.loadLegacyNextcloudCredentials() else { return }
        let hasScoped = (try? KeychainService.shared.loadNextcloudCredentials(walletAddress: walletAddress)) != nil
        if !hasScoped {
            try? KeychainService.shared.saveNextcloudCredentials(legacyBlob, walletAddress: walletAddress)
        }
        try? KeychainService.shared.deleteLegacyNextcloudCredentials()
        AppLog.log("%@", "[Nextcloud] Migrated the global Nextcloud login to the active wallet's per-account storage")
    }

    // MARK: - Automatic Portfolio backup

    /// The Portfolio changed (PortfolioManager and PortfolioViewModel call this on every save): with
    /// Automatic Sync on, it uploads a few seconds after the changes settle.
    func notePortfolioChanged() {
        portfolioChanges &+= 1
        guard autoBackupEnabled, isConnected, !needsReconnect else { return }
        setPendingBackup(true)
        scheduleBackup(after: Self.backupDebounce)
    }

    /// Counts Portfolio changes, so a backup clears the pending flag only if none came in after it
    /// read what to upload.
    private var portfolioChanges = 0

    private func setPendingBackup(_ pending: Bool) {
        pendingBackup = pending
        if let key = scopedKey(Self.pendingBackupKey) {
            UserDefaults.standard.set(pending, forKey: key)
        }
    }

    private func scheduleBackup(after delay: TimeInterval) {
        guard autoBackupEnabled, isConnected, !needsReconnect, let walletAtStart = currentWalletAddress else { return }
        backupTask?.cancel()
        backupTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self, self.currentWalletAddress == walletAtStart else { return }
            do {
                try await self.runPortfolioBackup()
            } catch {
                // Kept pending: the next change, background or launch retries.
                self.noteRejectedLogin(error)
                AppLog.log("%@", "[Nextcloud] Automatic Portfolio backup failed: \(error.localizedDescription)")
            }
        }
    }

    /// The app opened or came back: with Automatic Sync on, brings in another device's Portfolio
    /// changes. A change still owed is uploaded instead, which merges the server's copy in first.
    private func syncWithServerOnOpen() {
        guard autoBackupEnabled, isConnected, !needsReconnect, let walletAtStart = currentWalletAddress else { return }
        if let lastServerCheck, Date().timeIntervalSince(lastServerCheck) < Self.serverCheckInterval { return }
        lastServerCheck = Date()
        if pendingBackup {
            scheduleBackup(after: Self.backupDebounce)
            return
        }
        backupTask?.cancel()
        backupTask = Task { [weak self] in
            // after the other services have switched to this account
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self, self.currentWalletAddress == walletAtStart else { return }
            do {
                _ = try await self.mergePortfoliosFromServer(walletAtStart: walletAtStart)
            } catch {
                self.noteRejectedLogin(error)
                AppLog.log("%@", "[Nextcloud] Checking the server failed: \(error.localizedDescription)")
            }
        }
    }

    /// Going to the background with a Portfolio change still owed: upload it inside a background task.
    private func backUpPendingInBackground() {
        guard autoBackupEnabled, isConnected, !needsReconnect, pendingBackup else { return }
        var taskId: UIBackgroundTaskIdentifier = .invalid
        taskId = UIApplication.shared.beginBackgroundTask(withName: "kachat.wallet.backup") {
            UIApplication.shared.endBackgroundTask(taskId)
            taskId = .invalid
        }
        Task { @MainActor in
            defer {
                if taskId != .invalid { UIApplication.shared.endBackgroundTask(taskId) }
            }
            try? await self.runPortfolioBackup()
        }
    }

    // MARK: - Automatic contacts sync

    /// A contact changed. Marks the active wallet's contacts dirty (persisted, so a kill can't lose
    /// the fact that an upload is owed) and restarts the quiet-time timer, so a run of edits becomes
    /// one merge upload. Cheap and safe to call at any rate.
    func noteContactActivity() {
        guard autoBackupEnabled, isConnected, !needsReconnect, let wallet = currentWalletAddress else { return }
        if !pendingSyncDirty {
            setPendingSyncDirty(true, walletAddress: wallet)
        }
        armSyncDebounce(for: wallet, after: Self.syncDebounceInterval)
    }

    /// Runs `autoBackupTask`, so `setCurrentWallet` can cancel it mid-flight on an account switch.
    private func scheduleAutoBackup(minInterval: TimeInterval = NextcloudService.autoBackupMinInterval) {
        autoBackupTask?.cancel()
        autoBackupTask = Task { [weak self] in
            await self?.autoBackupIfDue(minInterval: minInterval)
        }
    }

    /// Syncs the contacts when at least `minInterval` past the last time (hourly on background, daily
    /// on the launch catch-up), or when the dirty flag says an upload is still owed.
    private func autoBackupIfDue(minInterval: TimeInterval) async {
        guard autoBackupEnabled, isConnected, !needsReconnect, let walletAtStart = currentWalletAddress else { return }
        let last = lastAutoSyncAt?.timeIntervalSince1970 ?? 0
        guard Date().timeIntervalSince1970 - last >= minInterval || pendingSyncDirty else { return }
        await performAutomaticSync(walletAtStart: walletAtStart)
    }

    private func armSyncDebounce(for wallet: String, after delay: TimeInterval) {
        syncDebounceTask?.cancel()
        syncDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.pendingSyncDirty else { return }
            await self.performAutomaticSync(walletAtStart: wallet)
        }
    }

    /// The one automatic upload path. The dirty flag is cleared BEFORE building - a contact changed
    /// during the upload re-marks it, so nothing is lost - and re-marked on any failure so a later
    /// trigger retries.
    private func performAutomaticSync(walletAtStart: String) async {
        guard currentWalletAddress == walletAtStart, autoBackupEnabled, isConnected else { return }
        if let last = lastAutoSyncAt {
            let floorInterval = NetworkEpochMonitor.shared.isExpensivePath
                ? Self.autoSyncMinIntervalExpensive
                : Self.autoSyncMinInterval
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < floorInterval {
                armSyncDebounce(for: walletAtStart, after: floorInterval - elapsed)
                return
            }
        }
        guard !syncInFlight else {
            armSyncDebounce(for: walletAtStart, after: 30)
            return
        }
        syncInFlight = true
        defer { syncInFlight = false }

        setPendingSyncDirty(false, walletAddress: walletAtStart)

        var taskId: UIBackgroundTaskIdentifier = .invalid
        taskId = UIApplication.shared.beginBackgroundTask(withName: "kachat.wallet.contacts") {
            UIApplication.shared.endBackgroundTask(taskId)
            taskId = .invalid
        }
        defer { if taskId != .invalid { UIApplication.shared.endBackgroundTask(taskId) } }

        do {
            try await runContactsBackup()
            guard !Task.isCancelled, currentWalletAddress == walletAtStart else { return }
            let now = Date()
            if let key = scopedKey(Self.lastAutoBackupKey) {
                UserDefaults.standard.set(now.timeIntervalSince1970, forKey: key)
            }
            lastAutoSyncAt = now
            AppLog.log("%@", "[Nextcloud] Automatic sync merged the contacts")
        } catch {
            setPendingSyncDirty(true, walletAddress: walletAtStart)
            noteRejectedLogin(error)
            AppLog.log("%@", "[Nextcloud] Automatic sync upload failed (a later trigger retries): \(error.localizedDescription)")
        }
    }

    /// A 401 won't fix itself, and repeated failed logins can trip the server's brute-force
    /// protection: automatic work stops and Settings asks for a new connection.
    private func noteRejectedLogin(_ error: Error) {
        guard let nextcloud = error as? NextcloudError, case .badCredentials = nextcloud else { return }
        needsReconnect = true
        syncDebounceTask?.cancel()
        syncDebounceTask = nil
        stopChangeWatcher()
        AppLog.log("%@", "[Nextcloud] The server refused this login; automatic sync stops until it reconnects")
    }

    /// Writes the dirty flag against a snapshotted wallet's key (never the current one - the wallet
    /// may have switched mid-flight).
    private func setPendingSyncDirty(_ dirty: Bool, walletAddress: String) {
        let key = "\(Self.pendingSyncKey)_\(KeychainService.walletHashSuffix(walletAddress))"
        UserDefaults.standard.set(dirty, forKey: key)
        if currentWalletAddress == walletAddress {
            pendingSyncDirty = dirty
        }
    }

    // MARK: - Change watcher (foreground pull of other devices' contact changes)

    /// Starts the foreground ETag watcher when Automatic Sync is on, a server is connected, a wallet
    /// is active and the app isn't in the background. A no-op while one is already running.
    func startChangeWatcherIfNeeded() {
        guard changeWatcherTask == nil, !needsReconnect else { return }
        guard autoBackupEnabled, isConnected, let wallet = currentWalletAddress,
              UIApplication.shared.applicationState != .background else { return }
        changeWatcherEpoch += 1
        let epoch = changeWatcherEpoch
        changeWatcherTask = Task { [weak self] in
            await self?.runChangeWatcher(walletAtStart: wallet, epoch: epoch)
        }
    }

    /// Stops the watcher: on background, disconnect, wallet switch and toggle-off. The epoch bump
    /// keeps a mid-await loop iteration from outliving the stop.
    func stopChangeWatcher() {
        changeWatcherEpoch += 1
        changeWatcherTask?.cancel()
        changeWatcherTask = nil
    }

    private var currentChangeWatchInterval: TimeInterval {
        NetworkEpochMonitor.shared.isExpensivePath ? Self.changeWatchIntervalExpensive : Self.changeWatchInterval
    }

    /// The poll loop. A failed poll backs off and snaps back on the next success.
    private func runChangeWatcher(walletAtStart: String, epoch: Int) async {
        var backoffFactor: Double = 1
        while !Task.isCancelled {
            let interval = min(currentChangeWatchInterval * backoffFactor, Self.changeWatchBackoffMax)
            await sleepInterruptibly(seconds: interval, epoch: epoch)
            guard !Task.isCancelled, changeWatcherEpoch == epoch else { break }
            guard currentWalletAddress == walletAtStart, autoBackupEnabled, isConnected else { break }
            do {
                try await checkForRemoteChangeAndImport(walletAtStart: walletAtStart)
                backoffFactor = 1
            } catch {
                noteRejectedLogin(error)
                backoffFactor = min(backoffFactor * 3, Self.changeWatchBackoffFactorMax)
            }
        }
        if changeWatcherEpoch == epoch {
            changeWatcherTask = nil
        }
    }

    /// Sleeps up to `seconds`, returning early when the watcher is cancelled or superseded.
    private func sleepInterruptibly(seconds: TimeInterval, epoch: Int) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !Task.isCancelled, changeWatcherEpoch == epoch {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(min(0.5, remaining) * 1_000_000_000))
        }
    }

    /// One poll: fetch the ETag, and merge the file if it changed. Skips silently (leaving the
    /// last-known ETag alone, so the next poll retries) while a sync is running. Throws on network
    /// trouble so the watcher backs off.
    private func checkForRemoteChangeAndImport(walletAtStart: String) async throws {
        // ETag BEFORE the download: if the file is replaced between the two requests, the stored
        // ETag is the older one and the next poll simply merges again, which changes nothing.
        guard let etag = try await fetchBackupETag() else { return } // no backup yet
        guard etag != lastKnownBackupETag else { return }
        guard currentWalletAddress == walletAtStart, autoBackupEnabled, isConnected, !syncInFlight else { return }
        syncInFlight = true
        defer { syncInFlight = false }

        let raw = try await downloadBackup()
        guard !Task.isCancelled, currentWalletAddress == walletAtStart else { return }
        let book = AddressBookManager.shared
        let serverIsBehind: Bool
        do {
            guard BackupEnvelope.parse(raw) != nil else { throw NextcloudError.malformedResponse }
            let plaintext = try await BackupEnvelope.decryptIfEnvelopedDetached(raw, key: backupEncryptionKey(), walletAddress: walletAtStart)
            guard !Task.isCancelled, currentWalletAddress == walletAtStart, book.holdsWallet(walletAtStart) else { return }
            serverIsBehind = try book.mergeBackup(plaintext).serverIsBehind
        } catch {
            // A file this wallet can't read: record the ETag so it isn't downloaded every poll; a
            // future replacement changes the ETag and gets a fresh look.
            setLastKnownBackupETag(etag, walletAddress: walletAtStart)
            AppLog.log("%@", "[Nextcloud] Change watcher skipped an unreadable contacts file: \(error.localizedDescription)")
            return
        }
        setLastKnownBackupETag(etag, walletAddress: walletAtStart)
        if serverIsBehind { noteContactActivity() }
        AppLog.log("%@", "[Nextcloud] Change watcher merged another device's contacts")
    }

    /// The contacts file's current ETag via a Depth-0 PROPFIND requesting only `getetag`.
    /// nil = no file yet (404); throws on any other failure.
    private func fetchBackupETag() async throws -> String? {
        guard let account, let server = account.serverURL else { throw NextcloudError.badCredentials }
        var url = server
        for part in "remote.php/dav/files/\(account.username)/\(backupFolderPath)/\(Self.backupFileName)".split(separator: "/") {
            url.appendPathComponent(String(part))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        applyAuth(&request, account: account)
        request.httpBody = Data("""
        <?xml version="1.0"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:getetag/></d:prop></d:propfind>
        """.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NextcloudError.malformedResponse }
        if http.statusCode == 401 { throw NextcloudError.badCredentials }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 207 else { throw NextcloudError.httpError(http.statusCode) }
        guard let etag = Self.parseETagFromMultistatus(data) else { throw NextcloudError.malformedResponse }
        return etag
    }

    /// Pulls the getetag value out of a Depth-0 multistatus without a full XML pass - servers
    /// vary the namespace prefix (`d:`, `D:`, none), so any tag whose name contains "getetag"
    /// matches.
    nonisolated static func parseETagFromMultistatus(_ data: Data) -> String? {
        guard let xml = String(data: data, encoding: .utf8),
              let regex = try? NSRegularExpression(
                pattern: "<[^<>]*getetag[^<>]*>([^<]+)</[^<>]*getetag[^<>]*>",
                options: [.caseInsensitive]
              ) else { return nil }
        let range = NSRange(xml.startIndex..., in: xml)
        guard let match = regex.firstMatch(in: xml, range: range),
              let valueRange = Range(match.range(at: 1), in: xml) else { return nil }
        let raw = String(xml[valueRange])
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
        let normalized = normalizedETag(raw)
        return normalized.isEmpty ? nil : normalized
    }

    /// Strips the weak-validator prefix and surrounding quotes so a PUT response header ETag
    /// and a PROPFIND getetag for the same content compare equal.
    nonisolated static func normalizedETag(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("W/") { value.removeFirst(2) }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private func setLastKnownBackupETag(_ etag: String?, walletAddress: String) {
        let key = "\(Self.lastETagKey)_\(KeychainService.walletHashSuffix(walletAddress))"
        if let etag {
            UserDefaults.standard.set(etag, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        if currentWalletAddress == walletAddress {
            lastKnownBackupETag = etag
        }
    }

    // MARK: - Contacts backup (WebDAV PUT/GET of one encrypted file)

    /// Back Up Contacts Now and the automatic sync both come here, one at a time.
    func runContactsBackup() async throws {
        let previous = backupChain
        let task = Task { [weak self] in
            _ = try? await previous?.value
            guard let self else { throw CancellationError() }
            try await self.performContactsBackup()
        }
        backupChain = task
        defer { if backupChain == task { backupChain = nil } }
        try await task.value
    }

    /// One read, merge, write of the contacts file. Newest edit or deletion wins per address, so no
    /// device can undo another's newer change. Written only when the file is missing something this
    /// device has. Any file that can't be read as this account's contacts throws before the PUT,
    /// except this account's own file that fails to decrypt (cut off at rest, say): that's replaced
    /// in place, since Nextcloud's version history keeps the old content. The active wallet is
    /// re-checked around every await so a mid-flight account switch aborts.
    private func performContactsBackup() async throws {
        let walletAtStart = currentWalletAddress
        // Key up front: writers ALWAYS encrypt, so without the key the backup is skipped rather than
        // uploaded readable.
        guard let walletAddress = walletAtStart, let key = backupEncryptionKey() else {
            throw BackupEnvelope.EnvelopeError.keyUnavailable
        }
        await moveToEncryptedContactsIfNeeded(walletAtStart: walletAddress)
        guard !Task.isCancelled, currentWalletAddress == walletAtStart else { throw CancellationError() }

        var serverCopy: Data?
        var replaceUnreadable = false
        do {
            let raw = try await downloadBackup()
            guard BackupEnvelope.parse(raw) != nil else { throw NextcloudError.malformedResponse }
            do {
                serverCopy = try await BackupEnvelope.decryptIfEnvelopedDetached(raw, key: key, walletAddress: walletAddress)
            } catch {
                guard BackupEnvelope.isOwnUnreadableEnvelope(raw, walletAddress: walletAddress) else { throw error }
                AppLog.log("%@", "[Nextcloud] This account's contacts file can't be decrypted; replacing it in place")
                replaceUnreadable = true
            }
        } catch NextcloudError.backupNotFound {
            // Nothing there yet: the one other case that writes without merging.
        }
        guard !Task.isCancelled, currentWalletAddress == walletAtStart else { throw CancellationError() }

        let book = AddressBookManager.shared
        guard book.holdsWallet(walletAddress) else { throw CancellationError() }
        var serverIsBehind = replaceUnreadable || book.hasBackupData
        if let serverCopy {
            serverIsBehind = try book.mergeBackup(serverCopy).serverIsBehind
        }
        guard serverIsBehind else {
            setLastKnownBackupETag((try? await fetchBackupETag()) ?? nil, walletAddress: walletAddress)
            stampBackup()
            return
        }

        let body = try await BackupEnvelope.encryptDetached(
            try book.exportData(includingDeleted: true), key: key, walletAddress: walletAddress
        )
        guard !Task.isCancelled, currentWalletAddress == walletAtStart else { throw CancellationError() }
        var newETag = try await uploadBackup(body)
        // A relay that cuts a large PUT can leave a short file, which the next sync would read as
        // damaged. Say so plainly instead of looping. Only our own write counts: another device may
        // have replaced the file in between.
        if let storedSize = await contactsFileInfo()?.size, storedSize != Int64(body.count) {
            let currentETag = (try? await fetchBackupETag()) ?? nil
            if newETag == nil || currentETag == newETag {
                throw NextcloudError.uploadCutOff(sent: body.count, stored: storedSize)
            }
        }
        if newETag == nil {
            // Some proxies strip the PUT response's ETag header.
            newETag = (try? await fetchBackupETag()) ?? nil
        }
        // Remember our own write's ETag so the watcher never downloads it back.
        guard currentWalletAddress == walletAtStart else { return }
        setLastKnownBackupETag(newETag, walletAddress: walletAddress)
        stampBackup()
        AppLog.log("%@", "[Nextcloud] Contacts backed up")
    }

    private func stampBackup() {
        needsReconnect = false
        lastBackupAt = Date()
        if let key = scopedKey(Self.lastBackupKey) {
            UserDefaults.standard.set(lastBackupAt?.timeIntervalSince1970 ?? 0, forKey: key)
        }
    }

    /// The active wallet's envelope key, from the chatting address's raw private key, as in KaChat.
    fileprivate func backupEncryptionKey() -> SymmetricKey? {
        guard let identityKey = WalletManager.shared.getPrivateKey() else { return nil }
        return BackupEnvelope.key(identityPrivateKey: identityKey)
    }

    /// Uploads the contacts to `<backup folder>/kachat-contacts.json`, creating the folder chain
    /// first. Overwrites in place: private so every caller goes through `runContactsBackup` and the
    /// body is a merge, never a replacement. Returns the uploaded file's ETag when the server sent
    /// one (`OC-ETag` first - Nextcloud's canonical header - then `ETag`), normalized.
    @discardableResult
    private func uploadBackup(_ data: Data) async throws -> String? {
        guard let account, let server = account.serverURL else { throw NextcloudError.badCredentials }
        var folderURL = server.appendingPathComponent("remote.php/dav/files/\(account.username)")
        // Level by level: MKCOL is not recursive, and 405 means the level already exists.
        for part in backupFolderPath.split(separator: "/") {
            folderURL.appendPathComponent(String(part))
            var mkcol = URLRequest(url: folderURL)
            mkcol.httpMethod = "MKCOL"
            applyAuth(&mkcol, account: account)
            let (_, mkcolResponse) = try await URLSession.shared.data(for: mkcol)
            if let http = mkcolResponse as? HTTPURLResponse {
                if http.statusCode == 401 { throw NextcloudError.badCredentials }
                guard (200..<300).contains(http.statusCode) || http.statusCode == 405 else {
                    throw NextcloudError.httpError(http.statusCode)
                }
            }
        }

        var put = URLRequest(url: folderURL.appendingPathComponent(Self.backupFileName))
        put.httpMethod = "PUT"
        put.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&put, account: account)
        put.httpBody = data
        var attempt = 0
        while true {
            let (_, putResponse) = try await URLSession.shared.data(for: put)
            guard let http = putResponse as? HTTPURLResponse else { throw NextcloudError.malformedResponse }
            if http.statusCode == 401 { throw NextcloudError.badCredentials }
            if http.statusCode == 423 {
                // Nextcloud's file lock: another device is reading or writing the file, and a lock
                // held by a live request clears the moment that request ends. Wait it out a few
                // times before calling it stale.
                guard attempt < Self.lockRetryDelays.count else { throw NextcloudError.backupLocked }
                AppLog.log("%@", "[Nextcloud] Backup file locked (HTTP 423), retrying in \(Self.lockRetryDelays[attempt])s")
                try await Task.sleep(nanoseconds: UInt64(Self.lockRetryDelays[attempt] * 1_000_000_000))
                attempt += 1
                continue
            }
            guard (200..<300).contains(http.statusCode) else { throw NextcloudError.httpError(http.statusCode) }
            let rawETag = http.value(forHTTPHeaderField: "OC-ETag") ?? http.value(forHTTPHeaderField: "ETag")
            return rawETag.map { Self.normalizedETag($0) }.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// Downloads the contacts file's bytes. 404 -> `backupNotFound`.
    private func downloadBackup() async throws -> Data {
        guard let request = authenticatedFileRequest(for: "\(backupFolderPath)/\(Self.backupFileName)") else {
            throw NextcloudError.badCredentials
        }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw NextcloudError.malformedResponse }
        if http.statusCode == 401 { throw NextcloudError.badCredentials }
        if http.statusCode == 404 { throw NextcloudError.backupNotFound }
        guard (200..<300).contains(http.statusCode) else {
            throw NextcloudError.httpError(http.statusCode)
        }
        // A WebDAV GET of this file is never legitimately HTML; a 2xx HTML body is a reverse-proxy,
        // login, or maintenance page standing in for the server.
        if http.mimeType?.lowercased().contains("html") == true {
            throw NextcloudError.malformedResponse
        }
        let expected: Int64? = http.expectedContentLength > 0 ? http.expectedContentLength : nil
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        guard !data.isEmpty else { throw NextcloudError.httpError(http.statusCode) }
        // A connection closed gracefully mid-body just ends the sequence, so short of the advertised
        // length has to be caught here. A short file must never read as a damaged one and be
        // overwritten.
        if let expected, Int64(data.count) < expected {
            throw NextcloudError.truncatedDownload(received: Int64(data.count), expected: expected)
        }
        return data
    }

    /// The contacts file's server-side metadata (nil = no file yet).
    private func contactsFileInfo() async -> NextcloudFile? {
        guard let listing = try? await listFolder(backupFolderPath) else { return nil }
        return listing.first { $0.name == Self.backupFileName && !$0.isDirectory }
    }

    // MARK: - Moving off the plain contacts files

    private var plainContactsMerged: Bool {
        scopedKey(Self.plainContactsMergedKey).map { UserDefaults.standard.bool(forKey: $0) } ?? true
    }

    /// Once per wallet: finds the folder KaChat's contacts file is in, and merges the plain files the
    /// contacts used to be kept in, so nothing in them is lost. The plain files stay where they are,
    /// and aren't read again. A failure leaves this to run again with the next backup; it never stops one.
    private func moveToEncryptedContactsIfNeeded(walletAtStart: String) async {
        guard !plainContactsMerged else { return }
        do {
            if account?.backupFolder == nil, let found = await discoverExistingBackupFolder() {
                guard currentWalletAddress == walletAtStart else { return }
                setBackupFolder(found)
            }
            // Once this account's encrypted file is there, a plain file proves nothing: anyone who
            // can write to the folder could have put it there, and merging it would add their
            // address under a friend's name.
            if let key = backupEncryptionKey(),
               let encrypted = try? await downloadFile("\(backupFolderPath)/\(Self.backupFileName)", maxBytes: 50_000_000),
               BackupEnvelope.parse(encrypted) != nil,
               (try? await BackupEnvelope.decryptIfEnvelopedDetached(encrypted, key: key, walletAddress: walletAtStart)) != nil {
                guard currentWalletAddress == walletAtStart, let merged = scopedKey(Self.plainContactsMergedKey) else { return }
                UserDefaults.standard.set(true, forKey: merged)
                return
            }
            // Every name, not just the newest: a device on an older build may have kept writing an
            // older one. Newest edit or deletion wins, so an old file can't undo a newer change.
            for name in Self.plainContactsFileNames {
                guard let plain = try await downloadBackupFile(name, legacy: []) else { continue }
                guard currentWalletAddress == walletAtStart, AddressBookManager.shared.holdsWallet(walletAtStart) else { return }
                try AddressBookManager.shared.mergeBackup(plain)
            }
            guard currentWalletAddress == walletAtStart, let key = scopedKey(Self.plainContactsMergedKey) else { return }
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            AppLog.log("%@", "[Nextcloud] Merging the earlier contacts file failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Portfolio backup

    /// One account's Portfolio file found in the backup folder.
    private struct ServerPortfolioFile {
        let file: NextcloudFile
        let backup: PortfolioBackupFile
        /// Written before the files were encrypted: the next backup rewrites it.
        let isPlain: Bool
    }

    /// What one file in the backup folder turned out to be.
    private enum PortfolioFileRead {
        case portfolio(PortfolioBackupFile, isPlain: Bool)
        /// This account's own encrypted file, damaged: its name may be written over.
        case ownUnreadable
        case other
    }

    /// Decrypts (or, for an earlier plain file, just decodes) one downloaded file.
    private static func readPortfolioFile(_ data: Data, key: SymmetricKey, walletAddress: String) async -> PortfolioFileRead {
        let isPlain = BackupEnvelope.parse(data) == nil
        let plaintext: Data
        if isPlain {
            plaintext = data
        } else {
            do {
                plaintext = try await BackupEnvelope.decryptIfEnvelopedDetached(data, key: key, walletAddress: walletAddress)
            } catch {
                return BackupEnvelope.isOwnUnreadableEnvelope(data, walletAddress: walletAddress) ? .ownUnreadable : .other
            }
        }
        guard let backup = try? PortfolioBackupFile.decode(plaintext) else { return .other }
        return .portfolio(backup, isPlain: isPlain)
    }

    /// What the backup folder holds, as far as the Portfolio is concerned.
    private struct ServerPortfolios {
        var own: [ServerPortfolioFile] = []
        /// Lowercased names of everything else there: another account's portfolio, or any other
        /// file. A portfolio's file goes beside these, never over them.
        var taken: Set<String> = []
    }

    private static func isPortfolioFileCandidate(_ file: NextcloudFile) -> Bool {
        let name = file.name.lowercased()
        guard !file.isDirectory, name.hasSuffix(".json"), (file.size ?? 0) <= 50_000_000 else { return false }
        // Contacts and chat files, which can be large and are never portfolios.
        let notPortfolios = ([backupFileName, "kachat-backup.json"] + plainContactsFileNames).map { $0.lowercased() }
        return !notPortfolios.contains(name) && !name.hasPrefix("kapay contacts ")
    }

    /// Reads the backup folder. Any file that can't be downloaded throws, so nothing is written or
    /// deleted on a partial view of what's there, and so does a missing key: without it this
    /// account's files can't be told from anyone else's.
    private func readServerPortfolios(walletAtStart: String) async throws -> ServerPortfolios {
        guard let key = backupEncryptionKey() else { throw BackupEnvelope.EnvelopeError.keyUnavailable }
        let listing: [NextcloudFile]
        do {
            listing = try await listFolder(backupFolderPath)
        } catch NextcloudError.httpError(404) {
            return ServerPortfolios()
        }
        var result = ServerPortfolios()
        for file in listing where !file.isDirectory {
            var read = PortfolioFileRead.other
            if Self.isPortfolioFileCandidate(file) {
                if file.modified != nil, let cached = portfolioFileCache[file.path],
                   cached.modified == file.modified, cached.size == file.size {
                    read = cached.read
                } else {
                    let data = try await downloadFile(file.path, maxBytes: 50_000_000)
                    read = await Self.readPortfolioFile(data, key: key, walletAddress: walletAtStart)
                    // an account switch meanwhile cleared the cache: what this account read isn't the next one's
                    guard currentWalletAddress == walletAtStart else { throw CancellationError() }
                    portfolioFileCache[file.path] = (file.modified, file.size, read)
                }
            }
            // A plain file carries no proof of who wrote it (the owner inside is a public address),
            // so plain files count only until this account's own have been encrypted.
            let plainRetired = scopedKey(Self.plainPortfoliosRetiredKey).map { UserDefaults.standard.bool(forKey: $0) } ?? true
            switch read {
            case .portfolio(let backup, let isPlain)
                where backup.type == PortfolioBackupFile.kind && backup.version <= PortfolioBackupFile.currentVersion
                    && backup.walletAddress?.lowercased() == walletAtStart.lowercased()
                    && !(isPlain && plainRetired):
                result.own.append(ServerPortfolioFile(file: file, backup: backup, isPlain: isPlain))
            case .ownUnreadable:
                // ours, so its name stays free for this account's portfolio of that name
                AppLog.log("%@", "[Nextcloud] A Portfolio file of this account can't be decrypted: \(file.name)")
            default:
                result.taken.insert(file.name.lowercased())
            }
        }
        // Once any of this account's files is encrypted, a plain one proves nothing (its owner is a
        // public address): it may have been planted, so it is left alone like anyone else's.
        if result.own.contains(where: { !$0.isPlain }) {
            for found in result.own where found.isPlain { result.taken.insert(found.file.name.lowercased()) }
            result.own.removeAll(where: \.isPlain)
        }
        return result
    }

    /// Once per account: merges the one file the Portfolio used to be kept in. It stays where it is
    /// and isn't read again. A failure leaves this to run again with the next backup. Returns whether
    /// it changed anything here.
    private func mergeSinglePortfolioFileIfNeeded(walletAtStart: String) async -> Bool {
        guard let key = scopedKey(Self.singlePortfolioMergedKey), !UserDefaults.standard.bool(forKey: key) else { return false }
        do {
            var changed = false
            if let data = try await downloadBackupFile(Self.singlePortfolioFileNames[0], legacy: Array(Self.singlePortfolioFileNames.dropFirst())) {
                guard currentWalletAddress == walletAtStart, let account else { return false }
                let file = try PortfolioBackupFile.decode(data)
                // One file per Nextcloud login: with an owner inside, only that account's; without
                // one, only the first account here to connect with that login takes it, so a second
                // account on the same login doesn't take the first one's portfolios as its own.
                let login = "\(account.serverURLString.lowercased())|\(account.username.lowercased())"
                var logins = Set(UserDefaults.standard.stringArray(forKey: Self.singlePortfolioLoginsKey) ?? [])
                let isOurs = file.walletAddress.map { $0.lowercased() == walletAtStart.lowercased() } ?? !logins.contains(login)
                if isOurs {
                    changed = PortfolioViewModel.shared.importFromArchive(file.sync)
                    logins.insert(login)
                    UserDefaults.standard.set(Array(logins), forKey: Self.singlePortfolioLoginsKey)
                }
            }
            guard currentWalletAddress == walletAtStart else { return changed }
            UserDefaults.standard.set(true, forKey: key)
            return changed
        } catch {
            AppLog.log("%@", "[Nextcloud] Merging the earlier Portfolio file failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Merges every Portfolio file of this account into this device, without uploading.
    private func mergePortfoliosFromServer(walletAtStart: String) async throws -> (changed: Bool, server: ServerPortfolios) {
        var changed = await mergeSinglePortfolioFileIfNeeded(walletAtStart: walletAtStart)
        let server = try await readServerPortfolios(walletAtStart: walletAtStart)
        guard !Task.isCancelled, currentWalletAddress == walletAtStart else { throw CancellationError() }
        if !server.own.isEmpty {
            let merged = PortfolioViewModel.shared.importFromArchive(PortfolioSync.merge(server.own.map(\.backup.sync)))
            changed = changed || merged
        }
        return (changed, server)
    }

    /// Each portfolio's file name: its own name, with a number only where another file already has
    /// that name. The same portfolios get the same names on every device.
    private static func portfolioFileNames(for portfolios: [Portfolio], taken: Set<String>) -> [UUID: String] {
        var used = taken
        var names: [UUID: String] = [:]
        for portfolio in portfolios.sorted(by: { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }) {
            let trimmed = portfolio.name.trimmingCharacters(in: .whitespacesAndNewlines)
            var base = trimmed.isEmpty ? "Portfolio" : sanitizedFilename(String(trimmed.prefix(60)), keepSpaces: true)
            // A name no number can make allowed ("KaPay Contacts …") uses "Portfolio", as KaChat
            // Desktop does, so both apps give it the same file.
            if !isPortfolioNameAllowed("\(base) 2.json") { base = "Portfolio" }
            var candidate = "\(base).json"
            var number = 2
            while used.contains(candidate.lowercased()) || !isPortfolioNameAllowed(candidate) {
                candidate = "\(base) \(number).json"
                number += 1
            }
            used.insert(candidate.lowercased())
            names[portfolio.id] = candidate
        }
        return names
    }

    private static func isPortfolioNameAllowed(_ name: String) -> Bool {
        isPortfolioFileCandidate(NextcloudFile(path: name, name: name, isDirectory: false, contentType: nil, size: nil, modified: nil))
    }

    /// Back Up Portfolio Now and the automatic backup both come here, one at a time.
    func runPortfolioBackup() async throws {
        let previous = portfolioChain
        let task = Task { [weak self] in
            _ = try? await previous?.value
            guard let self else { throw CancellationError() }
            try await self.performPortfolioBackup()
        }
        portfolioChain = task
        defer { if portfolioChain == task { portfolioChain = nil } }
        try await task.value
    }

    /// Uploads each portfolio to its own file, skipping one already up to date. What's on the server
    /// is merged in first, so another device's edits and deletions survive. Afterwards, this account's
    /// file for a portfolio that was deleted or renamed goes: the other files carry the deletion.
    private func performPortfolioBackup() async throws {
        guard let walletAtStart = currentWalletAddress else { throw NextcloudError.noActiveWallet }
        // Writers always encrypt: without the key nothing is uploaded readable.
        guard let key = backupEncryptionKey() else { throw BackupEnvelope.EnvelopeError.keyUnavailable }
        let server = try await mergePortfoliosFromServer(walletAtStart: walletAtStart).server

        let changesAtRead = portfolioChanges
        let local = PortfolioViewModel.shared.syncState
        var state = PortfolioSync.merge([local.forArchive()])
        // Only the untouched "Portfolio 1" left after a deletion: its file carries the deletion, or
        // no file would and the other devices would put the deleted portfolio back.
        if state.portfolios.isEmpty, !state.tombstones.isEmpty {
            state = PortfolioSync.merge([local])
        }
        let seedIds = Set(local.portfolios.filter {
            PortfolioSync.isPristineSeed($0, transactions: local.transactions, fees: local.fees)
        }.map(\.id))
        let names = Self.portfolioFileNames(for: state.portfolios, taken: server.taken)
        for portfolio in state.portfolios {
            guard let name = names[portfolio.id] else { continue }
            let one = PortfolioSync(
                portfolios: [portfolio],
                transactions: state.transactions.filter { $0.portfolioId == portfolio.id },
                fees: state.fees.filter { $0.portfolioId == portfolio.id },
                tombstones: state.tombstones
            )
            if server.own.contains(where: { found in
                guard found.file.name.lowercased() == name.lowercased(), !found.isPlain else { return false }
                if found.backup.sync == one { return true }
                // another device's untouched seed carrying the same deletions does the same job:
                // writing ours over it would only have the two devices take turns
                let backup = found.backup
                return seedIds.contains(portfolio.id)
                    && backup.portfolios.allSatisfy { PortfolioSync.isPristineSeed($0, transactions: backup.transactions, fees: backup.fees) }
                    && PortfolioSync.mergeTombstones([backup.tombstones]) == one.tombstones
            }) { continue }
            let data = try await BackupEnvelope.encryptDetached(
                try PortfolioBackupFile(one, walletAddress: walletAtStart).encoded(), key: key, walletAddress: walletAtStart
            )
            _ = try await uploadToKaChatFolder(
                data: data, filename: name, contentType: "application/json", keepSpaces: true, folder: backupFolderPath
            )
            guard currentWalletAddress == walletAtStart else { return }
        }

        let deletedIds = Set(state.tombstones.filter { $0.kind == .portfolio }.map(\.id))
        // a name just written is a current portfolio's, whatever the listing from before said
        let writtenNames = Set(names.values.map { $0.lowercased() })
        // With nothing uploaded, no file carries a deletion: the deleted portfolio's file stays.
        for found in server.own where !state.portfolios.isEmpty {
            let ids = found.backup.portfolios.map(\.id)
            guard !writtenNames.contains(found.file.name.lowercased()) else { continue }
            // Only for what this device knows the fate of: never a portfolio it simply doesn't have.
            // This device's own untouched seed, uploaded while it carried a deletion, goes too.
            guard ids.allSatisfy({ names[$0] != nil || deletedIds.contains($0.uuidString) || seedIds.contains($0) }) else { continue }
            try await deleteFile(found.file.path)
            guard currentWalletAddress == walletAtStart else { return }
        }

        // every file of this account read as plain was written again encrypted (or deleted)
        if let retired = scopedKey(Self.plainPortfoliosRetiredKey) {
            UserDefaults.standard.set(true, forKey: retired)
        }
        // an edit made during the upload isn't in it: still owed
        if portfolioChanges == changesAtRead { setPendingBackup(false) }
        stampBackup()
        AppLog.log("%@", "[Nextcloud] Portfolio backed up")
    }

    /// Deletes a file from the user's Nextcloud. 404: nothing there, which is the state asked for.
    private func deleteFile(_ path: String) async throws {
        guard var request = authenticatedFileRequest(for: path) else { throw NextcloudError.badCredentials }
        request.httpMethod = "DELETE"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NextcloudError.malformedResponse }
        if http.statusCode == 401 { throw NextcloudError.badCredentials }
        guard (200..<300).contains(http.statusCode) || http.statusCode == 404 else {
            throw NextcloudError.httpError(http.statusCode)
        }
    }

    /// A plain file in the KaChat folder under its name, else under the name it had before the
    /// rename; nil when neither is there.
    private func downloadBackupFile(_ name: String, legacy: [String]) async throws -> Data? {
        for candidate in [name] + legacy {
            do {
                return try await downloadFile(Self.backupPath(candidate), maxBytes: 50_000_000)
            } catch NextcloudError.httpError(404) {
                continue
            }
        }
        return nil
    }

    /// The backup files' server-side metadata (a nil file = not backed up yet, or unreadable).
    struct BackupInfo: Equatable {
        var contacts: NextcloudFile?
        var portfolio: NextcloudFile?
    }

    func fetchBackupInfo() async -> BackupInfo {
        let contacts = await contactsFileInfo()
        guard let wallet = currentWalletAddress,
              let server = try? await readServerPortfolios(walletAtStart: wallet) else { return BackupInfo(contacts: contacts) }
        // the newest of the portfolios' files
        let portfolio = server.own.map(\.file).max { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
        return BackupInfo(contacts: contacts, portfolio: portfolio)
    }

    private static func backupPath(_ name: String) -> String { "\(backupFolderName)/\(name)" }

    // MARK: - Backup folder

    /// The folder the contacts and Portfolio files are in: the one chosen or found ("" is the files
    /// root), or "KaChat" by default.
    var backupFolderPath: String {
        account?.backupFolder ?? Self.backupFolderName
    }

    /// Persists the backup folder ("" = the files root, nil = the default "KaChat" folder).
    func setBackupFolder(_ path: String?) {
        guard var updated = account else { return }
        updated.backupFolder = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let walletAddress = currentWalletAddress, let encoded = try? JSONEncoder().encode(updated) {
            try? KeychainService.shared.saveNextcloudCredentials(encoded, walletAddress: walletAddress)
        }
        account = updated
        // A different file may be there, and this one may not be.
        if let walletAddress = currentWalletAddress { setLastKnownBackupETag(nil, walletAddress: walletAddress) }
    }

    /// Finds the folder this account already keeps its contacts file in, so a fresh connection doesn't
    /// start a second one beside it. Prefers a folder that actually holds the file; one merely NAMED
    /// KaChat is the fallback. Breadth-first and bounded.
    private func discoverExistingBackupFolder() async -> String? {
        guard account != nil else { return nil }

        var queue: [String] = [""]
        var visited = 0
        var namedCandidate: String?

        while !queue.isEmpty, visited < Self.folderDiscoveryMaxFolders {
            let path = queue.removeFirst()
            visited += 1
            guard let entries = try? await listFolder(path) else { continue }

            // A folder holding the file IS the answer - stop looking.
            if entries.contains(where: { !$0.isDirectory && $0.name == Self.backupFileName }) {
                return path
            }
            for entry in entries where entry.isDirectory {
                if entry.name.caseInsensitiveCompare(Self.backupFolderName) == .orderedSame, namedCandidate == nil {
                    namedCandidate = entry.path
                }
                if entry.path.split(separator: "/").count < Self.folderDiscoveryMaxDepth {
                    queue.append(entry.path)
                }
            }
        }
        return namedCandidate
    }

    // MARK: - Connection

    var isConnected: Bool { account != nil }

    /// Normalizes user input ("restohome.duckdns.org", trailing slashes, an accidental
    /// "/index.php" suffix) into a clean base URL, defaulting to https.
    nonisolated static func normalizedServerURL(from input: String) -> URL? {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if !raw.lowercased().hasPrefix("http://") && !raw.lowercased().hasPrefix("https://") {
            raw = "https://" + raw
        }
        while raw.hasSuffix("/") { raw.removeLast() }
        if raw.lowercased().hasSuffix("/index.php") { raw.removeLast("/index.php".count) }
        guard let url = URL(string: raw), url.host != nil else { return nil }
        return url
    }

    /// Verifies the credentials against the OCS user endpoint (the cheapest authenticated call),
    /// then persists them and merges in what this account already has there.
    /// Throws `badCredentials` on a 401 so the connect screen can say exactly what's wrong.
    func connect(serverInput: String, username: String, appPassword: String) async throws {
        guard !isOffForTestnet else { throw NextcloudError.offOnTestnet }
        guard let walletAddress = currentWalletAddress else {
            throw NextcloudError.noActiveWallet
        }
        guard let server = Self.normalizedServerURL(from: serverInput) else {
            throw NextcloudError.invalidServerURL
        }
        // https-only transport. The connect screen rejects http:// inline before calling here;
        // this guard is the backstop for any other path into connect().
        guard server.scheme?.lowercased() == "https" else {
            throw NextcloudError.httpNotSupported
        }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = appPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !password.isEmpty else { throw NextcloudError.badCredentials }

        let candidate = NextcloudAccount(serverURLString: server.absoluteString, username: user, appPassword: password)
        guard let endpoint = URL(string: server.absoluteString + "/ocs/v2.php/cloud/user?format=json") else {
            throw NextcloudError.invalidServerURL
        }
        var request = URLRequest(url: endpoint)
        applyAuth(&request, account: candidate)
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NextcloudError.malformedResponse }
        if http.statusCode == 401 { throw NextcloudError.badCredentials }
        guard (200..<300).contains(http.statusCode) else { throw NextcloudError.httpError(http.statusCode) }
        guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ocs = decoded["ocs"] as? [String: Any],
              ocs["data"] is [String: Any] else {
            throw NextcloudError.malformedResponse
        }

        let encoded = try JSONEncoder().encode(candidate)
        try KeychainService.shared.saveNextcloudCredentials(encoded, walletAddress: walletAddress)
        account = candidate
        needsReconnect = false

        // Point at the contacts file this account already has, before anything reads or writes one.
        if let found = await discoverExistingBackupFolder() {
            AppLog.log("%@", "[Nextcloud] Linked existing backup folder: \(found)")
            setBackupFolder(found)
        }
        noteContactActivity()
        startChangeWatcherIfNeeded()

        // What this account made on another device, or in KaChat, comes back by itself, once.
        Task { [weak self] in
            guard let self, let toast = await self.mergeAfterConnect(walletAtStart: walletAddress) else { return }
            self.syncStatusToast = toast
        }
    }

    /// Merges both backups into this device, without uploading. Returns the toast, or nil when nothing
    /// changed here. Each file is on its own: a problem with one doesn't stop the other.
    private func mergeAfterConnect(walletAtStart: String) async -> String? {
        let book = AddressBookManager.shared
        let contactsBefore = book.entries.count
        await moveToEncryptedContactsIfNeeded(walletAtStart: walletAtStart)
        do {
            let raw = try await downloadBackup()
            guard BackupEnvelope.parse(raw) != nil else { throw NextcloudError.malformedResponse }
            let plaintext = try await BackupEnvelope.decryptIfEnvelopedDetached(raw, key: backupEncryptionKey(), walletAddress: walletAtStart)
            guard currentWalletAddress == walletAtStart, book.holdsWallet(walletAtStart) else { return nil }
            try book.mergeBackup(plaintext)
        } catch NextcloudError.backupNotFound {
            // Nothing there yet.
        } catch {
            AppLog.log("%@", "[Nextcloud] Reading the contacts file failed: \(error.localizedDescription)")
        }
        var portfolioChanged = false
        do {
            portfolioChanged = try await mergePortfoliosFromServer(walletAtStart: walletAtStart).changed
        } catch {
            AppLog.log("%@", "[Nextcloud] Reading the Portfolio backup failed: \(error.localizedDescription)")
        }
        guard currentWalletAddress == walletAtStart else { return nil }
        let added = book.entries.count - contactsBefore
        switch (added > 0, portfolioChanged) {
        case (true, true):
            return String(format: AppLocalization.string("Restored %lld addresses and your Portfolio from Nextcloud."), added)
        case (true, false):
            return String(format: AppLocalization.string("Restored %lld addresses from Nextcloud."), added)
        case (false, true):
            return AppLocalization.string("Restored your Portfolio from Nextcloud.")
        case (false, false):
            return nil
        }
    }

    func disconnect() {
        // Revoke first, while the credentials still exist to authenticate the request.
        if let account {
            // Handed over: this task runs after `disconnect` has cleared the account.
            Task { await self.revokeAppPassword(using: account) }
        }
        backupTask?.cancel()
        backupTask = nil
        autoBackupTask?.cancel()
        autoBackupTask = nil
        syncDebounceTask?.cancel()
        syncDebounceTask = nil
        stopChangeWatcher()
        portfolioFileCache = [:]
        needsReconnect = false
        if let walletAddress = currentWalletAddress {
            try? KeychainService.shared.deleteNextcloudCredentials(walletAddress: walletAddress)
            // This wallet's Nextcloud settings go with its credentials: connecting a different
            // server later starts fresh.
            purgeStoredState(forWalletAddress: walletAddress)
        }
        // Belt and braces: if a legacy global blob somehow still exists, remove it too so
        // disconnect can never appear to "come back" via migration.
        try? KeychainService.shared.deleteLegacyNextcloudCredentials()
        autoBackupEnabled = false
        pendingBackup = false
        lastBackupAt = nil
        lastAutoSyncAt = nil
        pendingSyncDirty = false
        lastKnownBackupETag = nil
        account = nil
    }

    // MARK: - Files in the KaChat folder (the Portfolio backup, Contacts and Portfolio import / export)

    /// Uploads `data` as `filename` into the KaChat folder, or `folder` ("" is the files root),
    /// creating it if it isn't there yet, and returns the stored path. A file of the same name is
    /// replaced.
    /// `keepSpaces` keeps a name the user gave (a portfolio's, "KaChat Address Book") readable in
    /// Nextcloud instead of turning its spaces into underscores.
    func uploadToKaChatFolder(data: Data, filename: String, contentType: String, keepSpaces: Bool = false, folder: String? = nil) async throws -> String {
        guard let account, let server = account.serverURL else { throw NextcloudError.badCredentials }
        let folder = folder ?? Self.backupFolderName
        var folderURL = server.appendingPathComponent("remote.php/dav/files/\(account.username)")
        // Level by level: MKCOL is not recursive, and 405 means the level already exists.
        for part in folder.split(separator: "/") {
            folderURL.appendPathComponent(String(part))
            var mkcol = URLRequest(url: folderURL)
            mkcol.httpMethod = "MKCOL"
            applyAuth(&mkcol, account: account)
            let (_, mkcolResponse) = try await URLSession.shared.data(for: mkcol)
            if let http = mkcolResponse as? HTTPURLResponse {
                if http.statusCode == 401 { throw NextcloudError.badCredentials }
                guard (200..<300).contains(http.statusCode) || http.statusCode == 405 else {
                    throw NextcloudError.httpError(http.statusCode)
                }
            }
        }

        let storedName = Self.sanitizedFilename(filename, keepSpaces: keepSpaces)
        var put = URLRequest(url: folderURL.appendingPathComponent(storedName))
        put.httpMethod = "PUT"
        put.setValue(contentType, forHTTPHeaderField: "Content-Type")
        applyAuth(&put, account: account)
        put.httpBody = data
        let (_, putResponse) = try await URLSession.shared.data(for: put)
        guard let http = putResponse as? HTTPURLResponse else { throw NextcloudError.malformedResponse }
        if http.statusCode == 401 { throw NextcloudError.badCredentials }
        guard (200..<300).contains(http.statusCode) else { throw NextcloudError.httpError(http.statusCode) }
        return folder.isEmpty ? storedName : "\(folder)/\(storedName)"
    }

    /// A file's bytes, for importing it. Every failure throws so the caller can say what went wrong.
    func downloadFile(_ path: String, maxBytes: Int = 10_000_000) async throws -> Data {
        guard let request = authenticatedFileRequest(for: path) else { throw NextcloudError.badCredentials }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NextcloudError.malformedResponse }
        if http.statusCode == 401 { throw NextcloudError.badCredentials }
        guard (200..<300).contains(http.statusCode) else { throw NextcloudError.httpError(http.statusCode) }
        guard data.count <= maxBytes else { throw NextcloudError.malformedResponse }
        return data
    }

    /// Authenticated GET request for a file's raw bytes over WebDAV.
    private func authenticatedFileRequest(for path: String) -> URLRequest? {
        guard let account, let server = account.serverURL else { return nil }
        var url = server
        for part in "remote.php/dav/files/\(account.username)/\(path)".split(separator: "/") {
            url.appendPathComponent(String(part))
        }
        var request = URLRequest(url: url)
        applyAuth(&request, account: account)
        return request
    }

    /// Keeps stored filenames WebDAV/URL-safe: alphanumerics, dot, dash and underscore survive;
    /// everything else becomes "_". The extension must survive intact.
    private nonisolated static func sanitizedFilename(_ name: String, keepSpaces: Bool = false) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: keepSpaces ? "._- " : "._-"))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "file" : cleaned
    }

    private nonisolated func applyAuth(_ request: inout URLRequest, account: NextcloudAccount) {
        let token = Data("\(account.username):\(account.appPassword)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
    }

    // MARK: - WebDAV browsing (the import file picker's data source)

    /// Lists one folder (non-recursive) of the connected account's files via a Depth-1 PROPFIND.
    func listFolder(_ relativePath: String = "") async throws -> [NextcloudFile] {
        guard let account, let server = account.serverURL else { throw NextcloudError.badCredentials }
        let davBasePath = "/remote.php/dav/files/\(account.username)"
        // Normalized form of the listed folder, for the parser's self-entry exclusion below.
        let listedPath = relativePath.split(separator: "/").joined(separator: "/")
        var url = server
        for part in "remote.php/dav/files/\(account.username)/\(relativePath)".split(separator: "/") {
            url.appendPathComponent(String(part))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        applyAuth(&request, account: account)
        request.httpBody = Data("""
        <?xml version="1.0"?>
        <d:propfind xmlns:d="DAV:">
          <d:prop><d:displayname/><d:resourcetype/><d:getcontenttype/><d:getcontentlength/><d:getlastmodified/></d:prop>
        </d:propfind>
        """.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NextcloudError.malformedResponse }
        if http.statusCode == 401 { throw NextcloudError.badCredentials }
        guard http.statusCode == 207 else { throw NextcloudError.httpError(http.statusCode) }

        return DavMultistatusParser(davBasePath: davBasePath, listedPath: listedPath)
            .parse(data)
            .sortedNewestFirst()
    }
}

/// Minimal WebDAV `multistatus` parser for folder listings — pulls each response's href,
/// display name, collection flag, content type and length. Namespace-agnostic via
/// `shouldProcessNamespaces` (servers vary between `d:` and `D:` prefixes).
private final class DavMultistatusParser: NSObject, XMLParserDelegate {
    private let davBasePath: String
    /// The folder being listed. A Depth-1 PROPFIND's multistatus includes the listed folder
    /// ITSELF as its first response — without excluding it, every folder appears to contain
    /// itself (an infinite "Photos inside Photos" loop when browsing).
    private let listedPath: String
    private var results: [NextcloudFile] = []
    private var inResponse = false
    private var currentHref = ""
    private var currentName: String?
    private var currentType: String?
    private var currentLength: Int64?
    private var currentModified: Date?
    private var isCollection = false
    private var text = ""

    /// WebDAV's getlastmodified is RFC 1123 ("Mon, 11 Aug 2026 20:14:07 GMT").
    private static let lastModifiedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        // The string carries its own zone ("GMT"), but pin the fallback so a server that omits it
        // is read as UTC instead of drifting with the device's local zone.
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    init(davBasePath: String, listedPath: String) {
        self.davBasePath = davBasePath
        self.listedPath = listedPath
    }

    func parse(_ data: Data) -> [NextcloudFile] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        parser.parse()
        return results
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch elementName {
        case "response":
            inResponse = true
            currentHref = ""
            currentName = nil
            currentType = nil
            currentLength = nil
            currentModified = nil
            isCollection = false
        case "collection":
            isCollection = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "href":
            if inResponse, currentHref.isEmpty { currentHref = trimmed }
        case "displayname":
            if inResponse, currentName == nil, !trimmed.isEmpty { currentName = trimmed }
        case "getcontenttype":
            if inResponse, !trimmed.isEmpty { currentType = trimmed }
        case "getcontentlength":
            if inResponse { currentLength = Int64(trimmed) }
        case "getlastmodified":
            if inResponse, !trimmed.isEmpty { currentModified = Self.lastModifiedFormatter.date(from: trimmed) }
        case "response":
            inResponse = false
            appendCurrent()
        default:
            break
        }
    }

    private func appendCurrent() {
        guard let decoded = currentHref.removingPercentEncoding,
              let range = decoded.range(of: davBasePath) else { return }
        var relative = String(decoded[range.upperBound...])
        while relative.hasPrefix("/") { relative.removeFirst() }
        while relative.hasSuffix("/") { relative.removeLast() }
        guard !relative.isEmpty, relative != listedPath else { return } // the listed folder itself
        let fallbackName = relative.split(separator: "/").last.map(String.init) ?? relative
        results.append(NextcloudFile(
            path: relative,
            name: currentName ?? fallbackName,
            isDirectory: isCollection,
            contentType: currentType,
            size: currentLength,
            modified: currentModified
        ))
    }
}

// MARK: - Encrypted backup envelope (v1)

/// At-rest encryption for the Nextcloud `kachat-contacts.json` - the exact cross-platform format KaChat
/// specifies in its MESSAGING.md ("Encrypted Backup Envelope (v1)"), so either app reads what the other wrote. AES-256-GCM via
/// CryptoKit; the key is SHA-256(identity private key raw 32 bytes || "kachat-backup-v1"), so
/// any device holding the seed derives the same key and nothing else can read the archive.
/// Writers ALWAYS encrypt.
enum BackupEnvelope {
    struct Envelope: Codable {
        let kachatEncryptedBackup: Int
        let cipher: String
        let nonce: String
        let ciphertext: String
        let walletHint: String?
    }

    enum EnvelopeError: LocalizedError {
        case decryptFailed
        case keyUnavailable

        var errorDescription: String? {
            switch self {
            case .decryptFailed:
                return "Could not decrypt the backup. It may belong to a different account."
            case .keyUnavailable:
                return "The wallet key needed to encrypt the backup is not available."
            }
        }
    }

    /// key = SHA-256(identity_private_key_bytes || UTF8("kachat-backup-v1")) - the identity key
    /// is the chatting address's raw 32-byte private key (`WalletManager.getPrivateKey()`).
    static func key(identityPrivateKey: Data) -> SymmetricKey {
        var material = identityPrivateKey
        material.append(Data("kachat-backup-v1".utf8))
        return SymmetricKey(data: Data(SHA256.hash(data: material)))
    }

    /// First 8 bytes of SHA-256(walletAddress) as hex - identical to
    /// `KeychainService.walletHashSuffix`, restated here so this codec stays self-contained.
    static func walletHint(for walletAddress: String) -> String {
        SHA256.hash(data: Data(walletAddress.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Wraps the plaintext archive in the v1 envelope: fresh random 12-byte nonce per write,
    /// ciphertext carries the 16-byte GCM tag appended, both base64.
    static func encrypt(_ plaintext: Data, key: SymmetricKey, walletAddress: String) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce())
        let envelope = Envelope(
            kachatEncryptedBackup: 1,
            cipher: "aes-256-gcm",
            nonce: Data(sealed.nonce).base64EncodedString(),
            ciphertext: (sealed.ciphertext + sealed.tag).base64EncodedString(),
            walletHint: walletHint(for: walletAddress)
        )
        return try JSONEncoder().encode(envelope)
    }

    /// Detects the v1 envelope. The literal-marker scan keeps legacy multi-MB archives cheap
    /// (no full JSON decode attempt); a legacy archive that happens to CONTAIN the marker text
    /// inside a message simply fails the decode and is treated as plaintext.
    /// True when `data` is a v1 envelope carrying THIS wallet's walletHint - so a failed decrypt
    /// means our own file is damaged, not that it belongs to someone else. An envelope without a
    /// hint can't be attributed and is never treated as ours.
    static func isOwnUnreadableEnvelope(_ data: Data, walletAddress: String) -> Bool {
        guard let envelope = parse(data), let hint = envelope.walletHint else { return false }
        return hint == walletHint(for: walletAddress)
    }

    static func parse(_ data: Data) -> Envelope? {
        guard data.range(of: Data("\"kachatEncryptedBackup\"".utf8)) != nil,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.kachatEncryptedBackup == 1 else { return nil }
        return envelope
    }

    /// Off-main variant of `encrypt` - AES-GCM plus base64 over a multi-MB archive is real CPU
    /// work and every caller in this file is `@MainActor`, so hop to a detached task for it.
    static func encryptDetached(_ plaintext: Data, key: SymmetricKey, walletAddress: String) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try encrypt(plaintext, key: key, walletAddress: walletAddress)
        }.value
    }

    /// Off-main variant of `decryptIfEnveloped` - same rationale as `encryptDetached`.
    static func decryptIfEnvelopedDetached(_ data: Data, key: SymmetricKey?, walletAddress: String?) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try decryptIfEnveloped(data, key: key, walletAddress: walletAddress)
        }.value
    }

    /// Envelope-aware read: legacy plaintext passes through untouched; a v1 envelope is
    /// decrypted (after a cheap walletHint check that skips a foreign wallet's file without
    /// attempting the decrypt). Any failure throws `decryptFailed` - callers abort BEFORE any
    /// upload, so a wrong-seed or corrupt file can never overwrite the server copy.
    static func decryptIfEnveloped(_ data: Data, key: SymmetricKey?, walletAddress: String?) throws -> Data {
        guard let envelope = parse(data) else { return data }
        if let hint = envelope.walletHint, let walletAddress, hint != walletHint(for: walletAddress) {
            throw EnvelopeError.decryptFailed
        }
        guard let key,
              envelope.cipher == "aes-256-gcm",
              let nonceData = Data(base64Encoded: envelope.nonce),
              let combined = Data(base64Encoded: envelope.ciphertext),
              combined.count > 16,
              let nonce = try? AES.GCM.Nonce(data: nonceData),
              let sealed = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: combined.dropLast(16), tag: combined.suffix(16)),
              let plaintext = try? AES.GCM.open(sealed, using: key) else {
            throw EnvelopeError.decryptFailed
        }
        return plaintext
    }
}
