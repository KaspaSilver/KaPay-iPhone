import Foundation
import CryptoKit
import P256K

struct SavedAccountSummary: Identifiable, Equatable, Codable {
    var alias: String
    let publicAddress: String
    let publicKey: String

    var id: String { publicAddress }

    var displayAlias: String {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Saved Account" : trimmed
    }

    var shortPublicAddress: String {
        guard publicAddress.count > 16 else { return publicAddress }
        return "\(publicAddress.prefix(10))...\(publicAddress.suffix(6))"
    }

    var formattedPublicAddress: String {
        if publicAddress.contains(":") {
            return publicAddress
        }
        return "kaspa:\(publicAddress)"
    }

    var shortPublicKey: String {
        guard publicKey.count > 24 else { return publicKey }
        return "\(publicKey.prefix(12))...\(publicKey.suffix(8))"
    }

    init(alias: String, publicAddress: String, publicKey: String) {
        self.alias = alias
        self.publicAddress = publicAddress
        self.publicKey = publicKey
    }

    init(wallet: Wallet) {
        self.alias = wallet.alias
        self.publicAddress = wallet.publicAddress
        self.publicKey = wallet.publicKey
    }
}

/// Identity derivation-path family of the wallet a seed phrase was imported from - the
/// KasWare-style "which wallet is this seed from?" selection. Different Kaspa wallets put the
/// same seed's funds and KNS domains on different BIP32 branches; picking the right family at
/// import is what lets KaChat find them. Rules replicated exactly from KasWare's
/// ADDRESS_TYPES/RESTORE_WALLETS constants and its `hd-keyring.ts` `_pubkeyFromIndex` derivation
/// switch (see external reference /Users/restosaved/extension):
///
/// - `kaspaStandard`: m/44'/111111'/0'/0/{i} (receive chain, normal final index). KaChat's own
///   family, also KasWare, Kaspium, Core Golang CLI, OKX and Ledger seed imports.
/// - `kaspaLegacy972`: m/44'/972/0'/0'/{i'} - Kaspanet Web Wallet and KDX. NOTE: 972 is
///   deliberately NOT hardened (KasWare's hdPath string "m/44'/972/0'" has no apostrophe on 972
///   and their keyring derives it normally), while the change level and the final index ARE
///   hardened ("m/44'/972/0'/${dType}'/${i}'").
/// - `chainge`: m/44'/111111'/0'/0' - a single hardened leaf; Chainge wallets have exactly ONE
///   address per seed, so no index scanning applies (only index 0 exists).
/// - `oneKey`: the standard m/44'/111111'/0'/0/{i} key, then a BIP340 taproot-style tweak:
///   negate the private key if its compressed pubkey has an odd Y (0x03 prefix), then add
///   taggedHash("TapTweak", xOnlyPubkey) mod n. Address comes from the tweaked key.
///
/// Raw values are persisted (UserDefaults, keyed per derived address) - do not rename cases.
/// An address the import's passphrase step found on the identity chain.
struct FoundChattingAddress: Identifiable, Equatable {
    let index: Int
    let address: String
    let balanceSompi: UInt64

    var id: Int { index }
}

enum WalletSourceFamily: String, Codable, CaseIterable {
    case kaspaStandard
    case kaspaLegacy972
    case chainge
    case oneKey

    /// Chainge wallets have exactly one address.
    var supportsIndexScan: Bool {
        self != .chainge
    }

    /// Human-readable base path, for the import chooser UI.
    var pathDescription: String {
        switch self {
        case .kaspaStandard: return "m/44'/111111'/0'"
        case .kaspaLegacy972: return "m/44'/972/0'"
        case .chainge: return "m/44'/111111'/0'/0'"
        case .oneKey: return "m/44'/111111'/0' (OneKey)"
        }
    }
}

@MainActor
final class WalletManager: ObservableObject {
    static let shared = WalletManager()

    @Published var currentWallet: Wallet?
    @Published var isLoading = true
    @Published var error: KasiaError?
    /// Not @Published: nothing renders it, and each toggle published the whole WalletManager -
    /// which every tab root observes - twice per balance refresh.
    var isBalanceRefreshing = false
    /// When `refreshBalance` last finished for which address, so the half-dozen callers that
    /// fire together on a tab switch share one network round trip.
    private var lastBalanceRefresh: (address: String, at: Date, total: UInt64)?
    @Published private(set) var hasStoredWallet = false
    /// The stored wallet whose keys this device does not hold - see `WalletRecoveryView`. Set
    /// only when both the private key and the seed were looked up and found absent, never on
    /// a lookup that merely failed.
    @Published private(set) var walletNeedingKeyRecovery: Wallet?
    /// A saved account whose sign-in just failed because this device has no keys for it (its
    /// snapshot is from another phone). The accounts screen answers with the recovery sheet -
    /// "enter its recovery phrase" - instead of a bare error (the state after an iPhone restore,
    /// for every account that was not the active one).
    @Published private(set) var savedAccountNeedingKeys: SavedAccountSummary?

    func clearSavedAccountNeedingKeys() { savedAccountNeedingKeys = nil }
    /// Why the last saved-account sign-in failed. Held here rather than on the accounts screen:
    /// `loadWallet` shows the loading screen, which replaces the accounts screen, so a message
    /// kept there was lost with it. The rebuilt screen shows it.
    @Published private(set) var signInFailureMessage: String?

    func clearSignInFailure() { signInFailureMessage = nil }
    @Published private(set) var isLoggedOut = false
    @Published private(set) var savedAccounts: [SavedAccountSummary] = []

    /// True from the moment `createWallet` starts generating a brand-new wallet until
    /// `CreateWalletView`'s "Continue to App" button clears it (after the user confirms they've
    /// written down the seed phrase) - `ContentView`/`LaunchRouter` treat this as "stay on
    /// onboarding" even though `currentWallet` is already non-nil by then, closing the race where
    /// `currentWallet` (set inside `importWallet`, well before the seed-phrase screen is shown or
    /// confirmed) would otherwise let top-level routing jump straight to `MainTabView` and tear
    /// down the seed-phrase screen before the user ever saw it. Never set for `importWallet`
    /// (typing in an existing phrase needs no review step). Transient/in-memory only.
    @Published var isAwaitingSeedPhraseConfirmation = false

    /// Per-wallet ("account") toggle for whether the "Setup Guide" re-entry points (the Profile
    /// tab's "Welcome Guide" row and the "Edit KaChat Profile" screen's "Setup Guide" button) are
    /// shown - scoped to `currentWallet?.publicAddress` rather than global `AppSettings`, mirroring
    /// `spendingDefaultsKey` in `WalletManager+SpendingAddresses.swift`, so switching to a
    /// different account on the same device doesn't carry the choice over. Defaults to `true`
    /// (unset key) to match pre-existing behavior for anyone who had these guides visible before
    /// this toggle existed.
    var showSetupGuides: Bool {
        get {
            guard let key = showSetupGuidesDefaultsKey else { return true }
            return UserDefaults.standard.object(forKey: key) as? Bool ?? true
        }
        set {
            guard let key = showSetupGuidesDefaultsKey else { return }
            UserDefaults.standard.set(newValue, forKey: key)
            objectWillChange.send()
        }
    }

    private var showSetupGuidesDefaultsKey: String? {
        guard let address = currentWallet?.publicAddress else { return nil }
        return "kachat_show_setup_guides_\(address)"
    }

    private let keychainService = KeychainService.shared
    private let bip39 = BIP39.shared
    private let nodePool = NodePoolService.shared
    private let balanceCachePrefix = "kachat_balance_cache_"
    private let logoutFlagKey = "kachat_session_logged_out"
    private let savedAccountsKey = "kachat_saved_accounts"
    /// Set on the first launch of an install: UserDefaults is deleted with the app, the Keychain isn't.
    private let installSeenKey = "kapay_install_seen"

    private init() {
        LaunchTrace.startWatchdog()
        LaunchTrace.mark("WalletManager.init")
        // first: gets UserDefaults back under iOS's 4 MB limit before anything else writes
        DerivedAddressStore.prepare()
        Self.trimUserDefaults()
        LaunchTrace.mark("UserDefaults trimmed")
        savedAccounts = loadSavedAccountsFromStorage()
        hasStoredWallet = !savedAccounts.isEmpty
        logPrivateKeyStorageStatus()
        Task {
            await loadWallet()
        }
    }

    /// Keeps the app's UserDefaults well under iOS's 4 MB limit - past it iOS refuses EVERY
    /// write the app makes, settings and chain bounds included (seen on a real device,
    /// 2026-10-20). Drops KaChat's chat-list snapshots and payment-pool state no code reads,
    /// and, if iOS refused those removals (the domain still over the limit), writes the trimmed
    /// domain back in one go. Until the domain is healthy it logs its size and largest keys on
    /// every launch.
    private static let defaultsTrimmedKey = "kachat_defaults_trimmed_v1"
    private static let deadDefaultsPrefixes = ["kachat_payment_pool_state_", "kachat_chat_list_snapshot_"]

