import Foundation

/// The Wallet tab's pull to refresh, beyond the quick balance read (owner's call, 2026-11-20): a
/// pull scans the account's addresses for balances, the same sweeps as Manage Addresses' Discover
/// Addresses (`WalletManager.discoverSpendingAddresses`: regular and quantum, the first thousand
/// whatever the gaps, further while something turns up) and Manage kUSDT's Discover
/// (`TokenWallet.discoverHoldings`). New addresses found past the revealed range are shown, so they
/// count in the balances; one the person hid stays hidden (`.newOnly`): a pull is not a decision
/// to undo their Hide. At most one scan per account every `minInterval` (the balance read still
/// happens on every pull), and one at a time per account: a pull while one is running doesn't
/// start another, and the sweep itself is shared with Discover and a restore.
@MainActor
final class AddressScan {
    static let shared = AddressScan()

    /// A full sweep is a thousand addresses' activity, balances and name checks: pulling again
    /// a minute later finds the same thing.
    private static let minInterval: TimeInterval = 10 * 60

    /// Accounts with a scan running. Per account, so a scan still finishing for an account just
    /// switched away from never holds up a pull on the new one.
    private var running: Set<String> = []
    /// When each account's last scan started.
    private var startedAt: [String: Date] = [:]

    /// Runs the scan to the end (it belongs to the account it started for), then refreshes the
    /// balances that read what it found.
    func run() async {
        guard let account = WalletManager.shared.currentWallet?.publicAddress,
              !running.contains(account) else { return }
        if let last = startedAt[account], Date().timeIntervalSince(last) < Self.minInterval { return }
        running.insert(account)
        startedAt[account] = Date()
        defer { running.remove(account) }

        await WalletManager.shared.discoverSpendingAddresses(reveal: .newOnly)
        guard WalletManager.shared.currentWallet?.publicAddress == account else { return }
        await HotWalletBalance.shared.refresh(force: true)

        let tokens = TokenWallet.shared
        for token in tokens.tokens {
            guard WalletManager.shared.currentWallet?.publicAddress == account else { return }
            _ = await tokens.discoverHoldings(of: token) { _, _ in }
        }
    }
}
