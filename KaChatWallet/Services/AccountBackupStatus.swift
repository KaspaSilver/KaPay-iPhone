import Foundation

/// Which accounts on this device still owe the backup steps (`AccountBackupView`). An account
/// created here starts with it owed, since nobody has seen its seed phrase yet; an imported one
/// never does, since whoever typed the words has them. Kept for an account's addresses on both
/// networks, so a switch to testnet doesn't lose or bring back the card.
///
/// Finishing the backup steps also starts a timer: six months later the Backup Hygiene card asks
/// for a few of the words again (`BackupHygieneView`), and passing that or redoing the backup
/// starts it over. An account that never did the backup steps has no timer.
@MainActor
final class AccountBackupStatus: ObservableObject {
    static let shared = AccountBackupStatus()

    private static let storageKey = "kapay_backup_pending_addresses"
    private static let confirmedKey = "kapay_backup_confirmed_at"
    private static let hygieneMonths = 6

    @Published private(set) var pendingAddresses: Set<String>
    /// Address -> when its backup was last finished or checked, in seconds since 1970.
    @Published private(set) var confirmedAt: [String: Double]

    private init() {
        pendingAddresses = Set(UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? [])
        confirmedAt = (UserDefaults.standard.dictionary(forKey: Self.confirmedKey) as? [String: Double]) ?? [:]
    }

    /// Six months since this account's backup was last finished or checked.
    func isHygieneDue(_ address: String?, now: Date = Date()) -> Bool {
        guard let address, !isPending(address), let stamp = confirmedAt[address],
              let due = Calendar.current.date(byAdding: .month, value: Self.hygieneMonths,
                                              to: Date(timeIntervalSince1970: stamp)) else { return false }
        return now >= due
    }

    /// The backup steps were finished or the words checked: nothing is owed, and the six months
    /// start over.
    func markConfirmed(_ address: String) {
        markDone(address)
        let now = Date().timeIntervalSince1970
        for variant in WalletManager.accountAddressVariants(address) { confirmedAt[variant] = now }
        UserDefaults.standard.set(confirmedAt, forKey: Self.confirmedKey)
    }

    /// The account is gone from this device.
    func forget(_ address: String) {
        markDone(address)
        for variant in WalletManager.accountAddressVariants(address) { confirmedAt[variant] = nil }
        UserDefaults.standard.set(confirmedAt, forKey: Self.confirmedKey)
    }

    func isPending(_ address: String?) -> Bool {
        guard let address else { return false }
        return pendingAddresses.contains(address)
    }

    func markPending(_ address: String) {
        pendingAddresses.formUnion(WalletManager.accountAddressVariants(address))
        save()
    }

    func markDone(_ address: String) {
        pendingAddresses.subtract(WalletManager.accountAddressVariants(address))
        save()
    }

    private func save() {
        UserDefaults.standard.set(Array(pendingAddresses), forKey: Self.storageKey)
    }
}