    private static func trimUserDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: defaultsTrimmedKey), let id = Bundle.main.bundleIdentifier else { return }
        var dropped = 0
        for key in (defaults.persistentDomain(forName: id) ?? [:]).keys
        where deadDefaultsPrefixes.contains(where: { key.hasPrefix($0) }) {
            defaults.removeObject(forKey: key)
            dropped += 1
        }
        guard var domain = defaults.persistentDomain(forName: id) else { return }
        // A refused removal leaves the key in place: replace the whole domain with the trimmed
        // copy - one write that is itself under the limit.
        let movedPrefixes = deadDefaultsPrefixes + ["kachat_spending_derived_addresses_"]
        let refused = domain.keys.filter { key in movedPrefixes.contains { key.hasPrefix($0) } }
        if !refused.isEmpty {
            refused.forEach { domain.removeValue(forKey: $0) }
            defaults.setPersistentDomain(domain, forName: id)
            AppLog.log("[WalletManager] UserDefaults refused %d removals; rewrote the trimmed domain", refused.count)
        }
        let after = defaults.persistentDomain(forName: id) ?? [:]
        func size(_ value: Any) -> Int {
            (try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0).count) ?? 0
        }
        let total = size(after)
        let largest = after.map { ($0.key, size($0.value)) }.sorted { $0.1 > $1.1 }.prefix(8)
            .map { "\($0.0)=\($0.1 / 1024)KB" }.joined(separator: ", ")
        AppLog.log("[WalletManager] UserDefaults %d KB after trimming (dropped %d dead keys). Largest: %@",
                   total / 1024, dropped, largest)
        if total < 2_500_000 {
            defaults.set(true, forKey: defaultsTrimmedKey)
        }
    }

    // MARK: - Public Methods

    func loadWallet(force: Bool = false) async {
        isLoading = true
        noteKeysLeftByEarlierInstallIfNeeded()
        // every account's words onto the unlocked-only rule, not just the ones opened (as KaPost)
        keychainService.tightenAllSeedItems()
        defer { isLoading = false }

        do {
            LaunchTrace.mark("loadWallet: reading wallet record")
            // Try to load from keychain first
            if let storedWallet = try keychainService.loadWallet() {
                let wallet = withSavedAlias(storedWallet)
                if UserDefaults.standard.bool(forKey: logoutFlagKey), !force {
                    updateSavedAccounts(from: wallet)
                    currentWallet = nil
                    isBalanceRefreshing = false
                    isLoggedOut = true
                    AddressBookManager.shared.setActiveWalletAddress(nil)
                    ColdStorageManager.shared.setCurrentWallet(nil)
                    PortfolioManager.shared.setCurrentWallet(nil)
                    PortfolioViewModel.shared.setCurrentWallet(nil)
                    NextcloudService.shared.setCurrentWallet(nil)
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
                    return
                }

                UserDefaults.standard.removeObject(forKey: logoutFlagKey)
                isLoggedOut = false
                LaunchTrace.mark("loadWallet: key material check")
                // A readable snapshot of this account (filed on this phone) puts its keys back
                // first: the recovery screen is only for keys that are really gone, and its
                // Remove would erase a snapshot that could still have restored them.
                if case .missing = keychainService.keyMaterialStatus(), !restoreKeysFromSnapshot(for: wallet) {
                    // The record survived but the keys did not (an iPhone restore, typically).
                    // Opening the app with an address that cannot sign or decrypt looked like a
                    // working wallet in which everything silently failed.
                    AppLog.log("%@", "[WalletManager] Wallet record present but no key material on this device; asking for the recovery phrase")
                    updateSavedAccounts(from: wallet)
                    walletNeedingKeyRecovery = wallet
                    currentWallet = nil
                    isBalanceRefreshing = false
                    return
                }
                walletNeedingKeyRecovery = nil
                LaunchTrace.mark("loadWallet: reconcile")
                let canonicalWallet = walletOnCurrentNetwork(reconcileWalletWithLocalKeyMaterialIfNeeded(wallet))
                updateSavedAccounts(from: canonicalWallet)
                LaunchTrace.mark("loadWallet: snapshot keys")
                snapshotStoredWalletIfPossible()
                LaunchTrace.mark("loadWallet: snapshot done")
                var updated = canonicalWallet
                if let cached = loadCachedBalance(for: canonicalWallet.publicAddress) {
                    updated.balanceSompi = cached
                }
                self.currentWallet = updated
                migrateSpendingBoundsIfNeeded()
                isBalanceRefreshing = true
                AddressBookManager.shared.setActiveWalletAddress(canonicalWallet.publicAddress)
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
                isLoading = false
                LaunchTrace.mark("loadWallet: wallet set, switching services")
                LaunchTrace.mark("loadWallet: services switched")
                ColdStorageManager.shared.setCurrentWallet(canonicalWallet.publicAddress)
                PortfolioManager.shared.setCurrentWallet(canonicalWallet.publicAddress)
                PortfolioViewModel.shared.setCurrentWallet(canonicalWallet.publicAddress)
                NextcloudService.shared.setCurrentWallet(canonicalWallet.publicAddress)
                LaunchTrace.mark("loadWallet: done")
                Task { _ = try? await refreshBalance(force: true) }
                return
            }

            // No stored wallet - clear logout state and return to onboarding.
            hasStoredWallet = !savedAccounts.isEmpty
            isLoggedOut = false
            currentWallet = nil
            isBalanceRefreshing = false
            UserDefaults.standard.removeObject(forKey: logoutFlagKey)
            AddressBookManager.shared.setActiveWalletAddress(nil)
            ColdStorageManager.shared.setCurrentWallet(nil)
            PortfolioManager.shared.setCurrentWallet(nil)
            PortfolioViewModel.shared.setCurrentWallet(nil)
            NextcloudService.shared.setCurrentWallet(nil)
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        } catch {
            self.error = .keychainError(error.localizedDescription)
        }
    }

    /// Generates a fresh mnemonic for the create-account flow WITHOUT deriving keys or persisting
    /// anything. The wallet is only committed later via `commitCreatedWallet(...)`, once the user
    /// has backed up the phrase and chosen whether to add a BIP39 passphrase. Deferring derivation
    /// is what lets the passphrase - which changes the derived address - be known before we ever
    /// derive or save, so there's no throwaway account to migrate afterwards.
    func generateNewWalletSeedPhrase(wordCount: Int = 24) async throws -> SeedPhrase {
        // Use async version to ensure word list is loaded
        guard let seedPhrase = await bip39.generateMnemonicAsync(wordCount: wordCount) else {
            throw KasiaError.invalidSeedPhrase
        }
        return seedPhrase
    }

    /// Commits a brand-new wallet generated by `generateNewWalletSeedPhrase`: attaches the optional
    /// BIP39 passphrase, derives keys and persists. Import and create both funnel through
    /// `importWallet`, so account setup is identical afterwards. Pass "" for no passphrase.
    @discardableResult
    func commitCreatedWallet(seedPhrase: SeedPhrase, passphrase: String, alias: String) async throws -> Wallet {
        let sp = SeedPhrase(words: seedPhrase.words, passphrase: passphrase.isEmpty ? nil : passphrase)
        // Nobody has seen these words yet: the backup strip stays until they're backed up.
        // Marked inside the import, before the keys are saved, so an app killed mid-create
        // can't leave an account that is never owed its backup.
        return try await importWallet(from: sp, alias: alias, owesBackup: true)
    }

    /// The name a new account gets, renameable later: "My Account", then "My Account 2" and on,
    /// skipping any name a saved account already has.
    func nextDefaultAccountName() -> String {
        let base = AppLocalization.string("My Account")
        let taken = Set(savedAccounts.map { $0.alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    /// - Parameter chattingAddressIndex: derivation index on the identity chain
    ///   (m/44'/111111'/0'/0/<index>) the chatting address should live at. 0 (the default) is the
    ///   standard identity every fresh import/create starts from; a nonzero value is only ever
    ///   passed by `setChattingAddress(index:)` when the user picks a different identity index
    ///   during the import wizard. Persisted per derived address so key-repair and
    ///   seed-fallback paths re-derive the same identity.
    /// - Parameter family: identity derivation-path family of the wallet this seed comes from
    ///   (the KasWare-style source-wallet selection in the import flow). `.kaspaStandard` for
    ///   every create and for imports of KaChat/KasWare/Kaspium/Core CLI/OKX/Ledger seeds.
    ///   Persisted per derived address, exactly like the main-address index.
    /// - Parameter owesBackup: a brand-new account made here (`commitCreatedWallet`): it is
    ///   marked as owing its backup before anything is saved.
    func importWallet(from seedPhrase: SeedPhrase, alias: String = "My Account", chattingAddressIndex: Int = 0, family: WalletSourceFamily = .kaspaStandard, owesBackup: Bool = false) async throws -> Wallet {
        // Validate BIP39 checksum to catch typos in seed phrases
        guard bip39.validateMnemonic(seedPhrase.phrase) else {
            throw KasiaError.invalidSeedPhrase
        }
        guard chattingAddressIndex >= 0 else {
            throw KasiaError.apiError("Invalid chatting address index")
        }

        // Stop any in-flight sync/polling for the *previous* wallet before this new wallet becomes
        // active, so nothing of the old account keeps running across the switch.
        WalletService.shared.stopPolling()

        // Derive keys from seed phrase (once - the private key is reused for storage below and
        // cached in memory so the initial sync doesn't re-read the keychain per message).
        let (publicKey, publicAddress, privateKeyData) = try deriveKeysFromSeed(seedPhrase, chattingIndex: UInt32(chattingAddressIndex), family: family)
        // Persist the index and family before any consumer can hit a seed-fallback derivation
        // path for the new address (getPrivateKey / wallet reconciliation look both up per
        // address).
        persistChattingAddressIndex(chattingAddressIndex, for: publicAddress)
        persistWalletSourceFamily(family, for: publicAddress)
        cachedPrivateKey = (publicAddress, privateKeyData)

        // Determine whether this import is switching to a different account.
        // When user logs out, `currentWallet` is nil but keychain still has the
        // last signed-in account. Use stored account identity to avoid wiping
        // per-account contacts/archived state on same-account re-login.
        let existingStoredAddress = try? keychainService.loadWallet()?.publicAddress
        let previousAddress = currentWallet?.publicAddress ?? existingStoredAddress
        // Compared as an account: the same words entered on the other network are the same
        // account, and must not reset it or delete its contacts.
        let isNewWallet = previousAddress.map { !Self.isSameAccount($0, publicAddress) } ?? true

        let wallet = Wallet(
            publicAddress: publicAddress,
            publicKey: publicKey,
            alias: alias,
            createdAt: accountAddedDate(for: publicAddress)
        )

        if owesBackup { AccountBackupStatus.shared.markPending(publicAddress) }
        do {
            // the account in the active slot must be safely filed before its keys are overwritten
            try snapshotStoredWallet(beforeReplacingWith: publicAddress)

            // Save wallet
            try await saveWallet(wallet, seedPhrase: seedPhrase, privateKey: privateKeyData)
        } catch {
            // nothing was created, so nothing is owed
            if owesBackup { AccountBackupStatus.shared.markDone(publicAddress) }
            // nor kept in memory
            if let cached = cachedPrivateKey, cached.address == publicAddress { cachedPrivateKey = nil }
            throw error
        }
        // The keys are on this phone now: a recovery screen left from before must not come back.
        walletNeedingKeyRecovery = nil

        var updated = wallet
        if let cached = loadCachedBalance(for: wallet.publicAddress) {
            updated.balanceSompi = cached
        }
        self.currentWallet = updated
        isBalanceRefreshing = true
        updateSavedAccounts(from: wallet)
        isLoggedOut = false
        UserDefaults.standard.removeObject(forKey: logoutFlagKey)
        AddressBookManager.shared.setActiveWalletAddress(wallet.publicAddress)
        ColdStorageManager.shared.setCurrentWallet(wallet.publicAddress)
        PortfolioManager.shared.setCurrentWallet(wallet.publicAddress)
        PortfolioViewModel.shared.setCurrentWallet(wallet.publicAddress)
        NextcloudService.shared.setCurrentWallet(wallet.publicAddress)
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)

        // A new/different wallet starts its sync state from scratch.
        if isNewWallet {
            AppLog.log("%@", "[WalletManager] Importing new wallet, resetting sync state")
            WalletService.shared.resetForNewWallet()
        }


        // Ensure realtime sync/subscription starts even if UI lifecycle hooks
        // (e.g. MainTabView.onAppear) do not fire immediately after import.
        WalletService.shared.startPolling()

        Task { _ = try? await refreshBalance(force: true) }
        return wallet
    }

    /// - Parameter passphrase: optional BIP39 passphrase the account was created with. Must match
    ///   exactly to restore the same account; a different (or empty) passphrase silently derives a
    ///   different, empty account. Pass "" for none.
    func importWallet(from phrase: String, alias: String = "My Account", passphrase: String = "", chattingAddressIndex: Int = 0, family: WalletSourceFamily = .kaspaStandard) async throws -> Wallet {
        // Debug: count words
        let words = phrase.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        guard let seedPhrase = SeedPhrase(phrase: phrase, passphrase: passphrase.isEmpty ? nil : passphrase) else {
            throw KasiaError.seedPhraseParsingFailed(wordCount: words.count)
        }
        let wallet = try await importWallet(from: seedPhrase, alias: alias, chattingAddressIndex: chattingAddressIndex, family: family)
        // whoever typed the words has them
        AccountBackupStatus.shared.markConfirmed(wallet.publicAddress)
        // A restored seed finds its spending addresses by itself - legacy and quantum, the same
        // sweep as Manage Addresses' Discover Addresses - so balances and change rotation are
        // right without anyone knowing to tap it (owner's call, 2026-10-21). Only this path: a
        // typed-in recovery phrase; creating or switching accounts doesn't scan.
        Task {
            await self.discoverSpendingAddresses()
            await HotWalletBalance.shared.refresh(force: true)
        }
        return wallet
    }

    /// - Parameter removeRemoteBackup: also delete the encrypted archive on the user's
    ///   Nextcloud. Off unless the user picked the option that names it.
    func deleteWallet(removeRemoteBackup: Bool = false) async throws {
        // The recovery screen's Remove: only while its account is still the one in the active
        // slot with no keys behind it. A recovery left over from before an import (or keys back
        // since) would otherwise erase a working account's keys.
        if currentWallet == nil, let stale = walletNeedingKeyRecovery {
            let stored = try? keychainService.loadWallet()
            guard case .missing = keychainService.keyMaterialStatus(),
                  let stored, Self.isSameAccount(stored.publicAddress, stale.publicAddress) else {
                walletNeedingKeyRecovery = nil
                throw KasiaError.keychainError(AppLocalization.string("This account's keys are on this phone again, so nothing was removed."))
            }
        }
        // the wallet being deleted: the active one, or the one stuck on the recovery screen
        let walletAddressToDelete = (currentWallet ?? walletNeedingKeyRecovery)?.publicAddress
        walletNeedingKeyRecovery = nil

        // Unregister from push notifications before clearing wallet
        await PushNotificationManager.shared.unregister()

        // The user's Nextcloud archive, if asked, while the credentials still exist to
        // authenticate with. The app password goes with the rest of the account's data.
        if removeRemoteBackup, NextcloudService.shared.isConnected {
            try await NextcloudService.shared.deleteRemoteBackup()
        }

        if let walletAddressToDelete {
            await removeLocalData(forAccount: walletAddressToDelete)
        }

        // The Secure Enclave key wraps every saved account's snapshot (and the device id and
        // .kachat commit salts): it goes only with the last
        // account. Otherwise only this account's keys and snapshot are removed. The list lives in
        // UserDefaults, which can miss an account: a snapshot still in the Keychain counts too.
        let isOther = { (address: String) in
            walletAddressToDelete.map { !Self.isSameAccount(address, $0) } ?? true
        }
        let otherAccountsRemain = savedAccounts.contains { isOther($0.publicAddress) }
            || keychainService.accountSnapshotAddresses().contains(where: isOther)
        if otherAccountsRemain {
            for address in walletAddressToDelete.map(Self.accountAddressVariants) ?? [] {
                try? keychainService.deleteAccountSnapshot(publicAddress: address)
            }
            try keychainService.clearCurrentAccountData()
        } else {
            try keychainService.clearAll()
        }
        if let walletAddressToDelete {
            savedAccounts.removeAll { Self.isSameAccount($0.publicAddress, walletAddressToDelete) }
            if savedAccounts.isEmpty {
                UserDefaults.standard.removeObject(forKey: savedAccountsKey)
            } else {
                persistSavedAccountsToStorage()
            }
        }
        currentWallet = nil
        // the deleted account's key must not outlive it in memory
        cachedPrivateKey = nil
        lastBalanceRefresh = nil
        updateSavedAccounts(from: nil)
        isLoggedOut = false
        isBalanceRefreshing = false
        UserDefaults.standard.removeObject(forKey: logoutFlagKey)
        AddressBookManager.shared.setActiveWalletAddress(nil)

        ColdStorageManager.shared.setCurrentWallet(nil)
        PortfolioManager.shared.setCurrentWallet(nil)
        PortfolioViewModel.shared.setCurrentWallet(nil)
        NextcloudService.shared.setCurrentWallet(nil)
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }

    /// Logs out the active session while preserving locally stored wallet and message data.
    func logout() async {
        guard let wallet = currentWallet else { return }

        await PushNotificationManager.shared.unregister()
        WalletService.shared.stopPolling()
        resetInMemoryStateForAccountSwitch()

        updateSavedAccounts(from: wallet)
        currentWallet = nil
        cachedPrivateKey = nil
        // signed in means the keys were here: Log Out goes to the sign-in screen, never to a
        // recovery screen left from before
        walletNeedingKeyRecovery = nil
        isBalanceRefreshing = false
        isLoggedOut = true
        UserDefaults.standard.set(true, forKey: logoutFlagKey)
        AddressBookManager.shared.setActiveWalletAddress(nil)

        ColdStorageManager.shared.setCurrentWallet(nil)
        PortfolioManager.shared.setCurrentWallet(nil)
        PortfolioViewModel.shared.setCurrentWallet(nil)
        NextcloudService.shared.setCurrentWallet(nil)
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }

    @discardableResult
    func signInToSavedAccount(_ account: SavedAccountSummary) async -> Bool {
        guard savedAccounts.contains(account) else {
            signInFailureMessage = AppLocalization.string("Unable to sign in to this account.")
            return false
        }
        savedAccountNeedingKeys = nil
        signInFailureMessage = nil
        // what the active slot held, put back if writing this account's keys fails part-way
        var previousSlot: (wallet: Wallet, seedPhrase: SeedPhrase, privateKey: Data)?

        do {
            if let storedWallet = try keychainService.loadWallet(),
               Self.isSameAccount(storedWallet.publicAddress, account.publicAddress) {
                resetInMemoryStateForAccountSwitch()
                await loadWallet(force: true)
                if currentWallet != nil {
                    WalletService.shared.startPolling()
                }
                return finishSignIn(account)
            }

            // the account in the active slot must be safely filed before its keys are overwritten
            try snapshotStoredWallet(beforeReplacingWith: account.publicAddress)

            // A snapshot is filed under the address it was taken with, which may be the other
            // network's encoding of this account (one taken on mainnet, signing in on testnet).
            var foundSnapshot: (seedPhrase: SeedPhrase, privateKey: Data)?
            for address in Self.accountAddressVariants(account.publicAddress) {
                if let found = try keychainService.loadAccountSnapshot(publicAddress: address) {
                    foundSnapshot = found
                    break
                }
            }
            guard let snapshot = foundSnapshot else {
                // Not an error to read and dismiss: the accounts screen opens the recovery
                // sheet, which explains and leads into Enter Recovery Phrase.
                savedAccountNeedingKeys = account
                return false
            }

            let wallet = Wallet(
                publicAddress: account.publicAddress,
                publicKey: account.publicKey,
                alias: account.alias,
                createdAt: accountAddedDate(for: account.publicAddress)
            )
            // Keys first, record last: a record with no keys behind it is the broken state the
            // recovery screen exists for, so it is never written ahead of them.
            previousSlot = activeSlotContents()
            try keychainService.saveSeedPhrase(snapshot.seedPhrase)
            try keychainService.savePrivateKey(snapshot.privateKey)
            try keychainService.saveWallet(wallet)
            previousSlot = nil

            resetInMemoryStateForAccountSwitch()
            await loadWallet(force: true)
            if currentWallet != nil {
                WalletService.shared.startPolling()
            }
            return finishSignIn(account)
        } catch {
            if let previousSlot { restoreActiveSlot(previousSlot) }
            self.error = .keychainError(error.localizedDescription)
            signInFailureMessage = error.localizedDescription
            return false
        }
    }

    /// Whether the sign-in landed on `account`; when it didn't, and no recovery screen explains
    /// why, the reason waits in `signInFailureMessage` for the rebuilt accounts screen.
    private func finishSignIn(_ account: SavedAccountSummary) -> Bool {
        if isCurrentAccount(account) { return true }
        if walletNeedingKeyRecovery == nil {
            signInFailureMessage = error?.localizedDescription
                ?? AppLocalization.string("Unable to sign in to this account.")
        }
        return false
    }

    /// Removes a saved account entry.
    /// If the removed entry matches the locally stored wallet, local key material
    /// and message store data are cleared as well.
    func removeSavedAccount(_ account: SavedAccountSummary) async {
        guard savedAccounts.contains(account) else { return }

        let isStoredAccount: Bool
        do {
            let storedWallet = try keychainService.loadWallet()
            isStoredAccount = storedWallet.map { Self.isSameAccount($0.publicAddress, account.publicAddress) } ?? false
            if !isStoredAccount {
                for address in Self.accountAddressVariants(account.publicAddress) {
                    try? keychainService.deleteAccountSnapshot(publicAddress: address)
                }
                await removeLocalData(forAccount: account.publicAddress)
                // back on whoever is signed in (nobody, on the sign-in list)
                let current = currentWallet?.publicAddress
                ColdStorageManager.shared.setCurrentWallet(current)
                PortfolioManager.shared.setCurrentWallet(current)
                PortfolioViewModel.shared.setCurrentWallet(current)
                if let cached = cachedPrivateKey, Self.isSameAccount(cached.address, account.publicAddress) {
                    cachedPrivateKey = nil
                }
                removeSavedAccountFromStorage(account)
                return
            }
        } catch {
            self.error = .keychainError(error.localizedDescription)
            await loadWallet(force: false)
            return
        }

        await PushNotificationManager.shared.unregister()
        WalletService.shared.stopPolling()

        // Remove the stored wallet's local data, then clear local key material.
        await removeLocalData(forAccount: account.publicAddress)

        do {
            for address in Self.accountAddressVariants(account.publicAddress) {
                try keychainService.deleteAccountSnapshot(publicAddress: address)
            }
            try keychainService.clearCurrentAccountData()
        } catch {
            self.error = .keychainError(error.localizedDescription)
            await loadWallet(force: false)
            return
        }

        removeSavedAccountFromStorage(account)
        currentWallet = nil
        cachedPrivateKey = nil
        lastBalanceRefresh = nil
        isBalanceRefreshing = false
        isLoggedOut = false
        UserDefaults.standard.removeObject(forKey: logoutFlagKey)

        ColdStorageManager.shared.setCurrentWallet(nil)
        PortfolioManager.shared.setCurrentWallet(nil)
        PortfolioViewModel.shared.setCurrentWallet(nil)
        NextcloudService.shared.setCurrentWallet(nil)
        WalletService.shared.resetForNewWallet()
        AddressBookManager.shared.setActiveWalletAddress(nil)
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }

    /// Everything an account keeps on this device besides its keys, on both networks' addresses
    /// (mainnet and testnet keep its data under different ones): what removing it has to take.
    /// The app password KaPay made on the user's Nextcloud is revoked first, while its login still
    /// exists to authenticate with. Leaves Cold Storage and the Portfolio on no wallet.
    private func removeLocalData(forAccount publicAddress: String) async {
        for address in Self.accountAddressVariants(publicAddress) {
            await NextcloudService.shared.revokeStoredAppPassword(forWalletAddress: address)
            // its .kachat reminders would keep firing for names this phone no longer holds
            await KachatNameReminders.removeAll(forWallet: address)
            ColdStorageManager.shared.setCurrentWallet(address)
            ColdStorageManager.shared.clearAllLocalData()
            PortfolioManager.shared.setCurrentWallet(address)
            PortfolioManager.shared.clearAllLocalData()
            PortfolioViewModel.shared.setCurrentWallet(address)
            PortfolioViewModel.shared.clearAllLocalData()
            NextcloudService.shared.purgeStoredState(forWalletAddress: address)
            AddressBookManager.shared.removeAllData(forWalletAddress: address)
            GlobalNotificationCenter.removeAllData(forWalletAddress: address)
            Self.removeSpendingData(forAccount: address)
        }
        ColdStorageManager.shared.setCurrentWallet(nil)
        PortfolioManager.shared.setCurrentWallet(nil)
        PortfolioViewModel.shared.setCurrentWallet(nil)
        AccountBackupStatus.shared.forget(publicAddress)
    }

    /// Settings > Delete Account: the signed-in account, removed the way the sign-in screen's
    /// Delete removes it.
    func deleteCurrentAccount() async {
        guard let wallet = currentWallet else { return }
        cachedPrivateKey = nil
        // files the account first, whatever the list holds, so the removal finds it
        updateSavedAccounts(from: wallet)
        guard let account = savedAccounts.first else { return }
        await removeSavedAccount(account)
    }

    func getSeedPhrase() throws -> SeedPhrase? {
        return try keychainService.loadSeedPhrase()
    }

    /// In-memory cache of the active wallet's private key, keyed by address. Avoids a keychain read
    /// (and, if the stored key were ever missing, a full PBKDF2 re-derivation) on every
    /// `getPrivateKey()` call - signing and push auth ask for it repeatedly. The address
    /// key makes serving a stale key after a wallet switch impossible; it's also cleared on logout.
    private var cachedPrivateKey: (address: String, key: Data)?

    /// Get the private key data for the current wallet (used for decryption)
    func getPrivateKey() -> Data? {
        if let cached = cachedPrivateKey, cached.address == currentWallet?.publicAddress {
            return cached.key
        }
        do {
            let key: Data?
            if let privateKey = try keychainService.loadPrivateKey() {
                key = privateKey
            } else if let seedPhrase = try getSeedPhrase() {
                key = derivePrivateKeyFromSeed(seedPhrase)
            } else {
                key = nil
            }
            if let key, let address = currentWallet?.publicAddress {
                cachedPrivateKey = (address, key)
            }
            return key
        } catch {
            AppLog.log("%@", "[WalletManager] Failed to get private key: \(error.localizedDescription)")
            return nil
        }
    }

    /// Sign an arbitrary message using the current wallet's Schnorr private key.
    /// Returns hex-encoded 64-byte Schnorr signature.
    enum ArbitraryMessageSigningMode {
        /// Kaspa wallet-compatible personal message signing:
        /// schnorr_sign(blake2b-256(key="PersonalMessageSigningHash", msg=utf8(message))).
        case kaspaPersonalMessage
        case rawUTF8
        case sha256Digest
    }

    func signArbitraryMessage(
        _ message: String,
        mode: ArbitraryMessageSigningMode = .rawUTF8
    ) throws -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KasiaError.encryptionError("Cannot sign empty message")
        }
        guard let privateKey = getPrivateKey() else {
            throw KasiaError.walletNotFound
        }

        var messageBytes: [UInt8]
        switch mode {
        case .kaspaPersonalMessage:
            let digest = Blake2b.hash(
                Data(message.utf8),
                digestLength: 32,
                key: "PersonalMessageSigningHash"
            )
            messageBytes = Array(digest)
        case .rawUTF8:
            // Keep bytes exactly as provided by caller (no normalization).
            messageBytes = Array(message.utf8)
        case .sha256Digest:
            // Legacy mode used by some existing server integrations.
            messageBytes = Array(SHA256.hash(data: Data(message.utf8)))
        }

        let key = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
        let signature = try key.signature(message: &messageBytes, auxiliaryRand: nil)
        for index in messageBytes.indices {
            messageBytes[index] = 0
        }

        return Data(signature.bytes).hexString
    }

    /// Ensures the non-sensitive wallet record matches locally stored signing key material.
    /// If keychain sync returns a stale wallet record from another device/account, prefer
    /// local key material so message decryption and signing keep working on this device.
    /// One key is one account on both networks: `kaspa:` and `kaspatest:` encodings of the same
    /// payload are the same account. The stored wallet record keeps the address it was saved
    /// with, while the saved-accounts list holds the running network's encoding
    /// (`walletOnCurrentNetwork`), so the two must never be compared as strings.
    static func isSameAccount(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard let pa = KaspaAddress(address: a), let pb = KaspaAddress(address: b) else { return false }
        return pa.type == pb.type && pa.payload == pb.payload
    }

    /// `address` on both networks, itself first - for state filed under an address string
    /// (account snapshots) that may have been written on the other network.
    static func accountAddressVariants(_ address: String) -> [String] {
        guard let parsed = KaspaAddress(address: address) else { return [address] }
        var variants = [address]
        for hrp in ["kaspa", "kaspatest"] where hrp != parsed.hrp {
            let other = KaspaAddress(hrp: hrp, type: parsed.type, payload: parsed.payload).address
            if !other.isEmpty { variants.append(other) }
        }
        return variants
    }

    private func isCurrentAccount(_ account: SavedAccountSummary) -> Bool {
        guard let current = currentWallet else { return false }
        return Self.isSameAccount(current.publicAddress, account.publicAddress)
    }

    /// The same key's address on the network the app is running on. A wallet record keeps the
    /// address it was saved with; after Settings > Connection Settings > Testnet switches the
    /// network, the account must appear as its `kaspatest:` (or back to its `kaspa:`) address -
    /// one key, one address per network. Not written back: the record stays as saved, and each
    /// launch re-encodes for whichever network is active.
    private func walletOnCurrentNetwork(_ wallet: Wallet) -> Wallet {
        let expectedHRP = SettingsViewModel.loadSettings().networkType == .mainnet ? "kaspa" : "kaspatest"
        guard let parsed = KaspaAddress(address: wallet.publicAddress), parsed.hrp != expectedHRP else {
            return wallet
        }
        let converted = KaspaAddress(hrp: expectedHRP, type: parsed.type, payload: parsed.payload).address
        guard !converted.isEmpty else { return wallet }
        var networked = Wallet(
            publicAddress: converted,
            publicKey: wallet.publicKey,
            alias: wallet.alias,
            createdAt: wallet.createdAt
        )
        // No balance carried over: the record's balance is the other network's (it is saved
        // with the record), and showing it here would be another chain's coins. The address's
        // own cached balance and the node refresh fill it in.
        networked.balanceSompi = nil
        networked.spendingAddressIndex = wallet.spendingAddressIndex
        networked.maxSpendingAddressIndex = wallet.maxSpendingAddressIndex
        return networked
    }

    private func reconcileWalletWithLocalKeyMaterialIfNeeded(_ wallet: Wallet) -> Wallet {
        guard let localWallet = walletFromLocalKeyMaterial(alias: wallet.alias, createdAt: wallet.createdAt, storedAddress: wallet.publicAddress) else {
            return wallet
        }
        guard localWallet.publicKey != wallet.publicKey else {
            return wallet
        }

        AppLog.log(
            "[WalletManager] Wallet record mismatch detected (stored=%@ local=%@). Repairing wallet record from local keys.",
            String(wallet.publicAddress.suffix(12)),
            String(localWallet.publicAddress.suffix(12))
        )
        do {
            try keychainService.saveWallet(localWallet)
        } catch {
            AppLog.log("[WalletManager] Failed to persist repaired wallet record: %@", error.localizedDescription)
        }
        return localWallet
    }

    /// - Parameter storedAddress: the keychain wallet record's address, used to look up its
    ///   persisted main-address index for the seed-fallback derivation. The private-key
    ///   branch needs no index - the stored key IS the chosen identity's key.
    private func walletFromLocalKeyMaterial(alias: String, createdAt: Date, storedAddress: String?) -> Wallet? {
        if let privateKey = try? keychainService.loadPrivateKey(),
           let wallet = try? walletFromPrivateKey(privateKey, alias: alias, createdAt: createdAt) {
            return wallet
        }
        let chattingIndex = storedAddress.map { chattingAddressIndex(for: $0) } ?? 0
        let family = storedAddress.map { walletSourceFamily(for: $0) } ?? .kaspaStandard
        if let seedPhrase = try? keychainService.loadSeedPhrase(),
           let keyPair = try? deriveKeysFromSeed(seedPhrase, chattingIndex: UInt32(chattingIndex), family: family) {
            return Wallet(
                publicAddress: keyPair.publicAddress,
                publicKey: keyPair.publicKey,
                alias: alias,
                createdAt: createdAt
            )
        }
        return nil
    }

    private func walletFromPrivateKey(_ privateKey: Data, alias: String, createdAt: Date) throws -> Wallet {
        let publicKeyData = try deriveSchnorrPublicKey(from: privateKey)
        let publicKeyHex = publicKeyData.map { String(format: "%02x", $0) }.joined()
        let settings = SettingsViewModel.loadSettings()
        let kaspaAddress = KaspaAddress.fromPublicKey(publicKeyData, network: settings.networkType)

        return Wallet(
            publicAddress: kaspaAddress.address,
            publicKey: publicKeyHex,
            alias: alias,
            createdAt: createdAt
        )
    }

    private func updateSavedAccounts(from wallet: Wallet?) {
        if let wallet {
            let summary = SavedAccountSummary(wallet: wallet)
            // Same key = same account, on whichever network: switching to testnet re-encodes
            // the address (`walletOnCurrentNetwork`) and must not list the account twice.
            savedAccounts.removeAll {
                Self.isSameAccount($0.publicAddress, summary.publicAddress)
                    || (!summary.publicKey.isEmpty && $0.publicKey == summary.publicKey)
            }
            savedAccounts.insert(summary, at: 0)
            persistSavedAccountsToStorage()
        }
        hasStoredWallet = !savedAccounts.isEmpty
    }

    /// The first launch after a reinstall, with keys still in the Keychain: they're listed as saved
    /// accounts and nothing opens by itself, so someone chooses to open or delete each. Keys are never
    /// erased here: for someone with no backup, they may be the only copy. An update has its saved
    /// accounts list, which a reinstall doesn't.
    private func noteKeysLeftByEarlierInstallIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: installSeenKey) else { return }
        defaults.set(true, forKey: installSeenKey)
        guard defaults.data(forKey: savedAccountsKey) == nil else { return }
        if (try? keychainService.loadWallet()) != nil {
            defaults.set(true, forKey: logoutFlagKey)
        }
        // one row per account: a snapshot under each network's encoding is still one account
        var leftover: [String] = []
        for address in keychainService.accountSnapshotAddresses()
        where !savedAccounts.contains(where: { Self.isSameAccount($0.publicAddress, address) })
            && !leftover.contains(where: { Self.isSameAccount($0, address) }) {
            leftover.append(address)
        }
        guard !leftover.isEmpty else { return }
        AppLog.log("%@", "[WalletManager] Listing \(leftover.count) saved account(s) left by an earlier install")
        // Named like a new account ("My Account 2"...), so the list never shows a blank row.
        for address in leftover {
            savedAccounts.append(SavedAccountSummary(alias: nextDefaultAccountName(), publicAddress: address, publicKey: ""))
        }
        persistSavedAccountsToStorage()
        hasStoredWallet = true
    }

    /// Renames a saved account entry (Onboarding's saved-accounts list). If this account
    /// happens to be the currently active wallet, keeps its alias in sync too.
    func renameSavedAccount(_ account: SavedAccountSummary, to newAlias: String) {
        guard let index = savedAccounts.firstIndex(where: { Self.isSameAccount($0.publicAddress, account.publicAddress) }) else { return }
        let trimmed = newAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        savedAccounts[index].alias = trimmed
        persistSavedAccountsToStorage()

        if isCurrentAccount(account) {
            currentWallet?.alias = trimmed
        }
        // The account in the active slot (signed in, or the last one signed out of): its wallet
        // record is what `loadWallet` reads, so the name goes there too, or the next launch or
        // sign-in would bring the old one back.
        if var stored = try? keychainService.loadWallet(),
           Self.isSameAccount(stored.publicAddress, account.publicAddress), stored.alias != trimmed {
            stored.alias = trimmed
            do {
                try keychainService.saveWallet(stored)
            } catch {
                AppLog.log("%@", "[WalletManager] Failed to save renamed wallet record: \(error.localizedDescription)")
            }
        }
    }

    /// The wallet record with the saved-accounts list's name for it. Every rename writes that
    /// list first, so its name is never older than the record's; a record left with an older name
    /// (by a build that renamed only the list) is brought up to date here instead of undoing the
    /// rename.
    private func withSavedAlias(_ wallet: Wallet) -> Wallet {
        guard let saved = savedAccounts.first(where: {
                  Self.isSameAccount($0.publicAddress, wallet.publicAddress)
                      || (!wallet.publicKey.isEmpty && $0.publicKey == wallet.publicKey)
              }) else { return wallet }
        let name = saved.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != wallet.alias else { return wallet }
        var renamed = wallet
        renamed.alias = name
        try? keychainService.saveWallet(renamed)
        return renamed
    }

    private func removeSavedAccountFromStorage(_ account: SavedAccountSummary) {
        savedAccounts.removeAll { $0.publicAddress == account.publicAddress }
        hasStoredWallet = !savedAccounts.isEmpty
        if savedAccounts.isEmpty {
            UserDefaults.standard.removeObject(forKey: savedAccountsKey)
        } else {
            persistSavedAccountsToStorage()
        }
    }

    private func loadSavedAccountsFromStorage() -> [SavedAccountSummary] {
        guard let data = UserDefaults.standard.data(forKey: savedAccountsKey) else {
            return []
        }
        guard let decoded = try? JSONDecoder().decode([SavedAccountSummary].self, from: data) else {
            UserDefaults.standard.removeObject(forKey: savedAccountsKey)
            return []
        }
        return decoded
    }

    private func persistSavedAccountsToStorage() {
        guard let data = try? JSONEncoder().encode(savedAccounts) else { return }
        UserDefaults.standard.set(data, forKey: savedAccountsKey)
    }

    /// Clears in-memory sync state so data from a previous account cannot leak into UI. Keeps
    /// on-disk wallet stores intact.
    private func resetInMemoryStateForAccountSwitch() {
        WalletService.shared.resetForNewWallet()
    }

    /// When this account was first added to the app on this device, stamped once and never
    /// moved.
    ///
    /// `Wallet.createdAt` was `Date()` at every site that builds a Wallet - including switching
    /// back to a saved account and re-importing a seed already on the device - so About's
    /// "Created" showed the last time you signed in, not when the account arrived. Keyed by
    /// address in UserDefaults rather than added to the Wallet model: the value has to survive
    /// the account being logged out and the Keychain record being rebuilt from a snapshot, which
    /// is exactly when the old value was being lost.
    ///
    /// An account already on this device from before this fix has no stamp, so it takes the
    /// creation date currently stored for it - the best evidence available - and keeps that from
    /// then on rather than resetting again on the next switch.
    private func accountAddedDate(for address: String) -> Date {
        let key = "kachat_account_added_at.\(address)"
        if let stored = UserDefaults.standard.object(forKey: key) as? Date {
            return stored
        }
        let inherited = (try? keychainService.loadWallet())
            .flatMap { Self.isSameAccount($0.publicAddress, address) ? $0.createdAt : nil }
        let date = inherited ?? Date()
        UserDefaults.standard.set(date, forKey: key)
        return date
    }

    private func snapshotStoredWalletIfPossible() {
        do {
            try snapshotStoredWallet(beforeReplacingWith: nil)
        } catch {
            AppLog.log("[WalletManager] Failed to snapshot current account: %@", error.localizedDescription)
        }
    }

    /// Files the account in the active keychain slot as a snapshot and reads it back, before that
    /// slot is overwritten with `newAddress`'s keys. Throws when the snapshot can't be written or
    /// doesn't read back intact: the caller must then leave the active slot alone, or that
    /// account's keys exist nowhere else. Nothing to protect (no stored keys, or the same
    /// account coming back) is not an error.
    private func snapshotStoredWallet(beforeReplacingWith newAddress: String?) throws {
        guard let wallet = try keychainService.loadWallet(),
              let seedPhrase = try keychainService.loadSeedPhrase(),
              let privateKey = try keychainService.loadPrivateKey() else {
            return
        }
        if let newAddress, Self.isSameAccount(wallet.publicAddress, newAddress) { return }
        try keychainService.saveAccountSnapshot(wallet: wallet, seedPhrase: seedPhrase, privateKey: privateKey)
        guard let back = try keychainService.loadAccountSnapshot(publicAddress: wallet.publicAddress),
              back.privateKey == privateKey, back.seedPhrase.words == seedPhrase.words,
              back.seedPhrase.passphrase == seedPhrase.passphrase else {
            throw KasiaError.keychainError(AppLocalization.string("The current account's keys couldn't be backed up on this device, so nothing was changed. Try again."))
        }
    }

    /// Refresh balance by summing UTXOs for the current wallet. `force` skips the few-seconds
    /// reuse below; event-driven callers (a UTXO change, a spend, a wallet load, pull to refresh)
    /// pass it, since they know the balance may have just moved.
    func refreshBalance(force: Bool = false) async throws -> UInt64 {
        guard let wallet = currentWallet else {
            throw KasiaError.walletNotFound
        }
        // Every toolbar balance label refreshes on appear, so one tab
        // switch used to fire several refreshes back to back. Answers from the last one if it is
        // only seconds old.
        if !force, let last = lastBalanceRefresh, last.address == wallet.publicAddress,
           Date().timeIntervalSince(last.at) < 5 {
            return last.total
        }
        isBalanceRefreshing = true
        defer { isBalanceRefreshing = false }
        let utxos = try await nodePool.getUtxosByAddresses([wallet.publicAddress])
        let total = utxos.reduce(0) { $0 + $1.amount }
        await MainActor.run {
            // Only when it moved: assigning `currentWallet` publishes WalletManager, which
            // re-renders every tab root, for an unchanged balance.
            if var w = self.currentWallet, w.publicAddress == wallet.publicAddress, w.balanceSompi != total {
                w.balanceSompi = total
                self.currentWallet = w
            }
        }
        lastBalanceRefresh = (wallet.publicAddress, Date(), total)
        storeCachedBalance(total, for: wallet.publicAddress)
        return total
    }

    /// Update balance from a UTXO fetch if it targets the current wallet.
    func updateBalanceIfCurrentWallet(address: String, utxos: [UTXO]) {
        guard let wallet = currentWallet, wallet.publicAddress == address else { return }
        let total = utxos.reduce(0) { $0 + $1.amount }
        if wallet.balanceSompi == total { return }
        var updated = wallet
        updated.balanceSompi = total
        currentWallet = updated
        storeCachedBalance(total, for: address)
        isBalanceRefreshing = false
    }

    private func balanceCacheKey(for address: String) -> String {
        "\(balanceCachePrefix)\(address)"
    }

    private func loadCachedBalance(for address: String) -> UInt64? {
        let key = balanceCacheKey(for: address)
        if let number = UserDefaults.standard.object(forKey: key) as? NSNumber {
            return number.uint64Value
        }
        if let value = UserDefaults.standard.object(forKey: key) as? UInt64 {
            return value
        }
        return nil
    }

    private func storeCachedBalance(_ sompi: UInt64, for address: String) {
        let key = balanceCacheKey(for: address)
        UserDefaults.standard.set(NSNumber(value: sompi), forKey: key)
    }

    /// Derive the raw private key from seed phrase
    private func derivePrivateKeyFromSeed(_ seedPhrase: SeedPhrase) -> Data? {
        // Must use the same passphrase as `deriveKeysFromSeed`, or the persisted private key
        // won't match the derived address and the wallet-reconciliation path will keep "repairing"
        // the record on every launch.
        guard let seed = bip39.mnemonicToSeed(seedPhrase.phrase, passphrase: seedPhrase.passphrase ?? "") else {
            return nil
        }

        // Family + index are the CURRENT wallet's persisted identity parameters (standard
        // family / index 0 unless the user imported from another wallet type or picked a
        // different identity index), so this fallback re-derives the key that actually matches
        // the stored wallet record.
        let baseNode = identityBaseNode(seed: seed, family: currentWalletSourceFamily)
        return identityPrivateKey(at: UInt32(currentChattingAddressIndex), baseNode: baseNode, family: currentWalletSourceFamily)
    }

    /// The chatting address a seed would produce with `passphrase`, without committing anything.
    ///
    /// Exists for the passphrase step, where seeing address #0 change as you type is the only
    /// direct evidence that a passphrase opens a DIFFERENT account rather than unlocking the same
    /// one - which is the single thing people get wrong about passphrases. Returns nil when the
    /// words are not a valid mnemonic.
    func previewChattingAddress(
        words: [String],
        passphrase: String,
        chattingIndex: UInt32 = 0,
        family: WalletSourceFamily = .kaspaStandard
    ) -> String? {
        let seed = SeedPhrase(words: words, passphrase: passphrase.isEmpty ? nil : passphrase)
        return try? deriveKeysFromSeed(seed, chattingIndex: chattingIndex, family: family).publicAddress
    }

    private func deriveKeysFromSeed(_ seedPhrase: SeedPhrase, chattingIndex: UInt32 = 0, family: WalletSourceFamily = .kaspaStandard) throws -> (publicKey: String, publicAddress: String, privateKey: Data) {
        // Derive seed using BIP39 standard (PBKDF2 with 2048 iterations). The optional BIP39
        // passphrase carried on the SeedPhrase changes the derived account entirely; reading it
        // here (rather than hardcoding "") is what makes relaunch, reconciliation and
        // `getPrivateKey` all passphrase-correct for free. Must match `derivePrivateKeyFromSeed`.
        guard var seed = bip39.mnemonicToSeed(seedPhrase.phrase, passphrase: seedPhrase.passphrase ?? "") else {
            throw KasiaError.invalidSeedPhrase
        }
        defer { seed.zeroOut() }

        // Identity path is family-dependent (see WalletSourceFamily): the standard family is
        // m/44'/111111'/0'/0/<chattingIndex> (111111 / 0x1B207 is Kaspa's coin type); imported
        // seeds from other wallets may use the legacy 972 branch, the single Chainge leaf, or
        // OneKey's tweaked standard key. chattingIndex is 0 for every fresh import/create;
        // nonzero only when the user chose a different identity index (setChattingAddress).
        let baseNode = identityBaseNode(seed: seed, family: family)
        guard let privateKeyData = identityPrivateKey(at: chattingIndex, baseNode: baseNode, family: family) else {
            throw KasiaError.apiError("This wallet type has no address at index \(chattingIndex).")
        }

        // Derive public key using secp256k1
        let publicKeyData = try deriveSchnorrPublicKey(from: privateKeyData)

        // Create Kaspa address using bech32 encoding
        let settings = SettingsViewModel.loadSettings()
        let network = settings.networkType

        let kaspaAddress = KaspaAddress.fromPublicKey(publicKeyData, network: network)
        let publicAddress = kaspaAddress.address

        // Public key as hex
        let publicKeyHex = publicKeyData.map { String(format: "%02x", $0) }.joined()

        // Return the private key too so callers (import/create) don't re-run the whole
        // PBKDF2 + BIP32 derivation a second time just to persist it - that double derivation on
        // the main actor was a measurable stutter at sign-in.
        return (publicKeyHex, publicAddress, privateKeyData)
    }

    // MARK: - Family-aware identity derivation core

    /// The family's shared base node, from which each address index derives with one final step
    /// (see `identityPrivateKey(at:baseNode:family:)` for how the index applies per family).
    /// Deriving this once per scan/import is the expensive part (HMAC-SHA512 chain); mirrors the
    /// `spendingChangeKey()` reuse pattern.
    private func identityBaseNode(seed: Data, family: WalletSourceFamily) -> (key: Data, chainCode: Data) {
        let masterKey = deriveMasterKey(from: seed)
        let purpose = deriveChildKey(from: masterKey, index: 44 | 0x80000000)               // 44'
        switch family {
        case .kaspaStandard, .oneKey:
            // m/44'/111111'/0'/0 - OneKey shares the standard chain; only the final key gets
            // its tweak.
            let coinType = deriveChildKey(from: purpose, index: 111111 | 0x80000000)        // 111111'
            let account = deriveChildKey(from: coinType, index: 0 | 0x80000000)             // 0'
            return deriveChildKey(from: account, index: 0)                                  // 0 (receive)
        case .kaspaLegacy972:
            // m/44'/972/0'/0' - 972 deliberately NOT hardened (replicates KasWare's
            // "m/44'/972/0'" string exactly); change level hardened, final index hardened too
            // (applied in identityPrivateKey).
            let coinType = deriveChildKey(from: purpose, index: 972)                        // 972 (normal!)
            let account = deriveChildKey(from: coinType, index: 0 | 0x80000000)             // 0'
            return deriveChildKey(from: account, index: 0 | 0x80000000)                     // 0' (receive)
        case .chainge:
            // m/44'/111111'/0' - the single 0' leaf is applied as the "index 0" step below.
            let coinType = deriveChildKey(from: purpose, index: 111111 | 0x80000000)        // 111111'
            return deriveChildKey(from: coinType, index: 0 | 0x80000000)                    // 0'
        }
    }

    /// Applies the family's index rule to the base node. Returns nil for indexes the family
    /// does not have (Chainge has exactly one address) or if the OneKey tweak fails.
    private func identityPrivateKey(at index: UInt32, baseNode: (key: Data, chainCode: Data), family: WalletSourceFamily) -> Data? {
        switch family {
        case .kaspaStandard:
            return deriveChildKey(from: baseNode, index: index).key                          // .../0/{i}
        case .kaspaLegacy972:
            guard index < 0x80000000 else { return nil }
            return deriveChildKey(from: baseNode, index: index | 0x80000000).key             // .../0'/{i'}
        case .chainge:
            guard index == 0 else { return nil }
            return deriveChildKey(from: baseNode, index: 0 | 0x80000000).key                 // .../0' (single)
        case .oneKey:
            let raw = deriveChildKey(from: baseNode, index: index).key                       // .../0/{i}, then tweak
            return oneKeyTweakedPrivateKey(raw)
        }
    }

    /// OneKey's BIP340 taproot-style key tweak, replicated from KasWare's
    /// `_onekeyPrivateKeyFromOriginPrivateKey` (bip340.ts): if the compressed pubkey has an odd
    /// Y (0x03 prefix), negate the private key mod n; then add
    /// taggedHash("TapTweak", xOnlyPubkey) mod n. The address derives from the tweaked key.
    private func oneKeyTweakedPrivateKey(_ privateKey: Data) -> Data? {
        guard let compressed = try? deriveCompressedPublicKey(from: privateKey), compressed.count == 33 else {
            return nil
        }
        var priv = privateKey
        if compressed.first == 0x03 {
            priv = negateModN(priv)
        }
        let xOnly = Data(compressed.dropFirst())
        let tweak = taggedSHA256(tag: "TapTweak", data: xOnly)
        do {
            let key = try P256K.Signing.PrivateKey(dataRepresentation: priv)
            let tweaked = try key.add(Array(tweak))
            return tweaked.dataRepresentation
        } catch {
            return nil
        }
    }

    /// BIP340 tagged hash: SHA256(SHA256(tag) || SHA256(tag) || data).
    private func taggedSHA256(tag: String, data: Data) -> Data {
        let tagHash = Data(SHA256.hash(data: Data(tag.utf8)))
        return Data(SHA256.hash(data: tagHash + tagHash + data))
    }

    /// n - key (big-endian, 32 bytes). Valid private keys are nonzero and < n, so no reduction
    /// is needed beyond the plain subtraction.
    private func negateModN(_ key: Data) -> Data {
        let n = Self.secp256k1_n
        let keyBytes = [UInt8](key)
        var result = [UInt8](repeating: 0, count: 32)
        var borrow: Int16 = 0
        for i in (0..<32).reversed() {
            let diff = Int16(n[i]) - Int16(keyBytes[i]) - borrow
            if diff < 0 {
                result[i] = UInt8((diff + 256) & 0xFF)
                borrow = 1
            } else {
                result[i] = UInt8(diff & 0xFF)
                borrow = 0
            }
        }
        return Data(result)
    }

    private func logPrivateKeyStorageStatus() {
        let preStatus = keychainService.privateKeyStorageStatus()
        AppLog.log("[WalletManager] Private key storage (pre-migration): %@", preStatus)

        do {
            let migratedKey = try keychainService.loadPrivateKey()
            if migratedKey == nil {
                AppLog.log("[WalletManager] Private key migration check: no key found")
            }
        } catch {
            AppLog.log("[WalletManager] Private key migration check failed: %@", error.localizedDescription)
        }

        let postStatus = keychainService.privateKeyStorageStatus()
        AppLog.log("[WalletManager] Private key storage (post-migration): %@", postStatus)
    }

    /// Derive master key from seed using BIP32
    func deriveMasterKey(from seed: Data) -> (key: Data, chainCode: Data) {
        let key = SymmetricKey(data: "Bitcoin seed".data(using: .utf8)!)
        let hmac = HMAC<SHA512>.authenticationCode(for: seed, using: key)
        let hmacData = Data(hmac)

        let privateKey = hmacData.prefix(32)
        let chainCode = hmacData.suffix(32)

        return (Data(privateKey), Data(chainCode))
    }

    // secp256k1 curve order n
    private static let secp256k1_n: [UInt8] = [
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
        0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B,
        0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41
    ]

    /// Derive child key using BIP32
    func deriveChildKey(from parent: (key: Data, chainCode: Data), index: UInt32) -> (key: Data, chainCode: Data) {
        var data = Data()

        if index >= 0x80000000 {
            // Hardened derivation
            data.append(0x00)
            data.append(parent.key)
        } else {
            // Normal derivation - need public key
            if let pubKey = try? deriveCompressedPublicKey(from: parent.key) {
                data.append(pubKey)
            } else {
                data.append(0x00)
                data.append(parent.key)
            }
        }

        // Append index as big-endian
        data.append(UInt8((index >> 24) & 0xFF))
        data.append(UInt8((index >> 16) & 0xFF))
        data.append(UInt8((index >> 8) & 0xFF))
        data.append(UInt8(index & 0xFF))

        let key = SymmetricKey(data: parent.chainCode)
        let hmac = HMAC<SHA512>.authenticationCode(for: data, using: key)
        let hmacData = Data(hmac)

        let il = Data(hmacData.prefix(32))
        let ir = Data(hmacData.suffix(32))

        // Use secp256k1 library's tweak_add for proper scalar addition (mod n)
        // This is what Kaspa's Rust implementation uses
        do {
            let parentPrivKey = try P256K.Signing.PrivateKey(dataRepresentation: parent.key)
            let childPrivKey = try parentPrivKey.add(Array(il))
            return (childPrivKey.dataRepresentation, ir)
        } catch {
            // Fallback to manual addition if tweak fails (shouldn't happen with valid keys)
            let childKey = addModN(il, parent.key)
            return (childKey, ir)
        }
    }

    /// Add two 32-byte big integers modulo secp256k1 curve order n (fallback only)
    private func addModN(_ a: Data, _ b: Data) -> Data {
        // First, add a + b as big integers
        var result = [UInt8](repeating: 0, count: 33) // Extra byte for overflow
        var carry: UInt16 = 0

        for i in (0..<32).reversed() {
            let sum = UInt16(a[i]) + UInt16(b[i]) + carry
            result[i + 1] = UInt8(sum & 0xFF)
            carry = sum >> 8
        }
        result[0] = UInt8(carry)

        // Now reduce modulo n if result >= n
        let n = Self.secp256k1_n

        // Compare result with n (result has 33 bytes, n has 32)
        var resultIsGreaterOrEqual = result[0] > 0 // If there's overflow, definitely greater

        if !resultIsGreaterOrEqual {
            // Compare the 32-byte portions
            for i in 0..<32 {
                if result[i + 1] > n[i] {
                    resultIsGreaterOrEqual = true
                    break
                } else if result[i + 1] < n[i] {
                    break
                }
            }
            // If all bytes equal, result == n, so still need to reduce
            if !resultIsGreaterOrEqual {
                var allEqual = true
                for i in 0..<32 {
                    if result[i + 1] != n[i] {
                        allEqual = false
                        break
                    }
                }
                if allEqual {
                    resultIsGreaterOrEqual = true
                }
            }
        }

        if resultIsGreaterOrEqual {
            // Subtract n from result
            var borrow: Int16 = 0
            for i in (0..<32).reversed() {
                let diff = Int16(result[i + 1]) - Int16(n[i]) - borrow
                if diff < 0 {
                    result[i + 1] = UInt8((diff + 256) & 0xFF)
                    borrow = 1
                } else {
                    result[i + 1] = UInt8(diff & 0xFF)
                    borrow = 0
                }
            }
            // Handle borrow from the overflow byte
            result[0] = UInt8(Int16(result[0]) - borrow)
        }

        // Return last 32 bytes
        return Data(result.suffix(32))
    }

    /// Derive compressed public key (33 bytes) from private key using secp256k1
    private func deriveCompressedPublicKey(from privateKey: Data) throws -> Data {
        let privKey = try P256K.Signing.PrivateKey(dataRepresentation: privateKey)
        return privKey.publicKey.dataRepresentation
    }

    /// Derive Schnorr public key (32 bytes, x-only) from private key using secp256k1
    func deriveSchnorrPublicKey(from privateKey: Data) throws -> Data {
        let privKey = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
        // Get the x-only public key for Schnorr (32 bytes)
        return Data(privKey.xonly.bytes)
    }

    // MARK: - Main-address index (the identity derivation index)
    //
    // An imported seed may hold its real identity at a nonzero index on the identity chain
    // (m/44'/111111'/0'/0/<index>) - e.g. the user's KNS domain sits on index 45 in another
    // wallet. The Welcome Guide's funding step (import runs only) lets the user scan that chain
    // and pick a different index as their chatting address. The chosen index is persisted in
    // UserDefaults keyed by the DERIVED address, so every path that re-derives from the seed
    // (getPrivateKey's fallback, reconcileWalletWithLocalKeyMaterialIfNeeded's repair) can find
    // the right index from the wallet record it already has. The keychain-stored private key is
    // simply the chosen index's key, so normal loads never re-derive at all.
    //
    // Collision note: the spending chain lives on a DIFFERENT hardened account branch
    // (m/44'/111111'/1'/0/<index>, see WalletManager+SpendingAddresses.swift), so a chosen
    // identity index can never collide with any spending address - no reservation needed.
    //
    // DECISION: the spending chain stays on KaChat's own m/44'/111111'/1' branch REGARDLESS of
    // the imported wallet's source family. Spending addresses are funds KaChat itself controls
    // and reveals (payment pools, fresh change, reservations) - they are not something the
    // source wallet ever derived, so there is nothing to "find" on the source family's branch,
    // and keeping them on the fixed account-1' branch means no source family (standard account
    // 0', legacy 972, Chainge's single 0' leaf, OneKey's tweaked account-0' keys) can ever
    // collide with them.

    private func chattingIndexKey(for address: String) -> String {
        "kachat_chatting_address_index_\(address)"
    }

    /// Persisted identity-chain index for a derived chatting address (0 when never customized).
    /// Read on either network's encoding of the address: the wallet record keeps the one it was
    /// saved with, and after a mainnet/testnet switch the running address is the other one.
    func chattingAddressIndex(for address: String) -> Int {
        for variant in Self.accountAddressVariants(address) {
            if let index = UserDefaults.standard.object(forKey: chattingIndexKey(for: variant)) as? Int {
                return index
            }
        }
        return 0
    }

    /// Identity-chain index of the active wallet's chatting address (0 = the standard identity).
    var currentChattingAddressIndex: Int {
        guard let address = currentWallet?.publicAddress else { return 0 }
        return chattingAddressIndex(for: address)
    }

    /// Written under both networks' encodings, so a mainnet/testnet switch reads the same index.
    private func persistChattingAddressIndex(_ index: Int, for address: String) {
        for variant in Self.accountAddressVariants(address) {
            if index == 0 {
                UserDefaults.standard.removeObject(forKey: chattingIndexKey(for: variant))
            } else {
                UserDefaults.standard.set(index, forKey: chattingIndexKey(for: variant))
            }
        }
    }

    // MARK: - Source-wallet family persistence (same pattern as the main-address index)

    private func walletSourceFamilyKey(for address: String) -> String {
        "kachat_wallet_source_family_\(address)"
    }

    /// Persisted identity path family for a derived address (`.kaspaStandard` when never
    /// customized - every pre-existing wallet).
    /// Read on either network's encoding of the address, like the chatting index.
    func walletSourceFamily(for address: String) -> WalletSourceFamily {
        for variant in Self.accountAddressVariants(address) {
            if let raw = UserDefaults.standard.string(forKey: walletSourceFamilyKey(for: variant)),
               let family = WalletSourceFamily(rawValue: raw) {
                return family
            }
        }
        return .kaspaStandard
    }

    /// Identity path family of the active wallet.
    var currentWalletSourceFamily: WalletSourceFamily {
        guard let address = currentWallet?.publicAddress else { return .kaspaStandard }
        return walletSourceFamily(for: address)
    }

    private func persistWalletSourceFamily(_ family: WalletSourceFamily, for address: String) {
        for variant in Self.accountAddressVariants(address) {
            if family == .kaspaStandard {
                UserDefaults.standard.removeObject(forKey: walletSourceFamilyKey(for: variant))
            } else {
                UserDefaults.standard.set(family.rawValue, forKey: walletSourceFamilyKey(for: variant))
            }
        }
    }

    private func chattingAddress(at index: Int, baseNode: (key: Data, chainCode: Data), family: WalletSourceFamily) -> String? {
        guard index >= 0, let privateKey = identityPrivateKey(at: UInt32(index), baseNode: baseNode, family: family) else { return nil }
        guard let publicKeyData = try? deriveSchnorrPublicKey(from: privateKey) else { return nil }
        let network = SettingsViewModel.loadSettings().networkType
        return KaspaAddress.fromPublicKey(publicKeyData, network: network).address
    }

    /// For an import's passphrase step, before there's an account: address #0 plus every other
    /// address on the identity chain holding funds, in index order. Nil when the words are invalid
    /// or the balances couldn't be checked. Single-address families only ever yield index 0.
    func findChattingAddresses(words: [String], passphrase: String, family: WalletSourceFamily, indices: Range<Int>) async -> [FoundChattingAddress]? {
        let seedPhrase = SeedPhrase(words: words, passphrase: passphrase.isEmpty ? nil : passphrase)
        guard var seed = bip39.mnemonicToSeed(seedPhrase.phrase, passphrase: seedPhrase.passphrase ?? "") else { return nil }
        let baseNode = identityBaseNode(seed: seed, family: family)
        seed.zeroOut()

        var derived: [(index: Int, address: String)] = []
        for index in indices {
            guard family.supportsIndexScan || index == 0 else { break }
            guard let address = chattingAddress(at: index, baseNode: baseNode, family: family) else { continue }
            derived.append((index, address))
        }
        guard !derived.isEmpty,
              let utxos = try? await NodePoolService.shared.getUtxosByAddresses(derived.map(\.address)) else { return nil }
        var balanceByAddress: [String: UInt64] = [:]
        for utxo in utxos {
            balanceByAddress[utxo.address, default: 0] += utxo.amount
        }
        return derived.compactMap { entry in
            let balance = balanceByAddress[entry.address] ?? 0
            guard entry.index == 0 || balance > 0 else { return nil }
            return FoundChattingAddress(index: entry.index, address: entry.address, balanceSompi: balance)
        }
    }

    // MARK: - Storage

    /// Keys first, the wallet record last. If key storage throws (a Secure Enclave that would
    /// not make a key), nothing is left behind: a record with no keys is the state the
    /// recovery screen exists for, and it used to be written before the keys were even tried.
    ///
    /// The slot's previous account is put back on a failure, not deleted: it may be another
    /// account (filed as a snapshot a moment ago, but signed in from this slot) or this same
    /// account re-entered, and either way deleting left it with no keys.
    private func saveWallet(_ wallet: Wallet, seedPhrase: SeedPhrase, privateKey: Data) async throws {
        let previousSlot = activeSlotContents()
        do {
            try keychainService.saveSeedPhrase(seedPhrase)
            // Private key is derived once by the caller (deriveKeysFromSeed) and passed in, rather
            // than re-deriving it here (a second full PBKDF2 + BIP32 pass on the main actor).
            try keychainService.savePrivateKey(privateKey)
            try keychainService.saveAccountSnapshot(wallet: wallet, seedPhrase: seedPhrase, privateKey: privateKey)
            try keychainService.saveWallet(wallet)
        } catch {
            if let previousSlot {
                restoreActiveSlot(previousSlot)
                if !Self.isSameAccount(previousSlot.wallet.publicAddress, wallet.publicAddress) {
                    try? keychainService.deleteAccountSnapshot(publicAddress: wallet.publicAddress)
                }
            } else {
                try? keychainService.deleteSeedPhrase()
                try? keychainService.deletePrivateKey()
                try? keychainService.deleteAccountSnapshot(publicAddress: wallet.publicAddress)
            }
            throw error
        }
    }

    /// The active keychain slot's record and keys, all three or nothing.
    private func activeSlotContents() -> (wallet: Wallet, seedPhrase: SeedPhrase, privateKey: Data)? {
        guard let wallet = try? keychainService.loadWallet(),
              let seedPhrase = try? keychainService.loadSeedPhrase(),
              let privateKey = try? keychainService.loadPrivateKey() else { return nil }
        return (wallet, seedPhrase, privateKey)
    }

    /// Puts back what `activeSlotContents` read, after a write that failed part-way.
    private func restoreActiveSlot(_ slot: (wallet: Wallet, seedPhrase: SeedPhrase, privateKey: Data)) {
        do {
            try keychainService.saveSeedPhrase(slot.seedPhrase)
            try keychainService.savePrivateKey(slot.privateKey)
            try keychainService.saveWallet(slot.wallet)
        } catch {
            AppLog.log("[WalletManager] Failed to restore the active account's keys: %@", error.localizedDescription)
        }
    }

    /// The stored record has no keys behind it: puts them back from this account's snapshot, when
    /// one filed on this phone can still be read. False when there is none.
    private func restoreKeysFromSnapshot(for wallet: Wallet) -> Bool {
        for address in Self.accountAddressVariants(wallet.publicAddress) {
            guard let snapshot = try? keychainService.loadAccountSnapshot(publicAddress: address) else { continue }
            do {
                try keychainService.saveSeedPhrase(snapshot.seedPhrase)
                try keychainService.savePrivateKey(snapshot.privateKey)
                AppLog.log("%@", "[WalletManager] Restored missing keys from this account's snapshot")
                return true
            } catch {
                try? keychainService.deleteSeedPhrase()
                try? keychainService.deletePrivateKey()
                return false
            }
        }
        return false
    }

    func saveWalletOnly(_ wallet: Wallet) async throws {
        try keychainService.saveWallet(wallet)
    }
}

