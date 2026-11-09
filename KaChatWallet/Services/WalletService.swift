import Foundation
import Combine
import UIKit

/// RPC connection status for the status indicator
enum RpcConnectionStatus {
    case connected      // UTXO subscription confirmed (green)
    case connecting     // Connection is being established (orange)
    case disconnected   // Not connected (red)

    var color: String {
        switch self {
        case .connected: return "green"
        case .connecting: return "orange"
        case .disconnected: return "red"
        }
    }

    var description: String {
        switch self {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .disconnected: return "Disconnected"
        }
    }
}

/// The wallet's link to the Kaspa network: the node connection, the live UTXO subscription to
/// the wallet's own addresses (main, spending, cold storage), sending, and transaction reads
/// from the Kaspa REST API.
///
/// Each live batch goes to `AddressActivityNotifier` ("Received KAS") and a balance refresh.
/// When the node can't stream, a slow poll refreshes the balance and catches up receives instead.
@MainActor
final class WalletService: ObservableObject {
    static let shared = WalletService()

    var settingsViewModel: SettingsViewModel?

    @Published var isRpcSubscribed = false
    @Published var lastSuccessfulSyncDate: Date?

    // Connection node + latency live on a DEDICATED observable, not @Published here: they update
    // ~every 2s (latency EWMA) and are shown ONLY in the connection-detail screen.
    var currentConnectedNode: String? {
        get { NodeConnectionInfo.shared.currentConnectedNode }
        set { NodeConnectionInfo.shared.currentConnectedNode = newValue }
    }
    var currentNodeLatencyMs: Int? {
        get { NodeConnectionInfo.shared.currentNodeLatencyMs }
        set { NodeConnectionInfo.shared.currentNodeLatencyMs = newValue }
    }

    /// Computed connection status based on node subscription state
    var connectionStatus: RpcConnectionStatus {
        switch NodePoolService.shared.subscriptionState {
        case .subscribed:
            return .connected
        case .connecting, .failover:
            return .connecting
        case .disconnected, .failed:
            break
        }
        return isRpcSubscribed ? .connected : .disconnected
    }

    var currentSettings: AppSettings {
        settingsViewModel?.settings ?? AppSettings.load()
    }

    // MARK: - Subscription state

    struct QueuedUtxoNotification {
        let parsed: ParsedUtxosChangedNotification
        let txIds: Set<String>
    }

    /// Delay between fallback polls while the subscription is down.
    let pollDelayAfterSync: TimeInterval = 60.0
    var pollTask: Task<Void, Never>?
    var initialSyncTask: Task<Void, Never>?
    var hasCompletedInitialSync = false

    var utxoSubscriptionToken: UUID?
    var isUtxoSubscribed = false {
        didSet {
            isRpcSubscribed = isUtxoSubscribed
            if !isUtxoSubscribed {
                currentConnectedNode = nil
                currentNodeLatencyMs = nil
            }
        }
    }
    var hasEverBeenSubscribed = false
    var lastSubscribedAddresses: Set<String> = []
    var subscriptionRetryTask: Task<Void, Never>?
    /// Consecutive failed subscription retry rounds - drives the capped exponential backoff in
    /// `scheduleSubscriptionRetry` (1s doubling to a 30s cap). Reset when the subscription is up.
    var subscriptionRetryAttempts = 0
    var pendingResubscriptionTask: Task<Void, Never>?
    var subscriptionBalanceRefreshTask: Task<Void, Never>?

    var utxoFetchInFlight = false
    var queuedUtxoNotifications: [QueuedUtxoNotification] = []

    // MARK: - Sending state

