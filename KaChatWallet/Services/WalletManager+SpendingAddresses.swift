import Foundation
import CryptoKit
import P256K

/// Spending-chain address system: a second BIP44 *account* branch off the same wallet seed,
/// distinct from the identity/chatting address's account (see `WalletManager.deriveKeysFromSeed`,
/// account 0). Addresses are always re-derived live from the seed + index rather than persisted -
/// only the index bounds are stored, in UserDefaults scoped per wallet address (see
/// `currentSpendingAddressIndex`'s doc comment for why that, and not `Wallet`'s own
/// `spendingAddressIndex`/`maxSpendingAddressIndex` fields, is authoritative). Hidden-set and
/// per-address labels live in that same per-address UserDefaults scope.
///
/// Path: m/44'/111111'/1'/0/<index> (the identity address uses m/44'/111111'/0'/0/0 - same
/// purpose/coin type, a separate account index so it can't collide with the identity address,
/// same external/receive chain shape so gap-limit discovery behaves like normal BIP44 wallet
/// recovery).
///
/// Reconstructed after this file's original implementation was accidentally lost to an
/// uncommitted-work-discarding `git checkout` earlier in development (see conversation) -
/// rebuilt from every call site's exact usage, cross-checked against `Wallet`'s own
/// `spendingAddressIndex`/`maxSpendingAddressIndex`/`effective*` fields (which survived, since
/// they live in Models.swift, a file the bad checkout never touched) rather than guessed from
/// scratch. An initial guess (a change=1 branch under account 0) didn't match - this account-1
/// variant is the second attempt. If any spending-chain address was funded before this
/// reconstruction, verify its address still matches after rebuilding (the derivation path
/// chosen here is a standard-shaped BIP44 branch, but is a reconstruction, not guaranteed
/// byte-for-byte identical to what generated the original addresses).
extension WalletManager {

    // MARK: - Persisted bounds (UserDefaults, scoped per wallet - authoritative)

    /// Authoritative source is per-address-keyed UserDefaults, NOT `currentWallet`'s own
    /// `spendingAddressIndex`/`maxSpendingAddressIndex` fields - every path that reconstructs a
    /// `Wallet` from partial data (re-signing into a saved account via `SavedAccountSummary`,
    /// re-importing the same account's seed phrase, the key-repair branch in
    /// `reconcileWalletWithLocalKeyMaterialIfNeeded`) builds a bare `Wallet` whose spending
    /// fields default to nil/0 and then persists that to the single-slot Keychain wallet record,
    /// permanently losing this state if it were the only place it lived - which it used to be,
    /// and was the cause of "log out, log back in, spending addresses reset to just #0". Kept in
    /// sync on the Wallet struct too (`updateSpendingBounds` below) purely as a migration
    /// fallback for anyone who generated spending addresses before this fix - see
    /// `migrateSpendingBoundsIfNeeded()`.
    var currentSpendingAddressIndex: Int {
        persistedSpendingAddressIndex ?? currentWallet?.effectiveSpendingAddressIndex ?? 0
    }

    var maxSpendingAddressIndex: Int {
        // Legacy chain only. Neither a quantum primary nor a stored value in quantum space (never
        // legitimately written) may widen it: a million-long "legacy chain" froze every range
        // loop over it (the launch hang of 2026-10-20).
        let fallback = currentWallet?.effectiveMaxSpendingAddressIndex ?? 0
        let persisted = persistedMaxSpendingAddressIndex.flatMap { Self.isQuantumIndex($0) ? nil : $0 }
        let current = currentSpendingAddressIndex
        return max(persisted ?? fallback, current < Self.quantumIndexBase ? current : 0)
    }

    // MARK: - Quantum-safe chain bounds (KIP-22; see the Quantum-safe section below)

    /// Quantum addresses live in the same Int index space as the legacy chain, offset by this
    /// base, so every API that passes a spending index (send sources, coin control, labels,
    /// hidden set, the primary pointer) works for both chains unchanged. Index `base + n` is
    /// quantum chain index `n`.
    nonisolated static let quantumIndexBase = 1_000_000

    nonisolated static func isQuantumIndex(_ index: Int) -> Bool { index >= quantumIndexBase }

    /// The highest quantum chain index ever revealed; -1 before the first one.
    var maxQuantumAddressIndex: Int { quantumMaxIndex(owner: nil) }

    private func quantumMaxIndex(owner: String?) -> Int {
        guard let key = spendingDefaultsKey("qmaxIndex", owner: owner) else { return -1 }
        return (UserDefaults.standard.object(forKey: key) as? Int) ?? -1
    }

