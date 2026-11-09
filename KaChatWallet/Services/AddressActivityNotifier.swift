import Foundation
import UIKit
import UserNotifications

/// "Received" notifications: alerts the user when any of the wallet's own addresses - the main
/// address, spending-chain addresses (Manage Addresses) or watch-only cold-storage addresses -
/// receives Kaspa from someone else. A local notification, plus a persisted per-address balance
/// baseline update so the catch-up path and the open Manage Addresses / Cold Storage screens
/// stay in sync.
///
/// Self-send filtering is the critical part - change from own payments, consolidations,
/// KNS inscription change, cold-storage withdrawals, payments between own addresses, and
/// anything another app on the same seed sends (a KaPosts post, a KaChat message) must NOT
/// notify. A tx counts as ours when ANY of its inputs spends from one of our addresses:
///   1. REST resolve (the classifier's own endpoint, `resolve_previous_outpoints=light`):
///      fetch the tx and check its input addresses.
///   2. The API often leaves a seconds-old tx's input addresses empty, so an unresolved input
///      is matched against the coins our addresses just spent (the `removed` entries of the
///      live batches, by outpoint), then looked up in the tx that created it.
///   3. A tx that can't be read at all is ours when the same batch spent from our addresses.
/// Notifications are deduped per txId (persisted, capped) and multiple outputs of one tx to
/// our addresses notify once with the summed amount.
///
/// Catch-up (app foregrounded after being away) diffs live balances against the persisted
/// baseline; increases are attributed via each address's recent transactions with the same
/// inputs-not-ours filter, falling back to a neutral "Balance increased" notification when
/// resolution fails. First run just seeds the baseline silently so enabling the feature (or
/// importing a wallet) never blasts notifications for historical funds. Only receives newer
/// than the address's floor (the newest block time a catch-up already looked at) count, newest
/// first and no more than the increase - so older history is never announced again.
///
/// With remote push registered, the push service sends "Received" for the same addresses, and
/// the app hides that push only while it is open (`willPresent`). So the app announces a
/// receive itself only while it is open; one that landed while it was away was the push's.
///
/// Gated by Settings > Notifications > "Address Activity" (default ON) plus the master
/// notification mode.
///
@MainActor
final class AddressActivityNotifier: ObservableObject {
    static let shared = AddressActivityNotifier()
    private init() {
        // A subscription restored after a failover: what arrived meanwhile is found by the
        // balance diff (debounced), never by replaying the UTXO set as new (IOS-070).
        NotificationCenter.default.addObserver(forName: .rpcSubscriptionsRestored, object: nil, queue: .main) { _ in
            Task { @MainActor in await AddressActivityNotifier.shared.runCatchUpIfNeeded() }
        }
        activeSince = UIApplication.shared.applicationState == .active ? Date() : nil
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AddressActivityNotifier.shared.activeSince = Date() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AddressActivityNotifier.shared.activeSince = nil }
        }
    }

    static let notificationThreadIdentifier = "address-activity"

    // MARK: - Cached own-address sets

    private var cachedWalletAddress: String?
    private var cachedNetworkKey: String = ""
    private var cachedSpendingMaxIndex: Int = -1
    private var spendingAddressSet: Set<String> = []
    private var coldFingerprint: String = ""
    /// Cold-storage address -> owning account label (for notification wording).
    private var coldLabelByAddress: [String: String] = [:]
    /// Cold-storage addresses whose account has receive notifications switched off. Still
    /// "ours" for the self-send check; never notified.
    private var coldMutedAddresses: Set<String> = []

    /// Receive notifications for the wallet's spending addresses (Manage Addresses), per
    /// wallet - the counterpart of a cold account's `notifyOnReceive`. Default on.
    @Published var spendingReceiveNotificationsEnabled: Bool = true {
        didSet {
            guard let wallet = WalletManager.shared.currentWallet?.publicAddress else { return }
            UserDefaults.standard.set(spendingReceiveNotificationsEnabled, forKey: Self.spendingNotifyKey(wallet: wallet))
        }
    }
    private var spendingNotifyLoadedForWallet: String?
    private static func spendingNotifyKey(wallet: String) -> String {
        "kachat_spending_receive_notify_\(wallet.replacingOccurrences(of: ":", with: "_"))"
    }

    /// Loads the spending switch for the current wallet - call when a screen that shows it appears.
    func reloadSpendingSwitchForCurrentWallet() {
        guard let wallet = WalletManager.shared.currentWallet?.publicAddress else { return }
        guard spendingNotifyLoadedForWallet != wallet else { return }
        spendingNotifyLoadedForWallet = wallet
        let stored = UserDefaults.standard.object(forKey: Self.spendingNotifyKey(wallet: wallet)) as? Bool
        spendingReceiveNotificationsEnabled = stored ?? true
    }

    // MARK: - Per-tx dedupe / in-flight tracking

    /// TxIds already handled (notified OR deliberately suppressed as self-sends) - persisted
    /// per wallet so reopening the app can't re-notify what the live path already covered.
    private var handledTxIds: Set<String> = []
    private var handledTxIdOrder: [String] = []
    private var handledLoadedForWallet: String?
    private static let handledTxIdCap = 500

    private var inFlightTxIds: Set<String> = []
    /// Outpoints (`txid:index`) our addresses spent, from the live batches' `removed` entries -
    /// kept a few minutes so a receive whose input addresses the REST API hasn't filled in yet
    /// can still be recognised as our own spend.
    private var recentOwnSpentOutpoints: [String: Date] = [:]
    private static let ownSpentOutpointTTL: TimeInterval = 600
    /// When the live path last saw a receive to each address - the catch-up's neutral "Balance
    /// increased" stays quiet for those, since the live path announces that receive itself.
    private var recentLiveHitAt: [String: Date] = [:]
    private static let liveHitTTL: TimeInterval = 180
    /// Since when the app has been open this time (nil while it isn't).
    private var activeSince: Date?
    private var lastCatchUpAt: Date?
    private var lastCatchUpWallet: String?

    // MARK: - Public surface

    /// Every address this feature wants in the UTXO subscription watched set: all revealed
    /// spending-chain addresses (0...max index) and every cold-storage address of every
    /// imported account. Derivation results are cached and only recomputed when the wallet,
    /// the spending max index, the cold-account set or the network changes - the first
    /// spending derivation per wallet does one seed decrypt + PBKDF2, same cost Manage
    /// Addresses already pays on open.
    func watchedOwnAddresses() -> Set<String> {
        refreshCaches()
        return spendingAddressSet.union(coldLabelByAddress.keys)
    }

    /// What the push service watches for this device's "Received" pushes (the register/update
    /// `watch_only_addresses`): the chatting address, the spending addresses while their switch is
    /// on, and every cold-storage address whose account notifies - the same choices the local
    /// notifications follow. Empty while Address Activity is off. The service keeps 200 at most.
    func pushWatchOnlyAddresses() -> [String] {
        guard featureEnabled else { return [] }
        refreshCaches()
        reloadSpendingSwitchForCurrentWallet()
        var addresses: Set<String> = []
        if let wallet = WalletManager.shared.currentWallet?.publicAddress {
            addresses.insert(wallet)
        }
        if spendingReceiveNotificationsEnabled {
            addresses.formUnion(spendingAddressSet)
        }
        addresses.formUnion(Set(coldLabelByAddress.keys).subtracting(coldMutedAddresses))
        return addresses.sorted()
    }

    /// UserInfo key carrying the involved own addresses on a `.ownAddressUtxoActivity` post.
    static let utxoActivityAddressesKey = "addresses"

    /// Always-post internal event, deliberately separate from the user-notification decision:
    /// posts `.ownAddressUtxoActivity` (with the involved own addresses) whenever a UTXO batch
    /// touches any watched spending/cold address - including SELF-SEND change, which the
    /// notification paths suppress. `handleLiveUtxoAdditions` posts `.ownAddressActivity` only
    /// after its self-send check (seconds later), and the whole notifier is gated by the
    /// Address Activity notification setting - so UI that must track its own change landing
    /// (the payment composer's Available pill, the address list screens) listens to THIS
    /// event instead. Not gated by `featureEnabled`.
    func postUtxoActivityEvent(
        parsed: ParsedUtxosChangedNotification,
        removedByTxId: [String: Set<String>]
    ) {
        let watched = watchedOwnAddresses()
        guard !watched.isEmpty else { return }
        var involved: Set<String> = []
        for entry in parsed.added {
            if let address = entry.address, watched.contains(address) {
                involved.insert(address)
            }
        }
        for removed in removedByTxId.values {
            involved.formUnion(removed.intersection(watched))
        }
        guard !involved.isEmpty else { return }
        NotificationCenter.default.post(
            name: .ownAddressUtxoActivity,
            object: nil,
            userInfo: [Self.utxoActivityAddressesKey: Array(involved)]
        )
    }

    /// Live path, called from the UTXO classifier with the whole parsed batch. Remembers the
    /// coins our addresses spent, collects outputs landing on own notifiable addresses, dedupes
    /// per txId, and schedules the self-send check (REST input resolution) for each tx.
    func handleLiveUtxoAdditions(parsed: ParsedUtxosChangedNotification) {
        guard featureEnabled else { return }
        guard let wallet = WalletManager.shared.currentWallet else { return }
        refreshCaches()
        ensureHandledTxIdsLoaded(wallet: wallet.publicAddress)

        // A batch's `removed` entries are keyed by the outpoint they spend (the tx that created
        // the coin), not by the spending tx - so they're remembered by outpoint and matched
        // against each receive's inputs once its tx is fetched.
        let ownAll = ownInputAddressSet(walletAddress: wallet.publicAddress)
        recordOwnSpends(parsed.removed, ownAddresses: ownAll)
        let batchSpentOwn = parsed.removed.contains { $0.address.map(ownAll.contains) ?? false }

        let notifiable = notifiableAddressSet(walletAddress: wallet.publicAddress)
        guard !notifiable.isEmpty else { return }

        // Group outputs to our own addresses per tx so one tx paying several of our
        // addresses notifies once with the summed amount. Coinbase entries are skipped to
        // mirror the classifier (a miner pointed at a spending address would otherwise get
        // a notification per block; catch-up still reflects the balance growth).
        var hitsByTx: [String: [(address: String, amount: UInt64)]] = [:]
        for entry in parsed.added {
            guard !entry.isCoinbase, let address = entry.address else { continue }
            guard notifiable.contains(address) else { continue }
            hitsByTx[entry.transactionId, default: []].append((address, entry.amount))
        }
        guard !hitsByTx.isEmpty else { return }

        let now = Date()
        recentLiveHitAt = recentLiveHitAt.filter { now.timeIntervalSince($0.value) < Self.liveHitTTL }
        for hits in hitsByTx.values {
            for hit in hits { recentLiveHitAt[hit.address] = now }
        }

        for (txId, hits) in hitsByTx {
            guard !handledTxIds.contains(txId), !inFlightTxIds.contains(txId) else { continue }
            inFlightTxIds.insert(txId)
            Task { [weak self] in
                await self?.resolveAndNotifyLive(
                    txId: txId,
                    hits: hits,
                    ownAddresses: ownAll,
                    batchSpentOwn: batchSpentOwn,
                    walletAddress: wallet.publicAddress
                )
            }
        }
    }

    /// Catch-up path, run on app foreground: diff live balances of every watched address
    /// against the persisted baseline and notify for increases not attributable to our own
    /// activity. Debounced; the first run for a wallet only seeds the baseline.
    func runCatchUpIfNeeded() async {
        guard let wallet = WalletManager.shared.currentWallet else { return }
        if let last = lastCatchUpAt,
           lastCatchUpWallet == wallet.publicAddress,
           Date().timeIntervalSince(last) < 60 {
            return
        }
        lastCatchUpAt = Date()
        lastCatchUpWallet = wallet.publicAddress

        refreshCaches()
        ensureHandledTxIdsLoaded(wallet: wallet.publicAddress)
        let watched = notifiableAddressSet(walletAddress: wallet.publicAddress)
        guard !watched.isEmpty else { return }

        // One batched balance fetch for the whole set (mirrors ColdStorageManager's
        // one-call-for-everything pattern). A network failure leaves baselines untouched so
        // nothing is silently marked as seen.
        guard let utxos = try? await NodePoolService.shared.getUtxosByAddresses(Array(watched)) else {
            return
        }
        var currentBalances: [String: UInt64] = [:]
        for address in watched { currentBalances[address] = 0 }
        for utxo in utxos where currentBalances[utxo.address] != nil {
            currentBalances[utxo.address, default: 0] += utxo.amount
        }

        let baselines = loadBaselines(wallet: wallet.publicAddress)
        let isFirstRun = baselines.isEmpty
        var updates: [String: UInt64] = [:]

        for (address, balance) in currentBalances {
            guard let previous = baselines[address] else {
                // Never-tracked address (feature install, newly revealed slot, fresh cold
                // import): seed silently - its history predates our tracking, and its receives
                // count from now on.
                updates[address] = balance
                setCatchUpFloor(Self.nowMs, address: address, wallet: wallet.publicAddress)
                continue
            }
            if balance > previous, !isFirstRun, featureEnabled {
                await attributeAndNotifyIncrease(
                    address: address,
                    delta: balance - previous,
                    walletAddress: wallet.publicAddress
                )
            }
            if balance != previous { updates[address] = balance }
        }

        if !updates.isEmpty {
            // The live path refreshes baselines while this runs - keep a value it wrote meanwhile.
            var stored = loadBaselines(wallet: wallet.publicAddress)
            for (address, balance) in updates where stored[address] == baselines[address] {
                stored[address] = balance
            }
            saveBaselines(stored, wallet: wallet.publicAddress)
            NotificationCenter.default.post(name: .ownAddressActivity, object: nil)
        }
    }

    // MARK: - Live resolution

    private func resolveAndNotifyLive(
        txId: String,
        hits: [(address: String, amount: UInt64)],
        ownAddresses: Set<String>,
        batchSpentOwn: Bool,
        walletAddress: String
    ) async {
        defer { inFlightTxIds.remove(txId) }

        let fullTx = await WalletService.shared.fetchKaspaFullTransaction(
            txId: txId,
            retries: 6,
            delayNs: 2_000_000_000
        )
        var spendsOwn: Bool?
        if let fullTx {
            spendsOwn = await spendsOwnFunds(fullTx, ownAddresses: ownAddresses)
        }
        // Inputs we couldn't place (or no tx at all): an own spend in the same batch makes it
        // our own change far more likely than a receive - e.g. a KaPosts post from this seed.
        let isSelfSend = spendsOwn ?? batchSpentOwn
        // An unreadable tx in a batch that spent nothing of ours still notifies: missing real
        // funds is worse than a rare stray ping.

        guard !handledTxIds.contains(txId) else { return }
        // the lookup above can take a while: an answer for an account no longer signed in is dropped
        guard WalletManager.shared.currentWallet?.publicAddress == walletAddress else { return }
        markHandled(txId: txId, wallet: walletAddress)

        if !isSelfSend, pushShowsReceive(blockTimeMs: nil) {
            AppLog.log("[AddressActivity] Receive %@ left to the push (app not open)", String(txId.prefix(12)))
        } else if !isSelfSend {
            postReceiveNotification(hits: hits, dedupeKey: txId)
            AppLog.log("[AddressActivity] Notified external receive %@ (%d output(s) to own addresses)",
                  String(txId.prefix(12)), hits.count)
        } else {
            AppLog.log("[AddressActivity] Suppressed self-send %@ after input resolve", String(txId.prefix(12)))
        }

        await refreshBaselines(for: Set(hits.map { $0.address }), wallet: walletAddress)
        NotificationCenter.default.post(name: .ownAddressActivity, object: nil)
    }

    // MARK: - Catch-up attribution

    private func attributeAndNotifyIncrease(
        address: String,
        delta: UInt64,
        walletAddress: String
    ) async {
        let ownAll = ownInputAddressSet(walletAddress: walletAddress)
        let recentTxs = await WalletService.shared.fetchFullTransactionsPaginated(
            for: address,
            pageSize: 10,
            maxTransactions: 10
        )
        // Only receives newer than what an earlier catch-up already looked at (or than when the
        // address started being tracked). An address tracked before floors existed has none
        // yet: the increase alone bounds it below.
        let floor = catchUpFloor(address: address, wallet: walletAddress)
        if let newest = recentTxs.compactMap(\.blockTime).max() {
            setCatchUpFloor(max(newest, floor ?? 0), address: address, wallet: walletAddress)
        }
        // The neutral fallback stays quiet when the receive is someone else's to announce: the
        // live path's (it just saw one here) or the push's (the app was away).
        let liveSawIt = recentLiveHitAt[address].map { Date().timeIntervalSince($0) < Self.liveHitTTL } ?? false
        let mayFallBack = !liveSawIt && !pushShowsReceive(blockTimeMs: nil)

        guard !recentTxs.isEmpty else {
            // Resolution failed entirely - still surface the funds, neutral wording.
            if mayFallBack { postBalanceIncreasedNotification(address: address, delta: delta) }
            return
        }

        // Newest first, and only as many receives as the balance grew by: anything older was
        // already in the baseline. Own change doesn't count against the increase.
        let newestFirst = recentTxs.sorted { ($0.blockTime ?? .max) > ($1.blockTime ?? .max) }
        var remaining = delta
        var attributedAny = false
        for tx in newestFirst {
            guard remaining > 0 else { break }
            if let floor, let time = tx.blockTime, time <= floor { continue }
            let toAddress = tx.outputs
                .filter { $0.scriptPublicKeyAddress == address }
                .reduce(UInt64(0)) { $0 + $1.amount }
            guard toAddress > 0 else { continue }
            attributedAny = true
            // Already announced, or the live path is on it right now.
            if handledTxIds.contains(tx.transactionId) || inFlightTxIds.contains(tx.transactionId) {
                remaining -= min(remaining, toAddress)
                continue
            }
            let isSelfSend = await spendsOwnFunds(tx, ownAddresses: ownAll) ?? false
            guard !handledTxIds.contains(tx.transactionId), !inFlightTxIds.contains(tx.transactionId) else { continue }
            markHandled(txId: tx.transactionId, wallet: walletAddress)
            if isSelfSend { continue }
            remaining -= min(remaining, toAddress)
            if pushShowsReceive(blockTimeMs: tx.blockTime) { continue }
            postReceiveNotification(hits: [(address, toAddress)], dedupeKey: tx.transactionId)
        }

        if !attributedAny, mayFallBack {
            // Balance grew but none of the fetched recent txs pays this address (deep
            // history page or indexer lag) - neutral fallback rather than staying silent.
            postBalanceIncreasedNotification(address: address, delta: delta)
        }
    }

    /// Whether the push service already shows this receive, so the app must not: it pushes
    /// "Received" for the addresses this device registered, and the app hides that push only
    /// while it is open. A receive from before the app opened this time (or any receive while it
    /// isn't open) is the push's. `blockTimeMs` nil means it is happening now.
    private func pushShowsReceive(blockTimeMs: UInt64?) -> Bool {
        guard AppSettings.load().notificationMode == .remotePush,
              PushNotificationManager.shared.isRegistered else { return false }
        guard UIApplication.shared.applicationState == .active, let activeSince else { return true }
        guard let blockTimeMs else { return false }
        return Double(blockTimeMs) < activeSince.timeIntervalSince1970 * 1000
    }

    // MARK: - Notification posting

    private func postReceiveNotification(hits: [(address: String, amount: UInt64)], dedupeKey: String) {
        guard featureEnabled else { return }
        let total = hits.reduce(UInt64(0)) { $0 + $1.amount }
        guard total > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Received \(Self.formatKas(total)) \(KaspaUnit.symbol)"
        content.body = bodyDescribing(addresses: hits.map { $0.address })
        content.threadIdentifier = Self.notificationThreadIdentifier
        // The tap opens the history of the address that got the Kaspa - with several, the one
        // that got the most (the body names them all).
        var byAddress: [String: UInt64] = [:]
        for hit in hits { byAddress[hit.address, default: 0] += hit.amount }
        let opened = byAddress.max { $0.value < $1.value }?.key ?? hits.first?.address ?? ""
        var info: [String: Any] = ["kind": kindKey(for: opened)]
        if !opened.isEmpty { info["address"] = opened }
        content.userInfo = info
        applySoundPreference(to: content)

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "addr-activity-\(dedupeKey)", content: content, trigger: nil)
        )
        // Also list it in the Profile notifications bell.
        Task { @MainActor in
            // the bell's entry opens the same address's history
            GlobalNotificationCenter.shared.record(id: "wallet-\(dedupeKey)", source: .wallet, title: content.title, body: content.body, timestamp: Int64(Date().timeIntervalSince1970 * 1000), targetId: opened.isEmpty ? nil : opened)
        }
    }

    private func postBalanceIncreasedNotification(address: String, delta: UInt64) {
        guard featureEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Balance increased by \(Self.formatKas(delta)) \(KaspaUnit.symbol)"
        content.body = describe(address: address)
        content.threadIdentifier = Self.notificationThreadIdentifier
        content.userInfo = ["kind": kindKey(for: address), "address": address]
        applySoundPreference(to: content)

        let balId = "addr-activity-bal-\(address.suffix(12))-\(UUID().uuidString)"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: balId, content: content, trigger: nil)
        )
        Task { @MainActor in
            GlobalNotificationCenter.shared.record(id: "wallet-\(balId)", source: .wallet, title: content.title, body: content.body, timestamp: Int64(Date().timeIntervalSince1970 * 1000), targetId: address)
        }
    }

    private func applySoundPreference(to content: UNMutableNotificationContent) {
        let settings = AppSettings.load()
        content.sound = settings.incomingNotificationSoundEnabled ? .default : nil
        if !settings.incomingNotificationSoundEnabled,
           settings.incomingNotificationVibrationEnabled,
           UIApplication.shared.applicationState == .active {
            Haptics.impact(.light)
        }
    }

    private func bodyDescribing(addresses: [String]) -> String {
        let unique = Array(Set(addresses))
        if unique.count == 1, let only = unique.first {
            return describe(address: only)
        }
        return "\(unique.count) of your addresses"
    }

    private func describe(address: String) -> String {
        if address == WalletManager.shared.currentWallet?.publicAddress {
            return "Chatting address \(Self.shortAddress(address))"
        }
        if let accountLabel = coldLabelByAddress[address] {
            return "Cold storage (\(accountLabel)) \(Self.shortAddress(address))"
        }
        return "Spending address \(Self.shortAddress(address))"
    }

    private func kindKey(for address: String) -> String {
        if address == WalletManager.shared.currentWallet?.publicAddress { return "main" }
        return coldLabelByAddress[address] != nil ? "cold" : "spending"
    }

    static func shortAddress(_ address: String) -> String {
        guard address.count > 20 else { return address }
        return address.prefix(14) + "..." + address.suffix(6)
    }

    static func formatKas(_ sompi: UInt64) -> String {
        let kas = Double(sompi) / 100_000_000
        var formatted = String(format: "%.8f", kas)
        while formatted.hasSuffix("0") { formatted.removeLast() }
        if formatted.hasSuffix(".") { formatted.removeLast() }
        return formatted
    }

    // MARK: - Gating

    /// Settings > Notifications > "Address Activity" plus the master notification mode.
    private var featureEnabled: Bool {
        let settings = AppSettings.load()
        return settings.addressActivityNotificationsEnabled && settings.notificationMode != .disabled
    }

    // MARK: - Address set caching

    private func refreshCaches() {
        guard let wallet = WalletManager.shared.currentWallet else {
            cachedWalletAddress = nil
            cachedSpendingMaxIndex = -1
            spendingAddressSet = []
            coldFingerprint = ""
            coldLabelByAddress = [:]
            return
        }
        let network = AppSettings.load().networkType
        let networkKey = String(describing: network)
        let walletChanged = cachedWalletAddress != wallet.publicAddress || cachedNetworkKey != networkKey

        // both chains: allSpendingAddresses covers quantum slots, and the fingerprint must move
        // when either chain grows or a new quantum address would go unwatched
        let maxIndex = WalletManager.shared.maxSpendingAddressIndex
            + (WalletManager.shared.maxQuantumAddressIndex + 1) * 100_000
        if walletChanged || cachedSpendingMaxIndex != maxIndex {
            spendingAddressSet = Set(WalletManager.shared.allSpendingAddresses())
            cachedSpendingMaxIndex = maxIndex
        }

        let accounts = ColdStorageManager.shared.accounts
        let fingerprint = accounts
            .map { "\($0.id.uuidString):\($0.maxAddressIndex):\($0.notifyOnReceive)" }
            .joined(separator: ",")
        if walletChanged || fingerprint != coldFingerprint {
            var labelByAddress: [String: String] = [:]
            var muted: Set<String> = []
            for account in accounts {
                guard let extendedKey = KaspaExtendedPublicKey(kpubString: account.kpubString) else { continue }
                for index in 0...account.maxAddressIndex {
                    if let address = try? extendedKey.receiveAddress(at: UInt32(index), network: network) {
                        labelByAddress[address] = account.label
                        if !account.notifyOnReceive { muted.insert(address) }
                    }
                }
            }
            coldLabelByAddress = labelByAddress
            coldMutedAddresses = muted
            coldFingerprint = fingerprint
        }
        if walletChanged { spendingNotifyLoadedForWallet = nil }
        reloadSpendingSwitchForCurrentWallet()

        cachedWalletAddress = wallet.publicAddress
        cachedNetworkKey = networkKey
    }

    /// Addresses whose receives should NOTIFY: the chatting address, the spending addresses while
    /// their switch is on, and every cold-storage address whose account notifies.
    private func notifiableAddressSet(walletAddress: String) -> Set<String> {
        // Per account: the spending chain has its own switch, and each cold-storage account
        // its own - an account switched off is still ours (self-send check), just quiet.
        var set = coldLabelByAddress.keys.filter { !coldMutedAddresses.contains($0) }.reduce(into: Set<String>()) { $0.insert($1) }
        if spendingReceiveNotificationsEnabled { set.formUnion(spendingAddressSet) }
        set.insert(walletAddress)
        return set
    }

    // MARK: - Catch-up floors (UserDefaults, per wallet)

    /// Per address, the newest block time (ms) a catch-up has already looked at, or when the
    /// address started being tracked: older receives were before it was watched, or already
    /// handled - never a burst of old payments.
    private func catchUpFloorsKey(wallet: String) -> String {
        "kachat_addr_activity_floors_\(wallet)"
    }

    private func catchUpFloor(address: String, wallet: String) -> UInt64? {
        guard let data = UserDefaults.standard.data(forKey: catchUpFloorsKey(wallet: wallet)),
              let floors = try? JSONDecoder().decode([String: UInt64].self, from: data),
              let floor = floors[address] else {
            // The chatting address's floor used to be kept on its own, set when it was first tracked.
            guard address == wallet else { return nil }
            let legacy = UserDefaults.standard.double(forKey: "addr_activity_chat_floor_\(wallet.lowercased())")
            return legacy > 0 ? UInt64(legacy) : nil
        }
        return floor
    }

    private func setCatchUpFloor(_ floor: UInt64, address: String, wallet: String) {
        let key = catchUpFloorsKey(wallet: wallet)
        var floors = UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([String: UInt64].self, from: $0) } ?? [:]
        guard floors[address] != floor else { return }
        floors[address] = floor
        guard let data = try? JSONEncoder().encode(floors) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static var nowMs: UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    /// Addresses that count as "ours" when they appear among a tx's INPUTS - superset of the
    /// notifiable set: the chatting address + all spending + all cold storage, muted or not.
    private func ownInputAddressSet(walletAddress: String) -> Set<String> {
        var set = spendingAddressSet.union(coldLabelByAddress.keys)
        set.insert(walletAddress)
        return set
    }

    // MARK: - Self-send check

    /// Whether `tx` spends from any of our addresses: true as soon as one input is ours, false
    /// when every input is placed and none is, nil when some input couldn't be placed. An input
    /// the REST API left unresolved (usual for a tx seconds old) is matched against the coins our
    /// addresses just spent, then looked up in the tx that created it.
    private func spendsOwnFunds(_ tx: KaspaFullTransactionResponse, ownAddresses: Set<String>) async -> Bool? {
        guard let inputs = tx.inputs, !inputs.isEmpty else { return nil }
        pruneOwnSpends()
        var unresolved: [(hash: String, index: Int)] = []
        var unknown = false
        for input in inputs {
            if let address = input.previousOutpointAddress, !address.isEmpty {
                if ownAddresses.contains(address) { return true }
            } else if let hash = input.previousOutpointHash,
                      let index = input.previousOutpointIndex.flatMap({ Int($0) }) {
                if recentOwnSpentOutpoints[Self.outpointKey(hash, index)] != nil { return true }
                unresolved.append((hash, index))
            } else {
                unknown = true
            }
        }
        var previousTxs: [String: KaspaFullTransactionResponse] = [:]
        for (hash, index) in unresolved {
            if previousTxs[hash] == nil,
               let previous = await WalletService.shared.fetchFullTransaction(txId: hash, resolvePrevious: false) {
                previousTxs[hash] = previous
            }
            let outputs = previousTxs[hash]?.outputs ?? []
            let spent = outputs.first(where: { $0.index == index }) ?? (outputs.indices.contains(index) ? outputs[index] : nil)
            guard let address = spent?.scriptPublicKeyAddress, !address.isEmpty else {
                unknown = true
                continue
            }
            if ownAddresses.contains(address) { return true }
        }
        return unknown ? nil : false
    }

    private func recordOwnSpends(_ removed: [ParsedUtxoEntry], ownAddresses: Set<String>) {
        let now = Date()
        for entry in removed {
            guard let address = entry.address, ownAddresses.contains(address) else { continue }
            recentOwnSpentOutpoints[Self.outpointKey(entry.transactionId, Int(entry.outputIndex))] = now
        }
        pruneOwnSpends()
    }

    private func pruneOwnSpends() {
        let cutoff = Date().addingTimeInterval(-Self.ownSpentOutpointTTL)
        recentOwnSpentOutpoints = recentOwnSpentOutpoints.filter { $0.value > cutoff }
    }

    private static func outpointKey(_ txId: String, _ index: Int) -> String {
        "\(txId.lowercased()):\(index)"
    }

    // MARK: - Baseline persistence (UserDefaults, per wallet)

    private func baselinesKey(wallet: String) -> String {
        "kachat_addr_activity_baselines_\(wallet)"
    }

    private func handledTxIdsKey(wallet: String) -> String {
        "kachat_addr_activity_handled_txids_\(wallet)"
    }

    private func loadBaselines(wallet: String) -> [String: UInt64] {
        guard let data = UserDefaults.standard.data(forKey: baselinesKey(wallet: wallet)),
              let decoded = try? JSONDecoder().decode([String: UInt64].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveBaselines(_ baselines: [String: UInt64], wallet: String) {
        guard let data = try? JSONEncoder().encode(baselines) else { return }
        UserDefaults.standard.set(data, forKey: baselinesKey(wallet: wallet))
    }

    /// Re-fetches live balances for just-changed addresses and folds them into the persisted
    /// baseline, so the next catch-up doesn't re-detect (and re-notify) what the live path
    /// already handled.
    private func refreshBaselines(for addresses: Set<String>, wallet: String) async {
        guard !addresses.isEmpty else { return }
        guard let utxos = try? await NodePoolService.shared.getUtxosByAddresses(Array(addresses)) else { return }
        var balances: [String: UInt64] = [:]
        for address in addresses { balances[address] = 0 }
        for utxo in utxos where balances[utxo.address] != nil {
            balances[utxo.address, default: 0] += utxo.amount
        }
        var baselines = loadBaselines(wallet: wallet)
        for (address, balance) in balances {
            baselines[address] = balance
        }
        saveBaselines(baselines, wallet: wallet)
    }

    // MARK: - Handled-tx persistence

    private func ensureHandledTxIdsLoaded(wallet: String) {
        guard handledLoadedForWallet != wallet else { return }
        handledLoadedForWallet = wallet
        let stored = UserDefaults.standard.stringArray(forKey: handledTxIdsKey(wallet: wallet)) ?? []
        handledTxIdOrder = stored
        handledTxIds = Set(stored)
    }

    private func markHandled(txId: String, wallet: String) {
        ensureHandledTxIdsLoaded(wallet: wallet)
        guard handledTxIds.insert(txId).inserted else { return }
        handledTxIdOrder.append(txId)
        if handledTxIdOrder.count > Self.handledTxIdCap {
            let overflow = handledTxIdOrder.count - Self.handledTxIdCap
            for dropped in handledTxIdOrder.prefix(overflow) {
                handledTxIds.remove(dropped)
            }
            handledTxIdOrder.removeFirst(overflow)
        }
        UserDefaults.standard.set(handledTxIdOrder, forKey: handledTxIdsKey(wallet: wallet))
    }
}

extension Notification.Name {
    /// Posted after own-address (spending / cold-storage) balances changed due to detected
    /// receive activity - open Manage Addresses / Cold Storage screens reload on it.
    static let ownAddressActivity = Notification.Name("ownAddressActivity")
    /// Always-posted internal event for ANY UTXO activity on watched own addresses - including
    /// self-send change that never produces an `.ownAddressActivity` post (fast-path suppression)
    /// and regardless of the Address Activity notification setting. UserInfo carries the
    /// involved addresses under `AddressActivityNotifier.utxoActivityAddressesKey`.
    static let ownAddressUtxoActivity = Notification.Name("ownAddressUtxoActivity")
}
