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
        guard address != nil else { return }
        if !force, let lastReadAt, Date().timeIntervalSince(lastReadAt) < Self.minReadInterval { return }

        let all = walletManager.allSpendingAddresses()
        guard !all.isEmpty else { return }
        readGeneration += 1
        let generation = readGeneration
        guard let utxos = try? await NodePoolService.shared.getUtxosByAddresses(all) else {
            AppLog.log("%@", "[HotWalletBalance] Reading the spending addresses failed; keeping the last known figure")
            return
        }
        guard generation == readGeneration, walletManager.currentWallet?.publicAddress == address else { return }
        spending = utxos.reduce(UInt64(0)) { $0 + $1.amount }
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
        activityTask?.cancel()
        activityTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await refresh(force: true)
        }
    }
}