/// Launch trace: timestamped steps along the launch path, plus a watchdog thread that logs
/// when the main thread stops answering and which step it was last in - so one run's console
/// shows where a launch hangs, without pausing in the debugger (pausing mid-XPC crashes
/// libdispatch on resume, which is how the first hang reports misled). The watchdog runs for
/// the first 90 seconds after launch.
enum LaunchTrace {
    private static let started = DispatchTime.now()
    private static let lock = NSLock()
    private static var currentStep = "launch"
    private static var watchdogStarted = false

    static func mark(_ step: String) {
        lock.lock()
        currentStep = step
        lock.unlock()
        AppLog.log("[Launch] +%dms %@", elapsedMs(), step)
    }

    private static func lastStep() -> String {
        lock.lock()
        defer { lock.unlock() }
        return currentStep
    }

    private static func elapsedMs() -> Int {
        // `started` is a lazy static: read it BEFORE taking "now", or on the very first call it
        // is set after "now" and the unsigned subtraction traps.
        let start = started.uptimeNanoseconds
        let now = DispatchTime.now().uptimeNanoseconds
        return now > start ? Int((now - start) / 1_000_000) : 0
    }

    static func startWatchdog() {
        lock.lock()
        let already = watchdogStarted
        watchdogStarted = true
        lock.unlock()
        guard !already else { return }
        let thread = Thread {
            let stopAt = Date().addingTimeInterval(90)
            while Date() < stopAt {
                let answered = DispatchSemaphore(value: 0)
                let sent = Date()
                DispatchQueue.main.async { answered.signal() }
                if answered.wait(timeout: .now() + 2) == .timedOut {
                    AppLog.log("[Launch] MAIN THREAD BLOCKED >2s at +%dms, in or after: %@", elapsedMs(), lastStep())
                    answered.wait()
                    AppLog.log("[Launch] main thread answered again after %.1fs (it was in or after: %@)",
                               Date().timeIntervalSince(sent), lastStep())
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        thread.name = "kachat.launch-watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }
}