    /// Sends run one at a time, so two never pick the same inputs.
    var outgoingTxTail: Task<Void, Never>?
    var cachedUtxos: [UTXO] = []
    var cachedUtxosTimestamp: Date?
    let utxoCacheInterval: TimeInterval = 20
    /// Coins a send from this app has just spent, by outpoint, and until when they stay out: the
    /// node goes on listing them until that spend is in a block, so the next send, Max or fee
    /// would otherwise pick them again and be refused.
    var reservedOutpoints: [String: Date] = [:]
    let spentOutpointHold: TimeInterval = 120

    private var pingLatencyCancellable: AnyCancellable?
    private var nodePoolSubscriptionStateCancellable: AnyCancellable?
    private var nodePoolPrimaryEndpointCancellable: AnyCancellable?
    private var rpcReconnectedObserver: NSObjectProtocol?
    private var ownAddressesCancellable: AnyCancellable?

    private init() {
        observePingLatency()
        observeNodePoolConnectionState()
        observeRpcReconnection()
        observeOwnAddressSet()
    }

    /// A cold-storage account added or removed, or the primary moving to a new spending address:
    /// the live subscription and the push service's watch list follow.
    private func observeOwnAddressSet() {
        ownAddressesCancellable = ColdStorageManager.shared.$accounts.map { _ in () }
            .merge(with: NotificationCenter.default.publisher(for: .spendingPrimaryChanged).map { _ in () })
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.checkAndResubscribeIfNeeded()
                Task { await PushNotificationManager.shared.updateWatchedAddresses() }
            }
    }

    /// Observe NodePoolService ping latency, throttled: it is only shown in the connection-detail
    /// sheet, so once every 2s (latest value) is plenty.
    private func observePingLatency() {
        pingLatencyCancellable = NodePoolService.shared.$lastPingLatencyMs
            .throttle(for: .seconds(2), scheduler: DispatchQueue.main, latest: true)
            .removeDuplicates()
            .sink { [weak self] latencyMs in
                guard let latency = latencyMs else { return }
                self?.currentNodeLatencyMs = latency
            }
    }

    /// Observe NodePool subscription/primary endpoint as the source of truth for status UI
    private func observeNodePoolConnectionState() {
        nodePoolPrimaryEndpointCancellable = NodePoolService.shared.$primaryEndpoint
            .receive(on: DispatchQueue.main)
            .sink { [weak self] endpoint in
                self?.currentConnectedNode = endpoint?.url
            }

        nodePoolSubscriptionStateCancellable = NodePoolService.shared.$subscriptionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .subscribed:
                    if !self.isUtxoSubscribed { self.isUtxoSubscribed = true }
                    self.pollTask?.cancel()
                    self.pollTask = nil
                case .disconnected, .failed:
                    if self.isUtxoSubscribed { self.isUtxoSubscribed = false }
                    // Lost mid-session (a network change while nodes were down): the balance keeps
                    // moving by polling while `UtxoSubscriptionManager` keeps retrying.
                    guard self.hasCompletedInitialSync, WalletManager.shared.currentWallet != nil else { break }
                    if self.pollTask == nil { self.startFallbackPolling() }
                case .connecting, .failover:
                    break
                }
            }
    }

    /// Re-subscribe once the connection comes back. What arrived meanwhile is found by
    /// `AddressActivityNotifier`'s catch-up on `.rpcSubscriptionsRestored`.
    private func observeRpcReconnection() {
        rpcReconnectedObserver = NotificationCenter.default.addObserver(
            forName: .rpcReconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            AppLog.log("[WalletService] RPC reconnected - re-subscribing to UTXOs...")
            Task { @MainActor in
                self?.isUtxoSubscribed = false
                await self?.setupUtxoSubscription()
            }
        }
    }

    /// Reset for a new/imported wallet or a logout: stops the old wallet's sync work.
    func resetForNewWallet() {
        pollTask?.cancel()
        pollTask = nil
        initialSyncTask?.cancel()
        initialSyncTask = nil
        subscriptionRetryTask?.cancel()
        subscriptionRetryTask = nil
        pendingResubscriptionTask?.cancel()
        pendingResubscriptionTask = nil
        subscriptionBalanceRefreshTask?.cancel()
        subscriptionBalanceRefreshTask = nil
        lastSubscribedAddresses = []
        isUtxoSubscribed = false
        hasEverBeenSubscribed = false
        hasCompletedInitialSync = false
        cachedUtxos = []
        cachedUtxosTimestamp = nil
        reservedOutpoints = [:]
        queuedUtxoNotifications = []
    }

    // MARK: - Sync

    /// Subscribe to the wallet's own addresses for live balance and "Received KAS", with a slow
    /// balance poll as the fallback when the node can't stream. Safe to call again (app return):
    /// it only resubscribes when the subscription is down.
    func startPolling() {
        guard WalletManager.shared.currentWallet != nil else { return }
        if hasCompletedInitialSync {
            if !isUtxoSubscribed {
                Task { await self.setupUtxoSubscription() }
                if pollTask == nil { startFallbackPolling() }
            }
            return
        }
        if let task = initialSyncTask, !task.isCancelled { return }
        AppLog.log("%@", "[WalletService] Starting wallet sync")
        initialSyncTask = Task {
            await setupUtxoSubscription()
            hasCompletedInitialSync = true
            lastSuccessfulSyncDate = Date()
            if !isUtxoSubscribed { startFallbackPolling() }
        }
    }

    func startFallbackPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.pollDelayAfterSync * 1_000_000_000))
                guard !Task.isCancelled else { break }
                // The loop stays alive in the background, but does no network work there.
                guard UIApplication.shared.applicationState == .active else { continue }
                _ = try? await WalletManager.shared.refreshBalance(force: true)
                await AddressActivityNotifier.shared.runCatchUpIfNeeded()
                self.lastSuccessfulSyncDate = Date()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        initialSyncTask?.cancel()
        initialSyncTask = nil
        subscriptionRetryTask?.cancel()
        subscriptionRetryTask = nil
        pendingResubscriptionTask?.cancel()
        pendingResubscriptionTask = nil
        subscriptionBalanceRefreshTask?.cancel()
        subscriptionBalanceRefreshTask = nil

        if let token = utxoSubscriptionToken {
            NodePoolService.shared.removeNotificationHandler(token)
            utxoSubscriptionToken = nil
        }
        NodePoolService.shared.unsubscribeUtxosChanged()
        isUtxoSubscribed = false
        AppLog.log("[WalletService] Polling and UTXO subscription stopped")
    }

    /// Every address the live subscription watches: the chatting address plus the spending and
    /// cold-storage addresses `AddressActivityNotifier` tracks.
    private func addressesToSubscribe(walletAddress: String) -> Set<String> {
        var addresses = AddressActivityNotifier.shared.watchedOwnAddresses()
        addresses.insert(walletAddress)
        return addresses
    }

    func setupUtxoSubscription() async {
        guard let wallet = WalletManager.shared.currentWallet else {
            subscriptionRetryTask?.cancel()
            subscriptionRetryTask = nil
            return
        }

        if let token = utxoSubscriptionToken {
            NodePoolService.shared.removeNotificationHandler(token)
            utxoSubscriptionToken = nil
        }
        isUtxoSubscribed = false

        do {
            try await connectRpcIfNeeded()
            let nodePool = NodePoolService.shared
            let addressList = Array(addressesToSubscribe(walletAddress: wallet.publicAddress))
            try await nodePool.subscribeUtxosChanged(addresses: addressList)

            // A run cancelled while it waited, or one for a wallet that is no longer current,
            // must not put a handler back.
            guard !Task.isCancelled, WalletManager.shared.currentWallet?.publicAddress == wallet.publicAddress else {
                AppLog.log("[WalletService] setupUtxoSubscription: superseded while subscribing; no handler added")
                return
            }

            // Two setups overlapping across the await above would each add a handler - every batch
            // processed twice - so whatever another run registered in the meantime goes first.
            if let token = utxoSubscriptionToken {
                nodePool.removeNotificationHandler(token)
            }
            utxoSubscriptionToken = nodePool.addNotificationHandler { [weak self] notification, payload in
                guard let self = self, notification == .utxosChanged else { return }
                self.handleUtxoChangeNotification(payload: payload)
            }

            isUtxoSubscribed = true
            hasEverBeenSubscribed = true
            subscriptionRetryAttempts = 0
            subscriptionRetryTask?.cancel()
            subscriptionRetryTask = nil

            if pollTask != nil {
                pollTask?.cancel()
                pollTask = nil
                AppLog.log("[WalletService] Stopped fallback polling - using real-time notifications")
            }

            currentConnectedNode = nodePool.connectedNodeURL
            currentNodeLatencyMs = nodePool.lastPingLatencyMs
            lastSubscribedAddresses = Set(addressList)
            lastSuccessfulSyncDate = Date()
            AppLog.log("[WalletService] Real-time notifications active for %d addresses", addressList.count)
            scheduleBalanceRefreshAfterSubscriptionEnabled()
        } catch {
            AppLog.log("[WalletService] RPC subscription failed: %@", error.localizedDescription)
            isUtxoSubscribed = false
            scheduleSubscriptionRetry()
        }
    }

    func scheduleSubscriptionRetry() {
        guard WalletManager.shared.currentWallet != nil else {
            subscriptionRetryTask?.cancel()
            subscriptionRetryTask = nil
            return
        }
        subscriptionRetryTask?.cancel()

        // Capped exponential backoff (1s -> 2s -> 4s ... 30s cap): a dead pool (airplane mode,
        // captive portal, node outage) must not burn a full-pool attempt every second.
        let delaySeconds = min(30.0, pow(2.0, Double(subscriptionRetryAttempts)))
        subscriptionRetryAttempts += 1

        subscriptionRetryTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await setupUtxoSubscription()
            guard !Task.isCancelled else { return }
            if !isUtxoSubscribed {
                scheduleSubscriptionRetry()
            }
        }
    }

    func scheduleBalanceRefreshAfterSubscriptionEnabled() {
        subscriptionBalanceRefreshTask?.cancel()
        subscriptionBalanceRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let delaysNs: [UInt64] = [0, 500_000_000, 1_500_000_000]
            for delayNs in delaysNs {
                if delayNs > 0 {
                    try? await Task.sleep(nanoseconds: delayNs)
                }
                guard !Task.isCancelled, self.isUtxoSubscribed else { return }
                if (try? await WalletManager.shared.refreshBalance(force: true)) != nil { return }
            }
        }
    }

    func setupUtxoSubscriptionAfterReconnect() async {
        await setupUtxoSubscription()
    }

    /// With remote push on, the subscription is dropped in the background (the push service
    /// covers receives there) and brought back on return.
    func pauseUtxoSubscriptionForRemotePush() {
#if targetEnvironment(macCatalyst)
        return
#else
        guard currentSettings.notificationMode == .remotePush else { return }
        if let token = utxoSubscriptionToken {
            NodePoolService.shared.removeNotificationHandler(token)
            utxoSubscriptionToken = nil
        }
        NodePoolService.shared.unsubscribeUtxosChanged()
        isUtxoSubscribed = false
        AppLog.log("[WalletService] Remote push active - UTXO subscription paused for background")
#endif
    }

    func resumeUtxoSubscriptionForRemotePush() async {
#if targetEnvironment(macCatalyst)
        return
#else
        guard currentSettings.notificationMode == .remotePush else { return }
        guard utxoSubscriptionToken == nil && !isUtxoSubscribed else { return }
        await setupUtxoSubscription()
#endif
    }

    /// Resubscribe when the watched address set changed (a new spending slot, a cold-storage
    /// import or removal).
    func checkAndResubscribeIfNeeded() {
        guard isUtxoSubscribed, let wallet = WalletManager.shared.currentWallet else { return }
        guard addressesToSubscribe(walletAddress: wallet.publicAddress) != lastSubscribedAddresses else { return }
        pendingResubscriptionTask?.cancel()
        pendingResubscriptionTask = Task {
            await setupUtxoSubscription()
        }
    }

    func connectRpcIfNeeded(timeout: TimeInterval = 30.0) async throws {
        let rpcManager = NodePoolService.shared
        if rpcManager.isConnected { return }
        let settings = currentSettings
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await rpcManager.connect(network: settings.networkType)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw KasiaError.networkError("RPC connection timeout")
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    // MARK: - Live UTXO batches

    func handleUtxoChangeNotification(payload: Data) {
        guard let parsed = GrpcNotificationParser.parseUtxosChangedNotification(payload) else { return }
        enqueueUtxoNotification(parsed)
        processQueuedUtxoNotificationsIfNeeded()
    }

    func enqueueUtxoNotification(_ parsed: ParsedUtxosChangedNotification) {
        let txIds = Set(parsed.added.map(\.transactionId)).union(parsed.removed.map(\.transactionId))
        guard !txIds.isEmpty else { return }

        if let existingIndex = queuedUtxoNotifications.firstIndex(where: { !$0.txIds.isDisjoint(with: txIds) }) {
            let existing = queuedUtxoNotifications[existingIndex]
            // one entry per outpoint: the same batch delivered twice must not count an output
            // twice ("Received 10 KAS" for 5, IOS-071)
            func unique(_ entries: [ParsedUtxoEntry]) -> [ParsedUtxoEntry] {
                var seen = Set<String>()
                return entries.filter { seen.insert("\($0.transactionId):\($0.outputIndex)").inserted }
            }
            let merged = ParsedUtxosChangedNotification(
                added: unique(existing.parsed.added + parsed.added),
                removed: unique(existing.parsed.removed + parsed.removed)
            )
            queuedUtxoNotifications[existingIndex] = QueuedUtxoNotification(parsed: merged, txIds: existing.txIds.union(txIds))
        } else {
            queuedUtxoNotifications.append(QueuedUtxoNotification(parsed: parsed, txIds: txIds))
        }
    }

    func processQueuedUtxoNotificationsIfNeeded() {
        guard !utxoFetchInFlight, !queuedUtxoNotifications.isEmpty else { return }
        utxoFetchInFlight = true
        let queued = queuedUtxoNotifications.removeFirst()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.utxoFetchInFlight = false
                self.processQueuedUtxoNotificationsIfNeeded()
            }
            await self.processParsedUtxoChangeNotification(queued.parsed)
        }
    }

    /// "Received KAS" for the wallet's own addresses (self-sends suppressed: any input spending
    /// from our addresses) and the live balance.
    func processParsedUtxoChangeNotification(_ parsed: ParsedUtxosChangedNotification) async {
        guard WalletManager.shared.currentWallet != nil else { return }
        var removedByTxId: [String: Set<String>] = [:]
        for entry in parsed.removed {
            if let address = entry.address {
                removedByTxId[entry.transactionId, default: []].insert(address)
            }
        }
        AddressActivityNotifier.shared.postUtxoActivityEvent(parsed: parsed, removedByTxId: removedByTxId)
        AddressActivityNotifier.shared.handleLiveUtxoAdditions(parsed: parsed)
        _ = try? await WalletManager.shared.refreshBalance(force: true)
    }
}

/// Node connection + ping latency, split out of WalletService so their frequent (~2s) updates
/// re-render only the connection-detail screen instead of every WalletService observer.
@MainActor
final class NodeConnectionInfo: ObservableObject {
    static let shared = NodeConnectionInfo()
    @Published var currentConnectedNode: String?
    @Published var currentNodeLatencyMs: Int?
    private init() {}
}