    private func setMaxQuantumAddressIndex(_ value: Int, owner: String? = nil) {
        guard let key = spendingDefaultsKey("qmaxIndex", owner: owner),
              value > quantumMaxIndex(owner: owner) else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    private var persistedSpendingAddressIndex: Int? {
        get {
            guard let key = spendingDefaultsKey("index") else { return nil }
            return UserDefaults.standard.object(forKey: key) as? Int
        }
        set {
            guard let key = spendingDefaultsKey("index") else { return }
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    private var persistedMaxSpendingAddressIndex: Int? {
        get {
            guard let key = spendingDefaultsKey("maxIndex") else { return nil }
            return UserDefaults.standard.object(forKey: key) as? Int
        }
        set {
            guard let key = spendingDefaultsKey("maxIndex") else { return }
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// One-time-per-address migration for wallets that generated spending addresses before this
    /// fix: seeds UserDefaults from the just-loaded Wallet's own (Keychain-persisted) fields the
    /// first time this address is seen with no UserDefaults value yet, so the value survives even
    /// if a later reconstruction path resets the Wallet's own fields before this address's next
    /// genuine `setActiveSpendingAddress`/`generateNextSpendingAddress` call. No-op once
    /// UserDefaults already has a value for this address (including a legitimately-0 one). Called
    /// from `loadWallet()` right after `currentWallet` is set to the freshly-loaded record.
    func migrateSpendingBoundsIfNeeded() {
        guard let wallet = currentWallet else { return }
        if persistedSpendingAddressIndex == nil, let index = wallet.spendingAddressIndex {
            persistedSpendingAddressIndex = index
        }
        if persistedMaxSpendingAddressIndex == nil, let maxIndex = wallet.maxSpendingAddressIndex {
            persistedMaxSpendingAddressIndex = maxIndex
        }
    }

    private func updateSpendingBounds(index: Int? = nil, maxIndex: Int? = nil) async {
        guard var wallet = currentWallet else { return }
        if let index {
            wallet.spendingAddressIndex = index
            persistedSpendingAddressIndex = index
        }
        if let maxIndex {
            wallet.maxSpendingAddressIndex = maxIndex
            persistedMaxSpendingAddressIndex = maxIndex
        }
        try? await saveWalletOnly(wallet)
        currentWallet = wallet
    }

    // MARK: - Hidden-set / labels (UserDefaults, scoped per wallet - not part of Wallet itself)

    /// `owner` names the account explicitly (the Discover sweep, which must keep writing to the
    /// account it started for); nil = the current account.
    private func spendingDefaultsKey(_ suffix: String, owner: String? = nil) -> String? {
        guard let address = owner ?? currentWallet?.publicAddress else { return nil }
        return "kachat_spending_\(suffix)_\(address)"
    }

    private var hiddenSpendingIndices: Set<Int> {
        get { hiddenIndices(owner: nil) }
        set { setHiddenIndices(newValue, owner: nil) }
    }

    private func hiddenIndices(owner: String?) -> Set<Int> {
        guard let key = spendingDefaultsKey("hidden", owner: owner) else { return [] }
        return Set(UserDefaults.standard.array(forKey: key) as? [Int] ?? [])
    }

    private func setHiddenIndices(_ indices: Set<Int>, owner: String?) {
        guard let key = spendingDefaultsKey("hidden", owner: owner) else { return }
        UserDefaults.standard.set(Array(indices), forKey: key)
    }

    // Snapshot of the last fully-loaded Manage Addresses list, persisted per wallet so the
    // screen can render INSTANTLY from cache while the live network refresh runs behind it.
    // Balances in the snapshot may be stale for a moment — the refresh replaces them.
    func cachedSpendingAddressList() -> [SpendingAddressEntry] {
        guard let key = spendingDefaultsKey("entries_cache"),
              let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SpendingAddressEntry].self, from: data) else { return [] }
        return decoded
    }

    func storeSpendingAddressListCache(_ entries: [SpendingAddressEntry]) {
        guard let key = spendingDefaultsKey("entries_cache"),
              let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private var spendingLabels: [Int: String] {
        get {
            guard let key = spendingDefaultsKey("labels"),
                  let data = UserDefaults.standard.data(forKey: key),
                  let decoded = try? JSONDecoder().decode([Int: String].self, from: data) else {
                return [:]
            }
            return decoded
        }
        set {
            guard let key = spendingDefaultsKey("labels"), let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: - Per-UTXO labels

    /// Keyed by address + `"txId:index"` outpoint key, mirroring `ColdStorageManager`'s identical
    /// per-UTXO label scheme (see that file's own copy of this pattern) - a spending address's
    /// UTXOs deserve the same optional naming Cold Storage's already have.
    func setSpendingUtxoLabel(address: String, outpointKey: String, label: String?) {
        var labels = loadSpendingUtxoLabels(address: address)
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            labels.removeValue(forKey: outpointKey)
        } else {
            labels[outpointKey] = trimmed
        }
        guard let data = try? JSONEncoder().encode(labels) else { return }
        UserDefaults.standard.set(data, forKey: spendingUtxoLabelsKey(for: address))
    }

    func loadSpendingUtxoLabels(address: String) -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: spendingUtxoLabelsKey(for: address)),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func spendingUtxoLabelsKey(for address: String) -> String {
        Self.spendingUtxoLabelsKey(for: address)
    }

    private static func spendingUtxoLabelsKey(for address: String) -> String {
        "kachat_spending_utxo_labels_" + address
    }

    /// Everything this file keeps for one account, for its removal: each derived address's coin
    /// labels, the derived-address files of both networks, and the account's own spending keys.
    static func removeSpendingData(forAccount address: String) {
        let defaults = UserDefaults.standard
        for network in NetworkType.allCases {
            let cacheKey = "kachat_spending_derived_addresses_\(address)_\(network.rawValue)"
            for derived in DerivedAddressStore.addresses(cacheKey).values {
                defaults.removeObject(forKey: spendingUtxoLabelsKey(for: derived))
            }
            DerivedAddressStore.remove(cacheKey)
        }
        let suffixes = ["_\(address)", "_\(address.replacingOccurrences(of: ":", with: "_"))"]
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("kachat_spending_") && suffixes.contains(where: key.hasSuffix) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Derivation

    /// Cache of derived spending ADDRESSES (never keys), persisted per wallet + network in
    /// `DerivedAddressStore` (a file each; the key is the store's name for the set).
    /// Two reasons:
    /// 1. Correctness — `spendingPrivateKey(at:)` needs the seed from the keychain, which can
    ///    transiently fail (cold launch / before protected data unlocks). Every caller that did
    ///    `currentSpendingAddress() ?? wallet.publicAddress` then briefly showed the CHATTING
    ///    address under the spending role until a later render resolved it — the "chatting
    ///    balance shows under spending then reverts" flicker. Addresses are deterministic, so a
    ///    cached value is always correct and never needs invalidation.
    /// 2. Speed — skips Secure Enclave decrypt + PBKDF2 + 5 HMAC derivations per lookup.
    private func spendingAddressCacheKey(owner: String? = nil) -> String? {
        guard let base = spendingDefaultsKey("derived_addresses", owner: owner) else { return nil }
        return "\(base)_\(SettingsViewModel.loadSettings().networkType.rawValue)"
    }

    func spendingAddress(at index: Int) -> String? {
        guard index >= 0 else { return nil }
        let cacheKey = spendingAddressCacheKey()
        if let cacheKey, let address = DerivedAddressStore.address(cacheKey, index) {
            return address
        }
        if Self.isQuantumIndex(index) {
            guard let chainKey = quantumChainKey() else { return nil }
            return quantumAddress(at: index, chainKey: chainKey)
        }
        guard let privateKey = spendingPrivateKey(at: index) else { return nil }
        guard let publicKeyData = try? deriveSchnorrPublicKey(from: privateKey) else { return nil }
        let network = SettingsViewModel.loadSettings().networkType
        let address = KaspaAddress.fromPublicKey(publicKeyData, network: network).address
        if let cacheKey {
            DerivedAddressStore.store(cacheKey, index, address)
        }
        return address
    }

    func spendingPrivateKey(at index: Int) -> Data? {
        guard index >= 0 else { return nil }
        if Self.isQuantumIndex(index) {
            guard let chain = quantumChainKey() else { return nil }
            return deriveChildKey(from: chain, index: UInt32(index - Self.quantumIndexBase)).key
        }
        guard let seedPhrase = try? getSeedPhrase() else { return nil }
        guard var seed = BIP39.shared.mnemonicToSeed(seedPhrase.phrase, passphrase: seedPhrase.passphrase ?? "") else { return nil }
        defer { seed.zeroOut() }

        let masterKey = deriveMasterKey(from: seed)
        let purpose = deriveChildKey(from: masterKey, index: 44 | 0x80000000)
        let coinType = deriveChildKey(from: purpose, index: 111111 | 0x80000000)
        let account = deriveChildKey(from: coinType, index: 1 | 0x80000000) // separate account branch, not the identity's account 0
        let change = deriveChildKey(from: account, index: 0) // external/receive chain, same as identity's own chain
        let addressIndex = deriveChildKey(from: change, index: UInt32(index))
        return addressIndex.key
    }

    func currentSpendingAddress() -> String? {
        spendingAddress(at: currentSpendingAddressIndex)
    }

    func currentSpendingPrivateKey() -> Data? {
        spendingPrivateKey(at: currentSpendingAddressIndex)
    }

    /// Derives the shared "change" node (m/44'/111111'/1'/0) once, for reuse across every index
    /// in a range - `spendingAddress(at:)`/`spendingPrivateKey(at:)` above each redo the expensive
    /// parts (Secure Enclave seed-phrase decrypt, PBKDF2-2048 mnemonic-to-seed, 4 HMAC-SHA512
    /// hardened derivations) from scratch per call, which is fine for a single lookup but was the
    /// dominant cost in `getSpendingAddressList()`/`discoverSpendingAddresses()` below calling one
    /// of those once per address - Manage Addresses' load time scaled with the number of revealed
    /// addresses for no reason, since only the final per-index derivation actually differs.
    private func spendingChangeKey() -> (key: Data, chainCode: Data)? {
        guard let seedPhrase = try? getSeedPhrase() else { return nil }
        guard var seed = BIP39.shared.mnemonicToSeed(seedPhrase.phrase, passphrase: seedPhrase.passphrase ?? "") else { return nil }
        defer { seed.zeroOut() }
        let masterKey = deriveMasterKey(from: seed)
        let purpose = deriveChildKey(from: masterKey, index: 44 | 0x80000000)
        let coinType = deriveChildKey(from: purpose, index: 111111 | 0x80000000)
        let account = deriveChildKey(from: coinType, index: 1 | 0x80000000)
        return deriveChildKey(from: account, index: 0)
    }

    // MARK: - Quantum-safe chain derivation (KIP-22)
    //
    // Path m/22'/111111'/0'/0/<index> (KIP-0022). The address is the P2SH of the redeem script
    // `<x-only key> OP_CHECKSIG`, so the chain shows only a hash of the key until the address
    // spends - a quantum attacker reading addresses learns nothing. The P2SH script and address
    // come from the same helpers the .kachat registry uses on chain every day.

    /// The quantum chain node (m/22'/111111'/0'/0), one seed decrypt per call like
    /// `spendingChangeKey()`.
    private func quantumChainKey() -> (key: Data, chainCode: Data)? {
        guard let seedPhrase = try? getSeedPhrase() else { return nil }
        guard var seed = BIP39.shared.mnemonicToSeed(seedPhrase.phrase, passphrase: seedPhrase.passphrase ?? "") else { return nil }
        defer { seed.zeroOut() }
        let masterKey = deriveMasterKey(from: seed)
        let purpose = deriveChildKey(from: masterKey, index: 22 | 0x80000000)
        let coinType = deriveChildKey(from: purpose, index: 111111 | 0x80000000)
        let account = deriveChildKey(from: coinType, index: 0 | 0x80000000)
        return deriveChildKey(from: account, index: 0)
    }

    /// The KIP-22 redeem script of a quantum index's key: `0x20 <x-only key> OP_CHECKSIG`.
    /// Spends push it after the signature; nil when the seed is unavailable this instant.
    func quantumRedeemScript(at index: Int) -> Data? {
        guard Self.isQuantumIndex(index), let privateKey = spendingPrivateKey(at: index),
              let publicKey = try? deriveSchnorrPublicKey(from: privateKey) else { return nil }
        return KachatNames.Codec.p2pkScript(publicKey)
    }

    /// Derives the quantum address at public index `base + n`, through the shared per-index
    /// address cache (same dictionary as the legacy chain: the index spaces cannot collide).
    private func quantumAddress(at index: Int, chainKey: (key: Data, chainCode: Data), owner: String? = nil) -> String? {
        guard Self.isQuantumIndex(index) else { return nil }
        let cacheKey = spendingAddressCacheKey(owner: owner)
        if let cacheKey, let address = DerivedAddressStore.address(cacheKey, index) {
            return address
        }
        let privateKey = deriveChildKey(from: chainKey, index: UInt32(index - Self.quantumIndexBase)).key
        guard let publicKeyData = try? deriveSchnorrPublicKey(from: privateKey) else { return nil }
        let redeem = KachatNames.Codec.p2pkScript(publicKeyData)
        guard let address = KachatNamesService.p2shAddress(script: KachatNames.Codec.p2shScript(redeem)) else { return nil }
        if let cacheKey {
            DerivedAddressStore.store(cacheKey, index, address)
        }
        return address
    }

    private func spendingAddress(at index: Int, changeKey: (key: Data, chainCode: Data), owner: String? = nil) -> String? {
        // legacy chain only: `changeKey` is m/44'/111111'/1'/0 - a quantum index goes through
        // `quantumAddress(at:chainKey:)` with the m/22' node
        guard index >= 0, !Self.isQuantumIndex(index) else { return nil }
        let cacheKey = spendingAddressCacheKey(owner: owner)
        if let cacheKey, let address = DerivedAddressStore.address(cacheKey, index) {
            return address
        }
        let privateKey = deriveChildKey(from: changeKey, index: UInt32(index)).key
        guard let publicKeyData = try? deriveSchnorrPublicKey(from: privateKey) else { return nil }
        let network = SettingsViewModel.loadSettings().networkType
        let address = KaspaAddress.fromPublicKey(publicKeyData, network: network).address
        if let cacheKey {
            DerivedAddressStore.store(cacheKey, index, address)
        }
        return address
    }

    // MARK: - Mutation

    /// Switches which spending address is "primary" - a pure pointer change, moves no funds.
    /// Also extends `maxSpendingAddressIndex` if this index hasn't been revealed yet.
    ///
    /// `owner`: the account a send started on (IOS-109 follow-up). A send that ends after the
    /// person switched accounts moves THAT account's primary, never the newly active one's;
    /// nothing is written once the account has been removed.
    func setActiveSpendingAddress(_ index: Int, owner: String? = nil) async {
        guard index >= 0 else { return }
        if let owner, owner != currentWallet?.publicAddress {
            guard accountStillSaved(owner) else { return }
            if Self.isQuantumIndex(index) {
                setMaxQuantumAddressIndex(index - Self.quantumIndexBase, owner: owner)
            } else if index > legacyMaxIndex(owner: owner) {
                await raiseLegacyMaxIndex(index, owner: owner)
            }
            if let key = spendingDefaultsKey("index", owner: owner) {
                UserDefaults.standard.set(index, forKey: key)
            }
            return
        }
        let changed = index != currentSpendingAddressIndex
        // a quantum index extends its own chain; the legacy max must never see base-space values
        let newMax = (!Self.isQuantumIndex(index) && index > maxSpendingAddressIndex) ? index : nil
        if Self.isQuantumIndex(index) { setMaxQuantumAddressIndex(index - Self.quantumIndexBase) }
        await updateSpendingBounds(index: index, maxIndex: newMax)
        // Let open screens (Manage Addresses) refresh which row is primary immediately -
        // a payment send rotates the primary through here, and without this the old primary's
        // row kept its stale star (and hid its Hide action) until the next full reload.
        if changed {
            NotificationCenter.default.post(name: .spendingPrimaryChanged, object: nil)
        }
    }

    /// Reveals a new, never-used spending address slot (extends `maxSpendingAddressIndex` by
    /// one) without changing which address is currently primary.
    func generateNextSpendingAddress() async {
        await updateSpendingBounds(maxIndex: maxSpendingAddressIndex + 1)
    }

    /// Reveals a brand-new quantum-safe slot (KIP-22) and returns its public index - what
    /// "Generate New Address" makes from now on. Always extends the chain: a never-spent-from
    /// address is the whole point, so nothing is ever recycled here.
    @discardableResult
    func generateNextQuantumAddress() async -> Int {
        // checked on chain first, like every other fresh quantum slot (IOS-101): a slot already
        // used elsewhere is skipped, never handed out as new. The probe awaits, so the account is
        // taken now and the slot is written to it, not to whichever is active later (IOS-109).
        guard let owner = currentWallet?.publicAddress else { return await verifiedFreshQuantumIndex() }
        let index = await verifiedFreshQuantumIndex(owner: owner, chainKey: quantumChainKey())
        guard accountStillSaved(owner) else { return index }
        setMaxQuantumAddressIndex(index - Self.quantumIndexBase, owner: owner)
        var hidden = hiddenIndices(owner: owner)
        if hidden.remove(index) != nil { setHiddenIndices(hidden, owner: owner) }
        return index
    }

    /// One past every quantum slot ever revealed, in public index space - where a spend's
    /// change goes (fresh and hidden-keyed, whatever chain the spend came from).
    /// `nextFreshQuantumIndex()`, checked on chain first (IOS-101): the chain's end on this
    /// phone can sit below slots used elsewhere (another device, a restore that ran before the
    /// sweep looked far enough). While the REST server says the slot has history it is skipped
    /// and the end raised, up to 20 times; a check that can't be answered takes the slot as is,
    /// so an unreachable server never blocks a send.
    func verifiedFreshQuantumIndex() async -> Int {
        guard let owner = currentWallet?.publicAddress else { return nextFreshQuantumIndex() }
        return await verifiedFreshQuantumIndex(owner: owner, chainKey: quantumChainKey())
    }

    /// A fresh quantum slot AND its address, both from the account active when this was called -
    /// for change outputs, whose address must come from the same account the probe checked
    /// (IOS-109). A spend that started on that account keeps its change there even if another
    /// account is active by the time the probe returns. nil when the seed is unavailable.
    func verifiedFreshQuantumSlot() async -> (index: Int, address: String)? {
        guard let owner = currentWallet?.publicAddress, let chainKey = quantumChainKey() else { return nil }
        let index = await verifiedFreshQuantumIndex(owner: owner, chainKey: chainKey)
        guard let address = quantumAddress(at: index, chainKey: chainKey, owner: owner) else { return nil }
        return (index, address)
    }

    /// Reveals and returns `count` brand-new quantum-chain (KIP-22) slots in one step - used by
    /// Request Payment's Fresh Address. They start at the first slot past the chain end that is
    /// unused on chain, and the chain end is raised to cover them before returning, so they have
    /// never been revealed, funded or offered before, and no later reservation lands on them. The
    /// addresses stay listed in Manage Addresses like any other revealed slot.
    ///
    /// Returns an empty array (reserving nothing, raising nothing) if derivation fails.
    func reserveFreshSpendingAddresses(count: Int) async -> [(index: Int, address: String)] {
        guard count > 0, let owner = currentWallet?.publicAddress, let chainKey = quantumChainKey() else { return [] }
        // Probe, addresses and the raised chain end all belong to the account active at the
        // start (IOS-109).
        let base = await verifiedFreshQuantumIndex(owner: owner, chainKey: chainKey) - Self.quantumIndexBase
        var result: [(index: Int, address: String)] = []
        for offset in 0..<count {
            let index = Self.quantumIndexBase + base + offset
            guard let address = quantumAddress(at: index, chainKey: chainKey, owner: owner) else { return [] }
            result.append((index: index, address: address))
        }
        guard accountStillSaved(owner) else { return [] }
        setMaxQuantumAddressIndex(base + count - 1, owner: owner)
        return result
    }

    /// The probe for one account, taken when it starts (IOS-109, the sweep's rule from IOS-107):
    /// its slots are derived from that account's chain node and a used slot raises THAT
    /// account's chain end, even if another account is active when a probe returns. Once the
    /// account has been removed it writes nothing more.
    private func verifiedFreshQuantumIndex(owner: String, chainKey: (key: Data, chainCode: Data)?) async -> Int {
        var index = nextFreshQuantumIndex(owner: owner)
        guard let chainKey else { return index }
        for _ in 0..<20 {
            guard let address = quantumAddress(at: index, chainKey: chainKey, owner: owner),
                  await WalletService.shared.spendingAddressUsedState(address) == true else { return index }
            AppLog.log("[WalletManager] Quantum slot %d already has history - skipping it", index - Self.quantumIndexBase)
            guard accountStillSaved(owner) else { return index + 1 }
            setMaxQuantumAddressIndex(index - Self.quantumIndexBase, owner: owner)
            index = nextFreshQuantumIndex(owner: owner)
        }
        return index
    }

    func nextFreshQuantumIndex() -> Int {
        Self.quantumIndexBase + maxQuantumAddressIndex + 1
    }

    private func nextFreshQuantumIndex(owner: String) -> Int {
        Self.quantumIndexBase + quantumMaxIndex(owner: owner) + 1
    }

    /// False once `owner` is neither the active account nor a saved one (it was removed).
    private func accountStillSaved(_ owner: String) -> Bool {
        currentWallet?.publicAddress == owner || savedAccounts.contains { $0.publicAddress == owner }
    }

    /// "Generate New Spending Address" - a SEQUENCE, not a single answer: every press yields
    /// the NEXT fresh address, forever. The chosen index is the lowest one that is truly
    /// unused (zero balance, no on-chain history, not the primary, never offered to a contact
    /// as a payment-pool reservation) AND currently hidden - i.e. not already sitting in the
    /// Manage Addresses list. Recycling un-hides it. An index that is already visible is never
    /// picked (that was the old stall: the lowest unused index, once revealed, satisfied every
    /// check again on the next press, so Generate kept returning the same row and appeared to
    /// stop working). When no hidden unused index remains, the chain extends by one past the
    /// all-time max, which is always safe. A probe failure (used-ness unknown) skips that
    /// index rather than recycling it. Returns the chosen index.
    ///
    /// Side-effect free: nothing is un-hidden or revealed here - the caller reveals the index
    /// (`revealSpendingAddress(at:)`) only when the address is really handed out. Past the
    /// revealed range it answers the next index without extending the chain.
    func lowestUnusedSpendingAddress() async -> Int {
        let entries = await getSpendingAddressList().sorted { $0.index < $1.index }
        for entry in entries {
            guard entry.hidden else { continue } // already visible - the user has it; move on
            if entry.isCurrent { continue }
            if entry.balanceSompi > 0 { continue }
            // Recycle only on a CONFIRMED-unused probe; nil (probe failed) skips the index -
            // extending the chain below is always safe, recycling an unknown one is not.
            let usedState = await WalletService.shared.spendingAddressUsedState(entry.address)
            if usedState == false {
                return entry.index
            }
        }
        return maxSpendingAddressIndex + 1
    }

    /// Which index the Receive QR is currently handing out. Persisted per wallet, and entirely
    /// separate from the primary: receiving and spending are different jobs, and the QR must not
    /// change which address a payment comes out of.
    private var receiveAddressIndex: Int? {
        get {
            guard let key = spendingDefaultsKey("receiveIndex") else { return nil }
            return UserDefaults.standard.object(forKey: key) as? Int
        }
        set {
            guard let key = spendingDefaultsKey("receiveIndex") else { return }
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// The address to show on the Receive QR: one that has never been used.
    ///
    /// Reusing an address across payments links them to each other and to you, so the QR must
    /// never hand out one that has already appeared on chain. Three rules, in order:
    ///
    /// 1. The address it handed out last time, while that is still unused. It does NOT mint a new
    ///    address per tap - an unused address is still unused the second time you open the sheet,
    ///    and minting one per tap would balloon the address list and lengthen every future
    ///    gap-limit scan for no privacy gained.
    /// 2. Otherwise the primary, while THAT is unused - a fresh wallet should not reveal a second
    ///    slot before the first one has seen anything.
    /// 3. Otherwise a newly revealed slot, remembered as the receive pointer for next time.
    ///
    /// The primary is never changed. Receiving and spending are separate jobs: which address a
    /// payment comes out of is not the QR's business, and moving it would make the balance under
    /// Spending mean something different from one tap to the next. Funds that arrive here are
    /// covered by the Total line on the same screen and by Manage Addresses.
    ///
    /// Returns nil only when the keychain cannot derive an address at all. A probe that FAILS
    /// (used-ness unknown) keeps the current answer rather than rotating on a guess: rotating
    /// every time the network hiccups is how an address list fills with empty slots.
    ///
    /// `revealing`: the address is being shown (Receive Kaspa's QR is open), so it goes on the
    /// Manage Addresses list - extending the chain to it if needed, so its payment is watched.
    /// Without it (Profile warming the QR ahead of the tap) nothing about the list changes: an
    /// address appearing after Hide All with nobody having done anything was exactly that.
    func freshReceiveAddress(revealing: Bool = false) async -> String? {
        // The QR is for the account active now: an answer that comes back after a switch
        // belongs to the other account and is dropped, nothing written (IOS-109).
        guard let owner = currentWallet?.publicAddress else { return nil }
        let chosen: (index: Int, address: String)
        // Rule 1: the pointer from last time, while it is still untouched - and quantum. A
        // legacy pointer, even unused, carries its key in the address itself (P2PK), so the QR
        // moves to the quantum chain the first time it is opened after the upgrade.
        if let index = receiveAddressIndex, Self.isQuantumIndex(index), let address = spendingAddress(at: index),
           await WalletService.shared.spendingAddressUsedState(address) != true {
            chosen = (index, address)
        } else {
            // Rule 2: the lowest quantum slot never used (recycling a hidden unused one), else a
            // brand-new slot past the chain's end.
            let index = await lowestUnusedQuantumAddress()
            guard currentWallet?.publicAddress == owner else { return nil }
            guard let address = spendingAddress(at: index) else { return currentSpendingAddress() }
            receiveAddressIndex = index
            chosen = (index, address)
        }
        guard currentWallet?.publicAddress == owner else { return nil }
        if revealing {
            await revealSpendingAddress(at: chosen.index, owner: owner)
        }
        return chosen.address
    }

    /// `lowestUnusedSpendingAddress`, on the quantum chain: the lowest hidden quantum slot that
    /// is confirmed unused (recycling un-hides it), else one past the chain's end - which is
    /// always safe.
    func lowestUnusedQuantumAddress() async -> Int {
        let entries = await getSpendingAddressList().filter { $0.isQuantum }.sorted { $0.index < $1.index }
        for entry in entries {
            guard entry.hidden else { continue }
            if entry.isCurrent { continue }
            if entry.balanceSompi > 0 { continue }
            if await WalletService.shared.spendingAddressUsedState(entry.address) == false {
                return entry.index
            }
        }
        return await verifiedFreshQuantumIndex()
    }

    // MARK: - Quantum spent-state (the shield)

    /// Quantum addresses this wallet has spent FROM: the spend put their key on chain for good,
    /// so the shield comes off (KIP-22). Marked the moment the app sends, and by the on-chain
    /// probe (`WalletService.quantumAddressSpentState`) for spends made elsewhere. Per wallet;
    /// never unmarked - a revealed key cannot be unrevealed.
    func markQuantumAddressSpent(_ address: String, owner: String? = nil) {
        // `owner`: the account whose address spent, when the caller started before an await
        // the person may have switched accounts across (IOS-109 follow-up)
        if let owner, !accountStillSaved(owner) { return }
        guard let key = spendingDefaultsKey("qspent", owner: owner) else { return }
        var spent = UserDefaults.standard.stringArray(forKey: key) ?? []
        let lowered = address.lowercased()
        guard !spent.contains(lowered) else { return }
        spent.append(lowered)
        UserDefaults.standard.set(spent, forKey: key)
    }

    func isQuantumAddressSpentLocally(_ address: String) -> Bool {
        guard let key = spendingDefaultsKey("qspent") else { return false }
        return (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(address.lowercased())
    }

    /// Reveals a specific index from the Address Visibility pager, extending the chain when the
    /// index is beyond the current max - intermediate newly-covered indices are marked hidden so
    /// checking ONE far-out row doesn't flood the main list with everything below it.
    ///
    /// `owner`: the account a send started on (IOS-109 follow-up) - its list gets the address
    /// even if another account is active when the send ends; nil = the current account.
    func revealSpendingAddress(at index: Int, owner: String? = nil) async {
        guard let owner = owner ?? currentWallet?.publicAddress, accountStillSaved(owner) else { return }
        var newlyCovered: [Int] = []
        if Self.isQuantumIndex(index) {
            let quantumIndex = index - Self.quantumIndexBase
            let currentMax = quantumMaxIndex(owner: owner)
            if quantumIndex > currentMax {
                setMaxQuantumAddressIndex(quantumIndex, owner: owner)
                newlyCovered = ((currentMax + 1)..<quantumIndex).map { Self.quantumIndexBase + $0 }
            }
        } else {
            let currentMax = legacyMaxIndex(owner: owner)
            if index > currentMax {
                await raiseLegacyMaxIndex(index, owner: owner)
                if index - 1 > currentMax { newlyCovered = Array((currentMax + 1)..<index) }
            }
        }
        // read after the await above: the hidden set is written in one go for the same account
        var hidden = hiddenIndices(owner: owner)
        hidden.formUnion(newlyCovered)
        hidden.remove(index)
        setHiddenIndices(hidden, owner: owner)
    }

    /// The Discover sweep's own copy of the account it started for: that account's address and
    /// both chain nodes, taken once at the start (IOS-107). Every derivation and write of the
    /// sweep goes through it, so switching accounts mid-sweep can't send results to the other
    /// account; they still land in this one's keys.
    struct SpendingSweepAccount {
        let owner: String
        let changeKey: (key: Data, chainCode: Data)
        let chainKey: (key: Data, chainCode: Data)?
    }

    private func spendingSweepAccount() -> SpendingSweepAccount? {
        guard let owner = currentWallet?.publicAddress, let changeKey = spendingChangeKey() else { return nil }
        return SpendingSweepAccount(owner: owner, changeKey: changeKey, chainKey: quantumChainKey())
    }

    /// The sweep's results are dropped only if its account was removed meanwhile.
    private func sweepAccountStillSaved(_ account: SpendingSweepAccount) -> Bool {
        accountStillSaved(account.owner)
    }

    /// `spendingAddresses(inRange:)` for the sweep's account, from its own chain nodes.
    private func sweepAddresses(inRange range: Range<Int>, account: SpendingSweepAccount) -> [Int: String] {
        var result: [Int: String] = [:]
        for index in range {
            if Self.isQuantumIndex(index) {
                if let chainKey = account.chainKey,
                   let address = quantumAddress(at: index, chainKey: chainKey, owner: account.owner) {
                    result[index] = address
                }
            } else if let address = spendingAddress(at: index, changeKey: account.changeKey, owner: account.owner) {
                result[index] = address
            }
        }
        return result
    }

    /// An account's legacy chain end: the stored bound (never a quantum-space value), at least
    /// the primary pointer when it is on the legacy chain.
    private func legacyMaxIndex(owner: String) -> Int {
        if currentWallet?.publicAddress == owner { return maxSpendingAddressIndex }
        func stored(_ suffix: String) -> Int? {
            guard let key = spendingDefaultsKey(suffix, owner: owner),
                  let value = UserDefaults.standard.object(forKey: key) as? Int,
                  !Self.isQuantumIndex(value) else { return nil }
            return value
        }
        return max(stored("maxIndex") ?? 0, stored("index") ?? 0)
    }

    /// Raises an account's legacy chain end. The current account also keeps its Wallet record in
    /// step (`updateSpendingBounds`); another account gets the stored bound, which is what it
    /// reads first when it is loaded again.
    private func raiseLegacyMaxIndex(_ value: Int, owner: String) async {
        if currentWallet?.publicAddress == owner {
            await updateSpendingBounds(maxIndex: value)
        } else if let key = spendingDefaultsKey("maxIndex", owner: owner) {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    /// Derives the spending addresses for an arbitrary index range with a SINGLE seed decrypt
    /// (shared change-node key), reading/filling the persistent per-index address cache.
    /// Built for the Address Visibility pager's beyond-revealed pages: calling the public
    /// `spendingAddress(at:)` once per row re-did the Secure Enclave decrypt + PBKDF2 per
    /// index, which froze (or, on a transient keychain failure, blanked) a whole 50-row page.
    /// Returns an empty map when the seed is unavailable this instant - callers should treat
    /// that as "try again", never as "these indices don't exist".
    func spendingAddresses(inRange range: Range<Int>) -> [Int: String] {
        guard !range.isEmpty else { return [:] }
        // Serve fully-cached ranges without touching the keychain at all.
        var result: [Int: String] = [:]
        var missing: [Int] = []
        if let cacheKey = spendingAddressCacheKey() {
            let cached = DerivedAddressStore.addresses(cacheKey)
            for index in range {
                if let address = cached[String(index)] {
                    result[index] = address
                } else {
                    missing.append(index)
                }
            }
        } else {
            missing = Array(range)
        }
        guard !missing.isEmpty else { return result }
        let legacyMissing = missing.filter { !Self.isQuantumIndex($0) }
        let quantumMissing = missing.filter { Self.isQuantumIndex($0) }
        if !legacyMissing.isEmpty, let changeKey = spendingChangeKey() {
            for index in legacyMissing {
                if let address = spendingAddress(at: index, changeKey: changeKey) {
                    result[index] = address
                }
            }
        }
        if !quantumMissing.isEmpty, let chainKey = quantumChainKey() {
            for index in quantumMissing {
                if let address = quantumAddress(at: index, chainKey: chainKey) {
                    result[index] = address
                }
            }
        }
        return result
    }

    /// Every revealed spending-chain address (0...maxSpendingAddressIndex), derived with a
    /// single seed decrypt via the shared change-node key - for callers that need the whole
    /// set WITHOUT balances (e.g. AddressActivityNotifier's own-address watch set), unlike
    /// `getSpendingAddressList()` which also fires a UTXO fetch.
    /// Which of this wallet's own addresses `address` is: "Chatting Address", or a spending
    /// address's name ("Address #3", or the name the person gave it). nil for anyone else's.
    /// Cheap enough for a view body: the address-to-index map is built once per account and
    /// address count (`spendingAddresses(inRange:)` serves it from its cache).
    func ownAddressLabel(for address: String) -> String? {
        let target = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty, let wallet = currentWallet?.publicAddress.lowercased() else { return nil }
        if target == wallet { return AppLocalization.string("Chatting Address") }
        let key = "\(wallet)|\(maxSpendingAddressIndex)|q\(maxQuantumAddressIndex)"
        if Self.ownAddressIndexCache?.key != key {
            var map: [String: Int] = [:]
            for (index, spending) in spendingAddresses(inRange: 0..<(max(0, maxSpendingAddressIndex) + 1)) {
                map[spending.lowercased()] = index
            }
            if maxQuantumAddressIndex >= 0 {
                let quantumRange = Self.quantumIndexBase..<(Self.quantumIndexBase + maxQuantumAddressIndex + 1)
                for (index, spending) in spendingAddresses(inRange: quantumRange) {
                    map[spending.lowercased()] = index
                }
            }
            Self.ownAddressIndexCache = (key, map)
        }
        guard let index = Self.ownAddressIndexCache?.map[target] else { return nil }
        let named = spendingLabels[index]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !named.isEmpty { return named }
        return "Address #\(Self.addressNumber(forIndex: index))"
    }

    /// The number people see for a spending address. The Chatting Address is #0, so the legacy
    /// chain's first slot shows as #1; the quantum chain has no chatting address and starts at #0.
    nonisolated static func addressNumber(forIndex index: Int) -> Int {
        isQuantumIndex(index) ? index - quantumIndexBase : index + 1
    }

    private static var ownAddressIndexCache: (key: String, map: [String: Int])?

    func allSpendingAddresses() -> [String] {
        // Through the address cache: the seed can't be read while the phone is locked, and a
        // background wake-up must still know these addresses.
        let legacy = spendingAddresses(inRange: 0..<(max(0, maxSpendingAddressIndex) + 1))
        var out = legacy.keys.sorted().compactMap { legacy[$0] }
        let quantumMax = maxQuantumAddressIndex
        if quantumMax >= 0 {
            let quantum = spendingAddresses(inRange: Self.quantumIndexBase..<(Self.quantumIndexBase + quantumMax + 1))
            out += quantum.keys.sorted().compactMap { quantum[$0] }
        }
        return out
    }

    private static var ownAddressSetCache: (key: String, set: Set<String>)?

    /// Hides (or shows) a spending address in Manage Addresses. Any address can be hidden -
    /// funded ones too: the person can start the list over from nothing (Address Visibility >
    /// Hide All). Nothing is lost: Profile's Manage Addresses total still counts hidden
    /// addresses, and Address Visibility brings any back.
    func setSpendingAddressHidden(index: Int, hidden: Bool) async -> Bool {
        var current = hiddenSpendingIndices
        if hidden {
            current.insert(index)
        } else {
            current.remove(index)
        }
        hiddenSpendingIndices = current
        return true
    }

    /// Hides every revealed spending address at once (Address Visibility > Hide All): Manage
    /// Addresses then starts empty under the chatting address.
    func hideAllSpendingAddresses() {
        var hidden = Set(0...max(0, maxSpendingAddressIndex))
        if maxQuantumAddressIndex >= 0 {
            for i in 0...maxQuantumAddressIndex { hidden.insert(Self.quantumIndexBase + i) }
        }
        hiddenSpendingIndices = hidden
    }

    /// Read-only snapshot of the hidden set, so Manage Addresses can apply bulk
    /// visibility edits to its already-loaded rows instantly on sheet dismiss
    /// (before the full balance/used reload finishes).
    func hiddenSpendingIndexSet() -> Set<Int> {
        hiddenSpendingIndices
    }

    func setSpendingAddressLabel(index: Int, label: String) {
        var labels = spendingLabels
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            labels.removeValue(forKey: index)
        } else {
            labels[index] = trimmed
        }
        spendingLabels = labels
    }

    /// Live-derived list of every revealed spending address (0...maxSpendingAddressIndex),
    /// with current balances. `everUsed` is left at its default (false) - callers that need it
    /// check history separately (`WalletService.hasSpendingAddressBeenUsed`), same as before.
    func getSpendingAddressList() async -> [SpendingAddressEntry] {
        let maxIndex = maxSpendingAddressIndex
        let activeIndex = currentSpendingAddressIndex
        let hidden = hiddenSpendingIndices
        let labels = spendingLabels

        var addressesByIndex: [Int: String] = [:]
        if let changeKey = spendingChangeKey() {
            for index in 0...maxIndex {
                if let address = spendingAddress(at: index, changeKey: changeKey) {
                    addressesByIndex[index] = address
                }
            }
        }
        let quantumMax = maxQuantumAddressIndex
        if quantumMax >= 0, let chainKey = quantumChainKey() {
            for quantumIndex in 0...quantumMax {
                let index = Self.quantumIndexBase + quantumIndex
                if let address = quantumAddress(at: index, chainKey: chainKey) {
                    addressesByIndex[index] = address
                }
            }
        }

        let allUtxos = (try? await NodePoolService.shared.getUtxosByAddresses(Array(addressesByIndex.values))) ?? []
        var balanceByAddress: [String: UInt64] = [:]
        for utxo in allUtxos {
            balanceByAddress[utxo.address, default: 0] += utxo.amount
        }

        return addressesByIndex.keys.sorted().map { index in
            let address = addressesByIndex[index] ?? ""
            return SpendingAddressEntry(
                index: index,
                address: address,
                balanceSompi: balanceByAddress[address] ?? 0,
                isCurrent: index == activeIndex,
                everUsed: false,
                label: labels[index],
                hidden: hidden.contains(index)
            )
        }
    }

    /// Where a discovery scan currently is, so a UI can count up instead of showing an unmoving
    /// spinner for the half-minute a gap-limit walk takes. Mirrors `ColdStorageManager`'s.
    struct SpendingDiscoveryProgress: Equatable {
        let checkingIndex: Int
        let foundCount: Int
    }

    /// Swept whatever the gaps, so a run of empty addresses can never end the scan early.
    static let spendingDeepScanFloor = 1000
    /// Hard stop, so the scan always terminates.
    static let maxSpendingScanIndex = 5000
    /// Addresses per bulk UTXO request.
    static let spendingScanBatchSize = 100
    /// KNS has no bulk endpoint, so domain ownership is only probed this far in.
    static let spendingKnsProbeDepth = 200

    /// Scan for spending addresses worth surfacing. Extends `maxSpendingAddressIndex` to cover
    /// the highest match. Returns how many addresses were FOUND, not the new bound.
    ///
    /// An address is worth surfacing when it HOLDS SOMETHING - a balance, or a KNS domain - not
    /// when it has transaction history. History still decides the "Unused" badge on a row (address
    /// reuse is a privacy problem), but every address ever touched and emptied is not what this
    /// list is for.
    ///
    /// The walk starts at index 0, never at the stored high-water mark, because the answer
    /// CHANGES: an address that was empty last month can hold a balance today, and a scan starting
    /// past it would never look again.
    ///
    /// ## Why this is not a gap-limit walk any more
    ///
    /// It was: one UTXO request per address, stop after 20 consecutive empties. That design
    /// cannot find what it is asked to find. A wallet with a balance at index 291 and any run of
    /// 20 empty addresses before it - which is ordinary, since a spending chain reveals addresses
    /// it never funds - ended the scan in the twenties and reported nothing, every time, with no
    /// way for the reader to make it look further.
    ///
    /// So it sweeps a floor of `spendingDeepScanFloor` indices whatever the gaps, in batches of
    /// `spendingScanBatchSize`. `getUtxosByAddresses` has always taken an array; asking it for
    /// one address at a time is what made this hundreds of round trips. Batched, it is both
    /// thorough and far faster than the walk it replaces. Past the floor it keeps going while
    /// something is still turning up, and stops for good at `maxSpendingScanIndex`.
    @discardableResult
    func discoverSpendingAddresses(
        gapLimit: Int = 60,
        onProgress: (@MainActor (SpendingDiscoveryProgress) -> Void)? = nil
    ) async -> Int {
        // The sweep belongs to the account it started for (IOS-107, owner's choice): its address
        // and chain nodes are taken now, and every derivation and write below goes to that
        // account even if another one is active by the time an await returns. Results are
        // dropped only if the account was removed meanwhile.
        guard let account = spendingSweepAccount() else { return 0 }

        var lastMatchIndex = -1
        var matchCount = 0
        var matchedIndices: Set<Int> = []

        // The balances were already batched; KNS was not. It was asked about the first two hundred
        // addresses ONE AT A TIME, and a KNS lookup measures a third to two thirds of a second -
        // a minute or two of sequential HTTP that no amount of batching the balances touches.
        //
        // `AddressActivityService` answers "was this address ever used" for the whole window in a
        // handful of requests, so balances and KNS are both asked only about the addresses the
        // chain says were actually touched. Neither a balance nor a domain can sit on an address
        // that has never been touched, so the filter loses nothing.
        let window = 0..<Self.spendingDeepScanFloor
        let derivedWindow = sweepAddresses(inRange: window, account: account)
        let orderedWindow = window.compactMap { index in derivedWindow[index].map { (index, $0) } }
        if let onProgress {
            let snapshot = SpendingDiscoveryProgress(checkingIndex: 0, foundCount: 0)
            await MainActor.run { onProgress(snapshot) }
        }

        if !orderedWindow.isEmpty,
           let activity = await AddressActivityService.lastActivity(for: orderedWindow.map { $0.1 }) {
            let touched = orderedWindow.filter { activity[$0.1] != nil }

            var funded: Set<String> = []
            if !touched.isEmpty,
               let utxos = try? await NodePoolService.shared.getUtxosByAddresses(touched.map { $0.1 }) {
                funded = Set(utxos.map { $0.address })
            }
            if let onProgress {
                let snapshot = SpendingDiscoveryProgress(checkingIndex: touched.last?.0 ?? 0, foundCount: funded.count)
                await MainActor.run { onProgress(snapshot) }
            }

            let knsCandidates = touched.filter { $0.0 < Self.spendingKnsProbeDepth && !funded.contains($0.1) }
            var domainOwners: Set<String> = []
            if !knsCandidates.isEmpty {
                domainOwners = await withTaskGroup(of: String?.self) { group -> Set<String> in
                    for (_, address) in knsCandidates {
                        group.addTask { await NameServicesClient.shared.ownsAnyName(address) ? address : nil }
                    }
                    var owners: Set<String> = []
                    for await owner in group { if let owner { owners.insert(owner) } }
                    return owners
                }
            }

            for (i, address) in touched where funded.contains(address) || domainOwners.contains(address) {
                lastMatchIndex = max(lastMatchIndex, i)
                matchCount += 1
                matchedIndices.insert(i)
            }
        } else {
            // The configured REST server does not serve /addresses/active, or could not be
            // reached. Fall back to the batched sweep this replaced.
            AppLog.log("%@", "[WalletManager] Spending discovery: bulk activity unavailable, using the batched sweep")
            var consecutiveMisses = 0
            var index = 0
            while index < Self.maxSpendingScanIndex {
                // Past the floor, stop once nothing has turned up for a long stretch.
                if index >= Self.spendingDeepScanFloor && consecutiveMisses >= gapLimit { break }

                let upper = min(index + Self.spendingScanBatchSize, Self.maxSpendingScanIndex)
                let batch = index..<upper
                if let onProgress {
                    let snapshot = SpendingDiscoveryProgress(checkingIndex: index, foundCount: matchCount)
                    await MainActor.run { onProgress(snapshot) }
                }

                guard sweepAccountStillSaved(account) else { return 0 }
                let derived = sweepAddresses(inRange: batch, account: account)
                if derived.isEmpty { break }

                let addresses = batch.compactMap { derived[$0] }
                guard let utxos = try? await NodePoolService.shared.getUtxosByAddresses(addresses) else {
                    AppLog.log("[WalletManager] Spending discovery: balances unavailable at %d, stopping", index)
                    break
                }
                let funded = Set(utxos.map { $0.address })

                for i in batch {
                    guard let address = derived[i] else { continue }
                    let matches: Bool
                    if funded.contains(address) {
                        matches = true
                    } else if i < Self.spendingKnsProbeDepth {
                        matches = await NameServicesClient.shared.ownsAnyName(address)
                    } else {
                        matches = false
                    }
                    if matches {
                        lastMatchIndex = i
                        matchCount += 1
                        matchedIndices.insert(i)
                        consecutiveMisses = 0
                    } else {
                        consecutiveMisses += 1
                    }
                }
                index = upper
            }
        }

        // One read-modify-write of the hidden set, not one per index: it is a computed property
        // over UserDefaults, so an insert in a loop would read and rewrite the whole thing every
        // time - and this loop can now be hundreds of indices long.
        guard sweepAccountStillSaved(account) else {
            AppLog.log("%@", "[WalletManager] Discovery dropped: its account was removed during the sweep")
            return 0
        }
        let previousMax = legacyMaxIndex(owner: account.owner)
        let storedHidden = hiddenIndices(owner: account.owner)
        var hidden = storedHidden
        // Anything the scan matched gets un-hidden. A previously-hidden address that now holds a
        // balance or a domain would otherwise be found and then dropped straight back out of the
        // list, which reads as the scan not finding it at all - and hiding is a tidying choice
        // about empty addresses, not a decision that should outrank a balance.
        hidden.subtract(matchedIndices)
        if lastMatchIndex > previousMax {
            // Hide the empty indices the new bound sweeps in, exactly as `revealSpendingAddress`
            // does. The scan reaches a thousand addresses deep now, so a match at index 291 would
            // otherwise raise the bound and flood Manage Addresses with 290 empty rows.
            for i in (previousMax + 1)..<lastMatchIndex where !matchedIndices.contains(i) {
                hidden.insert(i)
            }
        }
        if hidden != storedHidden {
            setHiddenIndices(hidden, owner: account.owner)
        }

        // The stored bound has to cover the highest match so those rows can be derived and
        // shown, and it only ever grows: an address that held funds last month and is empty now
        // should not vanish from the list.
        if lastMatchIndex > previousMax {
            await raiseLegacyMaxIndex(lastMatchIndex, owner: account.owner)
        }

        matchCount += await discoverQuantumAddresses(account: account)

        return matchCount
    }

    /// How many quantum slots one step of the restore sweep looks at. The sweep keeps stepping
    /// while a window turns up any activity (IOS-101: a fixed 200 missed funds past slot 199),
    /// up to `quantumScanLimit`.
    static let quantumScanFloor = 200
    static let quantumScanLimit = 10_000

    /// The quantum chain's restore sweep: funded slots are shown again, and the chain's end is
    /// set past every slot that EVER saw activity - not only funded ones - so a restored wallet
    /// never hands out an already-used (possibly key-revealed) slot as fresh change or a fresh
    /// receive address (IOS-101). Returns how many funded slots it found.
    @discardableResult
    private func discoverQuantumAddresses(account: SpendingSweepAccount) async -> Int {
        // same account rule as the legacy sweep (IOS-107)
        guard account.chainKey != nil, sweepAccountStillSaved(account) else { return 0 }
        let base = Self.quantumIndexBase
        var start = 0
        var matched: [Int] = []
        var highestUsed = -1
        while start < Self.quantumScanLimit {
            let window = (base + start)..<(base + start + Self.quantumScanFloor)
            let derived = sweepAddresses(inRange: window, account: account)
            let ordered = window.compactMap { index in derived[index].map { (index, $0) } }
            guard !ordered.isEmpty else { break }

            // Activity decides how far the chain reaches; funds decide what is shown. Without the
            // bulk activity answer (a REST server that doesn't serve it), only this window's
            // balances can be read, and the sweep stops there as before.
            let activity = await AddressActivityService.lastActivity(for: ordered.map { $0.1 })
            let touched = activity.map { a in ordered.filter { a[$0.1] != nil } } ?? ordered
            if let deepest = touched.map({ $0.0 }).max(), activity != nil {
                highestUsed = max(highestUsed, deepest - base)
            }
            if !touched.isEmpty,
               let utxos = try? await NodePoolService.shared.getUtxosByAddresses(touched.map { $0.1 }) {
                let funded = Set(utxos.map { $0.address })
                matched += touched.filter { funded.contains($0.1) }.map { $0.0 }
            }
            guard activity != nil, !touched.isEmpty else { break }
            start += Self.quantumScanFloor
            guard sweepAccountStillSaved(account) else { return 0 }
        }
        if let highestFunded = matched.max() {
            highestUsed = max(highestUsed, highestFunded - base)
        }
        guard highestUsed >= 0, sweepAccountStillSaved(account) else { return 0 }

        let storedHidden = hiddenIndices(owner: account.owner)
        var hidden = storedHidden
        hidden.subtract(matched)
        let previousMax = quantumMaxIndex(owner: account.owner)
        if highestUsed > previousMax {
            let fundedSet = Set(matched)
            for index in (base + previousMax + 1)...(base + highestUsed) where !fundedSet.contains(index) {
                hidden.insert(index)
            }
            setMaxQuantumAddressIndex(highestUsed, owner: account.owner)
        }
        if hidden != storedHidden {
            setHiddenIndices(hidden, owner: account.owner)
        }
        return matched.count
    }

}

/// Derived spending addresses (public and deterministic - never keys), one set per account and
/// network, each in its own file under Application Support/DerivedAddresses and held in memory
/// once read.
///
/// They lived in UserDefaults until 2026-10-20. One account's set had grown to ~19,000
/// addresses (1.4 MB): every lookup copied the whole dictionary out of UserDefaults, every newly
/// derived address rewrote all of it (a Discover pass: a thousand 1.4 MB writes), and the sets
/// together pushed the app's UserDefaults past iOS's 4 MB limit - past which iOS refuses EVERY
/// write the app makes (settings, spent marks, chain bounds, saved accounts), not just the big one.
@MainActor
enum DerivedAddressStore {
    private static var sets: [String: [String: String]] = [:]
    private static var dirty: Set<String> = []
    private static var flushScheduled = false
    private static var prepared = false
    private static let legacyPrefix = "kachat_spending_derived_addresses_"
    private static let movedFlag = "kachat_derived_addresses_moved_to_files_v1"
    private static let ioQueue = DispatchQueue(label: "kachat.derived-addresses", qos: .utility)

    static func address(_ key: String, _ index: Int) -> String? {
        addresses(key)[String(index)]
    }

    static func addresses(_ key: String) -> [String: String] {
        prepare()
        if let set = sets[key] { return set }
        let set = readFile(key)
        sets[key] = set
        return set
    }

    static func store(_ key: String, _ index: Int, _ address: String) {
        _ = addresses(key)
        guard sets[key]?[String(index)] != address else { return }
        sets[key]?[String(index)] = address
        dirty.insert(key)
        guard !flushScheduled else { return }
        flushScheduled = true
        // Coalesced: a Discover pass derives hundreds in a row and writes once. Losing the
        // last few to a kill costs nothing - they are derived again.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            flush()
        }
    }

    /// Drops a set and its file (its account was removed).
    static func remove(_ key: String) {
        sets[key] = nil
        dirty.remove(key)
        guard let url = fileURL(key) else { return }
        ioQueue.async { try? FileManager.default.removeItem(at: url) }
    }

    private static func flush() {
        flushScheduled = false
        let pending = dirty
        dirty = []
        for key in pending {
            guard let set = sets[key], let url = fileURL(key),
                  let data = try? JSONEncoder().encode(set) else { continue }
            ioQueue.async { write(data, to: url) }
        }
    }

    /// Moves every set still in UserDefaults (any account, either network) into its file and out
    /// of UserDefaults - once, before the app's first other write (`WalletManager.init`), so a
    /// domain over the 4 MB limit is back under it before anything else tries to save.
    static func prepare() {
        guard !prepared else { return }
        prepared = true
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: movedFlag) else { return }
        let domain = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) }
            ?? defaults.dictionaryRepresentation()
        var movedSets = 0
        var movedAddresses = 0
        for (key, value) in domain where key.hasPrefix(legacyPrefix) {
            if let old = value as? [String: String] {
                var merged = readFile(key)
                merged.merge(old) { current, _ in current }
                sets[key] = merged
                // written before the UserDefaults copy goes
                if let url = fileURL(key), let data = try? JSONEncoder().encode(merged) {
                    write(data, to: url)
                }
                movedAddresses += old.count
            }
            defaults.removeObject(forKey: key)
            movedSets += 1
        }
        defaults.set(true, forKey: movedFlag)
        var sizeNote = "?"
        if let id = Bundle.main.bundleIdentifier, let after = defaults.persistentDomain(forName: id),
           let data = try? PropertyListSerialization.data(fromPropertyList: after, format: .binary, options: 0) {
            sizeNote = "\(data.count / 1024) KB"
        }
        AppLog.log("[DerivedAddressStore] Moved %d sets (%d addresses) out of UserDefaults; UserDefaults now %@",
                   movedSets, movedAddresses, sizeNote)
    }

    private static func readFile(_ key: String) -> [String: String] {
        guard let url = fileURL(key), let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return decoded
    }

    private nonisolated static func fileURL(_ key: String) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DerivedAddresses", isDirectory: true)
            .appendingPathComponent(key.replacingOccurrences(of: ":", with: "_") + ".json")
    }

    private nonisolated static func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        // derivable from the seed at any time: no reason to carry the account's addresses into
        // device backups
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(values)
    }
}

extension Notification.Name {
    /// Posted after the primary spending address pointer changes - a manual "Set as Primary"
    /// or the automatic post-send rotation (`WalletService.sendPaymentInternal` calling
    /// `setActiveSpendingAddress` with the fresh change index). Open screens that render an
    /// `isCurrent` star or gate actions on "not the primary" reload on it so the old primary
    /// row becomes hideable right away.
    static let spendingPrimaryChanged = Notification.Name("spendingPrimaryChanged")
}
