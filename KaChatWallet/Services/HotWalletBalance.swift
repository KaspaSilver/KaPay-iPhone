import Foundation

/// What the whole hot wallet holds: the chatting address plus every spending address, hidden ones
/// included. Cold storage isn't part of it. The top bar on every tab and the Wallet tab's balance
/// card all read this, so they can't disagree.
@MainActor
final class HotWalletBalance: ObservableObject {
    static let shared = HotWalletBalance()

    /// The account `spending` was read for.
    private var account: String?
    /// Every spending address together, for `account`. Nil until the first read lands.
    @Published private var spending: UInt64?

    private var lastReadAt: Date?
    /// Only the newest read counts: an older one finishing late can't put an old figure back.
    private var readGeneration = 0
    private var activityTask: Task<Void, Never>?
    /// The read in flight, shared: every tab's top bar, the Wallet tab and the activity refresh
    /// ask at once, and each used to start its own read and throw away the others' (the
    /// generation check), so the loops in `refreshUntilKnown` kept each other a dash.
    private var inFlight: (id: UUID, account: String, startedAt: Date, task: Task<Void, Never>)?
    /// When funds last moved (`noteActivity`): a read that started before it may not show them.
    private var lastActivityAt = Date.distantPast

    /// Each tab's top bar asks when it appears; this keeps tab switches from reading each time.
    /// Arriving funds refresh at once.
    private static let minReadInterval: TimeInterval = 30
    private static let unknownRetryNanoseconds: UInt64 = 5_000_000_000

    private init() {
        NotificationCenter.default.addObserver(
            forName: .ownAddressUtxoActivity,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in HotWalletBalance.shared.noteActivity() }
        }
    }

    /// `wallet`'s spending addresses together, or nil until they're known.
    func spendingSompi(for wallet: Wallet?) -> UInt64? {
        guard let wallet, wallet.publicAddress == account else { return nil }
        return spending
    }

    /// The whole hot wallet, or nil until both parts are known: a total missing one of them would
    /// read as the whole balance.
    func totalSompi(for wallet: Wallet?) -> UInt64? {
        guard let wallet, let chatting = wallet.balanceSompi, let spending = spendingSompi(for: wallet) else { return nil }
        return chatting + spending
    }

    /// Reads the spending addresses, in one call. A failed read keeps what it last knew.
    func refresh(force: Bool = false) async {
        let walletManager = WalletManager.shared
        let address = walletManager.currentWallet?.publicAddress
        if address != account {
            account = address
            spending = nil
            lastReadAt = nil
        }
        guard let address else { return }
        if !force, let lastReadAt, Date().timeIntervalSince(lastReadAt) < Self.minReadInterval { return }

        // Join the read already running for this account rather than start another, unless funds
        // moved after it started: then its figure may be from before, and one more read follows.
        while let current = inFlight, current.account == address {
            await current.task.value
            if current.startedAt >= lastActivityAt { return }
            if inFlight?.id == current.id { inFlight = nil }
        }

        let id = UUID()
        let task = Task { @MainActor in
            await self.read(for: address)
            if self.inFlight?.id == id { self.inFlight = nil }
        }
        inFlight = (id, address, Date(), task)
        await task.value
    }

    /// One read of every spending address, in one call. A failed read keeps what it last knew.
    private func read(for address: String) async {
        let walletManager = WalletManager.shared
        let all = walletManager.allSpendingAddresses()
        guard !all.isEmpty else { return }
        readGeneration += 1
        let generation = readGeneration
        guard let utxos = try? await NodePoolService.shared.getUtxosByAddresses(all) else {
            AppLog.log("%@", "[HotWalletBalance] Reading the spending addresses failed; keeping the last known figure")
            return
        }
        guard generation == readGeneration, walletManager.currentWallet?.publicAddress == address else { return }
        let total = utxos.reduce(UInt64(0)) { $0 + $1.amount }
        // Published only when it changed: every top bar and the Wallet tab redraw on a write,
        // and most reads find the same figure.
        if spending != total { spending = total }
        lastReadAt = Date()
    }

    /// For a top bar's `.task`: refreshes, then keeps trying while the figure is unknown (the node
    /// may not be connected yet just after launch), so it doesn't stay a dash.
    func refreshUntilKnown() async {
        await refresh()
        let walletManager = WalletManager.shared
        while !Task.isCancelled, spendingSompi(for: walletManager.currentWallet) == nil,
              !walletManager.allSpendingAddresses().isEmpty {
            try? await Task.sleep(nanoseconds: Self.unknownRetryNanoseconds)
            guard !Task.isCancelled else { return }
            await refresh(force: true)
        }
    }

    /// One transaction can bring several UTXO changes: they make one read.
    private func noteActivity() {
        lastActivityAt = Date()
        activityTask?.cancel()
        activityTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await refresh(force: true)
        }
    }
}
