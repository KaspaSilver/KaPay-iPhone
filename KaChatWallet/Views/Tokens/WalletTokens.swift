import SwiftUI
import UserNotifications

// Tokens on Kaspa L1 (KCC-20), starting with Trestly's kUSDT (owner's call, 2026-11-19). KaPay is
// where tokens are bought, swapped and sold; the other apps on the same words only hold and send
// them.
//
// UI stage: these screens run on sample data (`TokenWallet.isSampleData`) until the token code is
// wired (kUSDT's covenant, the balance lookup and the transfer builder; see kusdt-open's SPEC.md).
// Every screen says so with `TokenSampleBadge`.

/// A token KaPay can hold. Amounts are whole base units (`decimals` places: kUSDT has 6).
struct WalletToken: Identifiable, Hashable {
    let id: String
    let symbol: String
    /// What people read under the symbol ("Bridged USDT").
    let name: LocalizedStringKey
    let decimals: Int
    /// Worth one US dollar (a stablecoin): the screens show its dollar value without a price feed.
    let isDollarStable: Bool
    /// Who issues it on Kaspa.
    let issuer: String
    let issuerSite: URL
    /// Where its backing can be checked on chain.
    let backingURL: URL
    /// KAS every token coin holds (kUSDT's `tokenValue`, 1.5 KAS): a send carries it to the
    /// recipient's new coin.
    let kasPerCoinSompi: UInt64

    static func == (lhs: WalletToken, rhs: WalletToken) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// kUSDT: USDT from Ethereum and BNB Chain, held 1:1 in Trestly's vault and issued as a
    /// KCC-20 token on Kaspa L1 (kusdt-open, mainnet launched 2026-11-15).
    static let kusdt = WalletToken(
        id: "kusdt",
        symbol: "kUSDT",
        name: "Bridged USDT",
        decimals: 6,
        isDollarStable: true,
        issuer: "Trestly",
        issuerSite: URL(string: "https://trestly.io")!,
        backingURL: URL(string: "https://etherscan.io/address/0xfa9869982542FB20baD929789B252b7b06EeE10e")!,
        kasPerCoinSompi: 150_000_000
    )
}

extension KaspaUnit {
    /// "1,234.5 KAS": `amount`, with the thousands grouped the way this phone writes them.
    static func groupedAmount(_ sompi: UInt64) -> String {
        "\(KaspaAmountEntry.grouped(plain(sompi))) \(symbol)"
    }

    /// "1,234.50000000": all eight decimals, grouped (Manage Addresses' balances).
    static func groupedExact(_ sompi: UInt64) -> String {
        KaspaAmountEntry.grouped("\(sompi / 100_000_000).\(String(format: "%08llu", sompi % 100_000_000))")
    }
}

/// Turning token base units into text and back.
enum TokenAmount {
    /// "125.50", "0.25", "1,250", "0.000001": grouped, at least two decimals for a dollar token,
    /// trailing zeros past that dropped.
    static func plain(_ units: UInt64, token: WalletToken) -> String {
        // grouped and with the decimal point the way this phone writes them
        KaspaAmountEntry.grouped(typed(units, token: token, keepCents: token.isDollarStable))
    }

    /// "125.5" (or "125.50" with `keepCents`): no grouping, "." the decimal point - what the
    /// keypad types (Max).
    static func typed(_ units: UInt64, token: WalletToken, keepCents: Bool = false) -> String {
        let scale = pow10(token.decimals)
        let whole = units / scale
        var frac = String(format: "%0\(token.decimals)llu", units % scale)
        let keep = keepCents ? 2 : 0
        while frac.count > keep, frac.hasSuffix("0") { frac.removeLast() }
        return frac.isEmpty ? "\(whole)" : "\(whole).\(frac)"
    }

    /// "125.50 kUSDT".
    static func amount(_ units: UInt64, token: WalletToken) -> String {
        "\(plain(units, token: token)) \(token.symbol)"
    }

    /// "$125.50" for a dollar token (two decimals), nil for others.
    static func dollars(_ units: UInt64, token: WalletToken) -> String? {
        guard token.isDollarStable else { return nil }
        let value = Double(units) / Double(pow10(token.decimals))
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = AppLocalization.locale
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 2
        return f.string(from: NSNumber(value: value))
    }

    /// Typed text ("12.5") to base units; nil for nothing, zero or more decimals than the token has.
    static func units(fromTyped text: String, token: WalletToken) -> UInt64? {
        let clean = text.replacingOccurrences(of: ",", with: "")
        guard !clean.isEmpty else { return nil }
        let parts = clean.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let whole = UInt64(parts[0].isEmpty ? "0" : String(parts[0])) else { return nil }
        var fracText = parts.count == 2 ? String(parts[1]) : ""
        guard fracText.count <= token.decimals else { return nil }
        fracText += String(repeating: "0", count: token.decimals - fracText.count)
        guard let frac = UInt64(fracText.isEmpty ? "0" : fracText) else { return nil }
        let (scaled, o1) = whole.multipliedReportingOverflow(by: pow10(token.decimals))
        let (total, o2) = scaled.addingReportingOverflow(frac)
        guard !o1, !o2, total > 0 else { return nil }
        return total
    }

    static func pow10(_ n: Int) -> UInt64 {
        (0..<n).reduce(UInt64(1)) { value, _ in value * 10 }
    }
}

/// One line of a token's activity.
struct TokenActivity: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case received, sent, swapped, bridged, combined }
    /// "txid:holding:kind" for what this phone records, so a send noted twice (a lost answer,
    /// then Try Again) is one line.
    var id = UUID().uuidString
    let kind: Kind
    let units: UInt64
    /// The other side: an address or a name.
    let counterparty: String
    let date: Date
    var pending = false
    /// Which of your addresses it happened on (`TokenHolding.id`).
    var holdingID = "chatting"
}

/// Where some of a token is held: the Chatting Address or one of the regular (legacy, key)
/// spending addresses. Never a quantum-safe address: sending a token from one reveals its key
/// (its KAS has to be spent with it), and Trestly's builder and pool don't take one.
struct TokenHolding: Identifiable, Equatable {
    /// nil: the Chatting Address; else the legacy spending index.
    let spendingIndex: Int?
    let address: String
    let units: UInt64
    /// Coins (UTXOs) holding it here: each holds the token's `kasPerCoinSompi` of KAS.
    let coins: Int

    var id: String { spendingIndex.map { "s\($0)" } ?? "chatting" }
    var isChatting: Bool { spendingIndex == nil }

    /// "Chatting Address", or the address's name as Manage Addresses shows it: the one you gave it
    /// (Rename Address, shared with Manage Addresses), else "Address #3".
    @MainActor var label: String {
        guard let spendingIndex else { return AppLocalization.string("Chatting Address") }
        return WalletManager.shared.ownAddressLabel(for: address) ?? "Address #\(WalletManager.addressNumber(forIndex: spendingIndex))"
    }
}

/// The account's tokens: balances by address, activity, and what can be done with them.
/// Tokens live on the Chatting Address and on the regular spending addresses (owner's call,
/// 2026-11-19: privacy from the start), so a payment can go to an address that isn't tied to
/// your name.
@MainActor
final class TokenWallet: ObservableObject {
    static let shared = TokenWallet()

    /// The screens ran on sample data before the token code was wired (2026-11-19). Off: balances
    /// come from Trestly's API, every coin checked on the node (`KusdtBalances`).
    static let isSampleData = false

    /// The tokens KaPay shows, in order.
    let tokens: [WalletToken] = [.kusdt]

    /// Where each token is held, by token id; nil until the first lookup answers.
    @Published private(set) var holdings: [String: [TokenHolding]] = [:]
    @Published private(set) var activity: [String: [TokenActivity]] = [:]
    /// Each address's verified coins, by holding id (what a send spends).
    private(set) var coins: [String: [KusdtBalances.Coin]] = [:]
    @Published private(set) var isRefreshing = false
    /// Why the last lookup failed; the screens keep the last good balances.
    @Published private(set) var lastError: String?
    private var lastRefreshed: Date?
    /// The account the balances belong to: another account's are dropped at once.
    private var loadedAccount: String?

    /// A coin of yours that a send from this phone just made (its change, or kUSDT sent to another
    /// of your addresses). Trestly's list can take a while to show it, and a balance built from
    /// that list alone dropped to 0 after a send. So it's checked on the node with the listed
    /// coins (`KusdtBalances.Expected`) until Trestly lists it, for up to 30 minutes.
    private struct PendingCoin {
        let holdingID: String
        let address: String
        let expected: KusdtBalances.Expected
        let since: Date
        var key: String { "\(expected.transactionId):\(expected.index)" }
    }
    private var pendingCoins: [PendingCoin] = []
    /// A refresh is due again shortly: a pending coin wasn't on the node yet.
    private var followUpScheduled = false

    private init() {}

    // MARK: Lookups

    /// Refreshes unless the balances are under `maxAge` seconds old (and for this account).
    func refreshIfStale(maxAge: TimeInterval = 60) async {
        let account = WalletManager.shared.currentWallet?.publicAddress
        if account == loadedAccount, let lastRefreshed, Date().timeIntervalSince(lastRefreshed) < maxAge { return }
        await refresh()
    }

    /// Every address that can hold tokens, looked up: the Chatting Address and each revealed
    /// regular spending address. Quantum addresses never hold them.
    func refresh() async {
        guard !isRefreshing, let account = WalletManager.shared.currentWallet?.publicAddress else { return }
        if account != loadedAccount {
            holdings = [:]
            coins = [:]
            pendingCoins = []
            loadedAccount = account
        }
        loadActivityIfNeeded(account: account)
        isRefreshing = true
        defer { isRefreshing = false }
        let manager = WalletManager.shared
        var targets: [(spendingIndex: Int?, address: String)] = [(nil, account)]
        let revealed = manager.spendingAddresses(inRange: 0..<(max(0, manager.maxSpendingAddressIndex) + 1))
        for index in revealed.keys.sorted() {
            if let address = revealed[index] { targets.append((index, address)) }
        }
        do {
            let results = try await lookUp(targets)
            // the account may have changed while the lookups ran
            guard WalletManager.shared.currentWallet?.publicAddress == account else { return }
            let previous = coins
            apply(results, for: .kusdt)
            loadActivityIfNeeded(account: account)
            await announceNewCoins(previous: previous, account: account, token: .kusdt)
            lastError = nil
            lastRefreshed = Date()
            scheduleFollowUpIfPending()
        } catch {
            lastError = error.localizedDescription
            AppLog.log("[kUSDT] lookup failed: %@", error.localizedDescription)
        }
    }

    /// The lookups, four at a time. Any one failing fails the refresh, so a partial answer is never
    /// shown as the whole balance.
    private func lookUp(_ targets: [(spendingIndex: Int?, address: String)],
                        progress: ((_ checkedThrough: Int?, _ found: Int) -> Void)? = nil) async throws -> [(spendingIndex: Int?, result: KusdtBalances.AddressResult)] {
        var out: [(spendingIndex: Int?, result: KusdtBalances.AddressResult)] = []
        let expectedByAddress = Dictionary(grouping: pendingCoins, by: \.address).mapValues { $0.map(\.expected) }
        var start = 0
        while start < targets.count {
            let batch = targets[start..<min(start + 4, targets.count)]
            try await withThrowingTaskGroup(of: (Int?, KusdtBalances.AddressResult).self) { group in
                for target in batch {
                    let expected = expectedByAddress[target.address] ?? []
                    group.addTask { (target.spendingIndex, try await KusdtBalances.fetch(address: target.address, expected: expected)) }
                }
                for try await (index, result) in group { out.append((index, result)) }
            }
            progress?(batch.last?.spendingIndex, out.filter { !$0.result.coins.isEmpty }.count)
            start += 4
        }
        return out
    }

    private func apply(_ results: [(spendingIndex: Int?, result: KusdtBalances.AddressResult)], for token: WalletToken) {
        // pending coins: let go once Trestly lists them, or after 30 minutes
        let listed = results.reduce(into: Set<String>()) { $0.formUnion($1.result.listedByAPI) }
        pendingCoins.removeAll { listed.contains($0.key) || Date().timeIntervalSince($0.since) > 1800 }
        let verified = Set(results.flatMap { $0.result.coins }.map(Self.outpointKey))
        // one sent in the last 2 minutes that the node doesn't show yet still counts in the balance
        // (not in what a send can spend), so the balance doesn't dip while the network catches up
        let landing = pendingCoins.filter { !verified.contains($0.key) && Date().timeIntervalSince($0.since) < 120 }

        var list: [TokenHolding] = []
        var byHolding: [String: [KusdtBalances.Coin]] = [:]
        for (index, result) in results {
            let extra = landing.filter { $0.address == result.address }
            guard !result.coins.isEmpty || !extra.isEmpty else { continue }
            let units = result.units + extra.reduce(UInt64(0)) { $0 + $1.expected.state.amount }
            let holding = TokenHolding(spendingIndex: index, address: result.address, units: units,
                                       coins: result.coins.count + extra.count)
            list.append(holding)
            byHolding[holding.id] = result.coins
        }
        list.sort { ($0.spendingIndex ?? -1) < ($1.spendingIndex ?? -1) }
        holdings[token.id] = list
        coins = byHolding
    }

    /// Every address holding it, hidden ones included (the total, Send's From, Trestly's list).
    func holdings(of token: WalletToken) -> [TokenHolding] {
        (allHoldings(of: token) ?? []).filter { $0.units > 0 }
    }

    /// The addresses Manage kUSDT lists, as Kaspa's Address Visibility decides for Manage
    /// Addresses: the Chatting Address always, then each regular address holding the token
    /// unless it's hidden, and any address without it that's checked on, in address order.
    func listedHoldings(of token: WalletToken) -> [TokenHolding] {
        let held = Dictionary(uniqueKeysWithValues: holdings(of: token).map { ($0.id, $0) })
        let hidden = hiddenHoldingIDs(of: token)
        let shown = shownEmptyIndices(of: token)
        var out: [TokenHolding] = []
        if let chatting = held["chatting"] {
            out.append(chatting)
        } else if let address = WalletManager.shared.currentWallet?.publicAddress {
            out.append(TokenHolding(spendingIndex: nil, address: address, units: 0, coins: 0))
        }
        var indices = Set(held.values.compactMap(\.spendingIndex).filter { !hidden.contains("s\($0)") })
        indices.formUnion(shown)
        for index in indices.sorted() {
            if let holding = held["s\(index)"] {
                out.append(holding)
            } else if let address = WalletManager.shared.spendingAddress(at: index) {
                out.append(TokenHolding(spendingIndex: index, address: address, units: 0, coins: 0))
            }
        }
        return out
    }

    /// Whether Address Visibility has this address on Manage kUSDT's list.
    func isListed(_ holding: TokenHolding, of token: WalletToken) -> Bool {
        guard let index = holding.spendingIndex else { return true }
        if holding.units > 0 { return !hiddenHoldingIDs(of: token).contains(holding.id) }
        return shownEmptyIndices(of: token).contains(index)
    }

    /// Address Visibility's checkmark, tapped: an address holding the token is hidden or shown,
    /// one without it is put on the list or taken off. The Chatting Address always stays.
    func toggleListed(_ holding: TokenHolding, of token: WalletToken) {
        guard let index = holding.spendingIndex else { return }
        if holding.units > 0 {
            var hidden = hiddenHoldingIDs(of: token)
            if hidden.remove(holding.id) == nil { hidden.insert(holding.id) }
            setHiddenHoldingIDs(hidden, of: token)
        } else {
            var shown = shownEmptyIndices(of: token)
            if shown.remove(index) == nil { shown.insert(index) }
            setShownEmptyIndices(shown, of: token)
        }
    }

    /// Hide All: the list starts over with only the Chatting Address. Nothing is lost: the
    /// hidden addresses still count in the total.
    func hideAllListed(of token: WalletToken) {
        setHiddenHoldingIDs(Set(holdings(of: token).filter { !$0.isChatting }.map(\.id)), of: token)
        setShownEmptyIndices([], of: token)
    }

    // MARK: Address Visibility

    /// Bumped when a visibility set changes, so the screens that read it redraw.
    @Published private(set) var visibilityRevision = 0

    /// Addresses holding the token that are hidden from Manage kUSDT, per account and token.
    func hiddenHoldingIDs(of token: WalletToken) -> Set<String> {
        guard let key = visibilityKey("hidden", token) else { return [] }
        return Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    func setHiddenHoldingIDs(_ ids: Set<String>, of token: WalletToken) {
        guard let key = visibilityKey("hidden", token) else { return }
        UserDefaults.standard.set(Array(ids).sorted(), forKey: key)
        visibilityRevision += 1
    }

    /// Spending indices without the token that are checked on, so Manage kUSDT lists them.
    func shownEmptyIndices(of token: WalletToken) -> Set<Int> {
        guard let key = visibilityKey("shown", token) else { return [] }
        return Set((UserDefaults.standard.array(forKey: key) as? [Int]) ?? [])
    }

    func setShownEmptyIndices(_ indices: Set<Int>, of token: WalletToken) {
        guard let key = visibilityKey("shown", token) else { return }
        UserDefaults.standard.set(Array(indices).sorted(), forKey: key)
        visibilityRevision += 1
    }

    private func visibilityKey(_ kind: String, _ token: WalletToken) -> String? {
        guard let account = WalletManager.shared.currentWallet?.publicAddress else { return nil }
        return "token_\(kind)_\(token.id)_\(account)"
    }

    // MARK: Sends

    /// A kUSDT send went out (`KusdtTransfer.send`): its coins are gone from the balances at once,
    /// every output it made is known (so your own change is never announced as received), and the
    /// balances are looked up again shortly, once the node has it.
    func noteSent(_ prepared: KusdtTransfer.Prepared) {
        guard let account = WalletManager.shared.currentWallet?.publicAddress else { return }
        let spent = Set(prepared.spentCoins.map(Self.outpointKey))
        for (id, list) in coins { coins[id] = list.filter { !spent.contains(Self.outpointKey($0)) } }
        pendingCoins.removeAll { spent.contains($0.key) }

        // the coins this send made that are yours: checked on the node until Trestly lists them
        let spentUnits = prepared.spentCoins.reduce(UInt64(0)) { $0 + $1.state.amount }
        if let changeIndex = prepared.changeIndex, spentUnits > prepared.amount,
           let owner = Kusdt.schnorrOwner(of: prepared.holding.address) {
            pendingCoins.append(PendingCoin(
                holdingID: prepared.holding.id, address: prepared.holding.address,
                expected: .init(transactionId: prepared.txid, index: changeIndex,
                                state: .plain(owner: owner, amount: spentUnits - prepared.amount)),
                since: Date()))
        }
        let ownRecipient = ownTokenAddress(prepared.recipient)
        if let ownRecipient, let owner = Kusdt.schnorrOwner(of: ownRecipient.address) {
            pendingCoins.append(PendingCoin(
                holdingID: ownRecipient.id, address: ownRecipient.address,
                expected: .init(transactionId: prepared.txid, index: 0, state: .plain(owner: owner, amount: prepared.amount)),
                since: Date()))
        }

        // the history: a combine, or a send (and its arrival, when it went to another of yours)
        let token = WalletToken.kusdt
        if prepared.recipient.lowercased() == prepared.holding.address.lowercased() {
            record(TokenActivity(id: "\(prepared.txid):\(prepared.holding.id):combined", kind: .combined, units: prepared.amount,
                                 counterparty: String(prepared.spentCoins.count), date: Date(), holdingID: prepared.holding.id),
                   token: token, account: account)
        } else {
            let to = ownRecipient.map { own in
                TokenHolding(spendingIndex: own.spendingIndex, address: own.address, units: 0, coins: 0).label
            } ?? prepared.recipientLabel ?? prepared.recipient
            record(TokenActivity(id: "\(prepared.txid):\(prepared.holding.id):sent", kind: .sent, units: prepared.amount,
                                 counterparty: to, date: Date(), holdingID: prepared.holding.id),
                   token: token, account: account)
            if let ownRecipient {
                record(TokenActivity(id: "\(prepared.txid):\(ownRecipient.id):received", kind: .received, units: prepared.amount,
                                     counterparty: prepared.holding.label, date: Date(), holdingID: ownRecipient.id),
                       token: token, account: account)
            }
        }

        var list = holdings[WalletToken.kusdt.id] ?? []
        if let i = list.firstIndex(where: { $0.id == prepared.holding.id }) {
            let old = list[i]
            let units = old.units > prepared.amount ? old.units - prepared.amount : 0
            list[i] = TokenHolding(spendingIndex: old.spendingIndex, address: old.address, units: units,
                                   coins: max(0, old.coins - prepared.spentCoins.count + (prepared.changeIndex == nil ? 0 : 1)))
        }
        if let ownRecipient {
            if let i = list.firstIndex(where: { $0.id == ownRecipient.id }) {
                let old = list[i]
                list[i] = TokenHolding(spendingIndex: old.spendingIndex, address: old.address,
                                       units: old.units + prepared.amount, coins: old.coins + 1)
            } else {
                list.append(TokenHolding(spendingIndex: ownRecipient.spendingIndex, address: ownRecipient.address,
                                         units: prepared.amount, coins: 1))
                list.sort { ($0.spendingIndex ?? -1) < ($1.spendingIndex ?? -1) }
            }
        }
        holdings[WalletToken.kusdt.id] = list.filter { $0.units > 0 || $0.coins > 0 }
        let key = seenKey(account: account, token: .kusdt)
        var seen = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        // every output of the send: it can only be yours if it's change, or a send to yourself
        for index in 0..<UInt32(prepared.rpc.outputs.count) { seen.insert("\(prepared.txid):\(index)") }
        UserDefaults.standard.set(Array(seen), forKey: key)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await self.refresh()
        }
    }

    /// The address a send went to, if it's one of yours that can hold tokens: the Chatting Address
    /// or a revealed regular spending address.
    private func ownTokenAddress(_ address: String) -> (id: String, spendingIndex: Int?, address: String)? {
        let manager = WalletManager.shared
        let target = address.lowercased()
        if manager.currentWallet?.publicAddress.lowercased() == target {
            return ("chatting", nil, manager.currentWallet?.publicAddress ?? address)
        }
        let revealed = manager.spendingAddresses(inRange: 0..<(max(0, manager.maxSpendingAddressIndex) + 1))
        guard let match = revealed.first(where: { $0.value.lowercased() == target }) else { return nil }
        return ("s\(match.key)", match.key, match.value)
    }

    /// A pending coin the node didn't show yet: look again in 5 seconds (the 2-minute window
    /// ends it).
    private func scheduleFollowUpIfPending() {
        let verified = Set(coins.values.flatMap { $0 }.map(Self.outpointKey))
        let waiting = pendingCoins.contains { !verified.contains($0.key) && Date().timeIntervalSince($0.since) < 120 }
        guard waiting, !followUpScheduled else { return }
        followUpScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self.followUpScheduled = false
            await self.refresh()
        }
    }

    /// The verified coins of one address (what a send from it can spend).
    func coins(of holding: TokenHolding) -> [KusdtBalances.Coin] { coins[holding.id] ?? [] }

    // MARK: Received notifications

    /// A token coin doesn't land on your address (it sits at its own contract address), so the
    /// Kaspa watch never sees it arrive. Instead each refresh compares the coins it found with the
    /// ones known before (kept per account on this phone) and announces the new ones as Received,
    /// like Kaspa: a local notification and the Notifications list, behind Settings >
    /// Notifications > Address Activity. Never announced: the first look on this phone (it only
    /// learns what's there), what Discover finds, and coins from your own transfers (the
    /// transaction spent a coin of yours, or paid from one of your addresses).
    private func announceNewCoins(previous: [String: [KusdtBalances.Coin]], account: String, token: WalletToken) async {
        let current = coins.values.flatMap { $0 }
        let known = seenOutpoints(account: account, token: token)
        defer { rememberSeen(current, account: account, token: token) }
        guard let known else { return } // first look: learn, don't announce
        let fresh = current.filter { !known.contains(Self.outpointKey($0)) }
        guard !fresh.isEmpty else { return }

        // a coin we knew that's gone now: something of ours was spent in this window
        let previousKeys = Set(previous.values.flatMap { $0 }.map(Self.outpointKey))
        let currentKeys = Set(current.map(Self.outpointKey))
        let ownCoinSpent = !previousKeys.subtracting(currentKeys).isEmpty
        let ownAddresses = Set(WalletManager.shared.allSpendingAddresses().map { $0.lowercased() } + [account.lowercased()])

        var received: [(holdingID: String, units: UInt64)] = []
        var checked: [String: Bool] = [:]
        for (holdingID, list) in coins {
            for coin in list where fresh.contains(coin) {
                let own: Bool
                if let cached = checked[coin.transactionId] {
                    own = cached
                } else {
                    own = await Self.isOwnTransfer(coin.transactionId, known: known, ownAddresses: ownAddresses, fallback: ownCoinSpent)
                    checked[coin.transactionId] = own
                }
                if !own, coin.state.amount > 0 {
                    received.append((holdingID, coin.state.amount))
                    record(TokenActivity(id: "\(coin.transactionId):\(holdingID):received", kind: .received,
                                         units: coin.state.amount, counterparty: "", date: Date(), holdingID: holdingID),
                           token: token, account: account)
                }
            }
        }
        guard !received.isEmpty, Self.notificationsEnabled else { return }
        postReceived(received, token: token)
    }

    /// Whether the transaction that made a coin was your own: it spent a coin of yours, or
    /// an input came from one of your addresses. When the REST API can't say, `fallback`.
    private static func isOwnTransfer(_ txid: String, known: Set<String>, ownAddresses: Set<String>, fallback: Bool) async -> Bool {
        guard let tx = await WalletService.shared.fetchFullTransaction(txId: txid, resolvePrevious: true),
              let inputs = tx.inputs, !inputs.isEmpty else { return fallback }
        for input in inputs {
            if let hash = input.previousOutpointHash?.lowercased(), let index = input.previousOutpointIndex,
               known.contains("\(hash):\(index)") { return true }
            if let address = input.previousOutpointAddress?.lowercased(), ownAddresses.contains(address) { return true }
        }
        return false
    }

    private func postReceived(_ received: [(holdingID: String, units: UInt64)], token: WalletToken) {
        let total = received.reduce(UInt64(0)) { $0 + $1.units }
        var byHolding: [String: UInt64] = [:]
        for r in received { byHolding[r.holdingID, default: 0] += r.units }
        let labels = holdings(of: token).filter { byHolding[$0.id] != nil }.map { $0.label }
        let content = UNMutableNotificationContent()
        content.title = String(format: AppLocalization.string("Received %@"), TokenAmount.amount(total, token: token))
        content.body = labels.count == 1
            ? String(format: AppLocalization.string("On your %@"), labels[0])
            : String(format: AppLocalization.string("On %d of your addresses"), labels.count)
        content.threadIdentifier = Self.notificationThread
        content.userInfo = ["token": token.id]
        let settings = AppSettings.load()
        content.sound = settings.incomingNotificationSoundEnabled ? .default : nil
        let id = "token-received-\(token.id)-\(UUID().uuidString)"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        GlobalNotificationCenter.shared.record(id: id, source: .token, title: content.title, body: content.body,
                                               timestamp: Int64(Date().timeIntervalSince1970 * 1000), targetId: token.id)
    }

    /// A tapped token notification opens that token's Manage screen (`KaChatApp`).
    nonisolated static let notificationThread = "token-received"

    /// Settings > Notifications > Address Activity, and notifications on at all (as for Kaspa).
    static var notificationsEnabled: Bool {
        let settings = AppSettings.load()
        return settings.addressActivityNotificationsEnabled && settings.notificationMode != .disabled
    }

    private static func outpointKey(_ coin: KusdtBalances.Coin) -> String { "\(coin.transactionId):\(coin.index)" }

    private func seenKey(account: String, token: WalletToken) -> String { "token_seen_\(token.id)_\(account)" }

    /// The coins known on this phone for the account; nil before its first look.
    private func seenOutpoints(account: String, token: WalletToken) -> Set<String>? {
        (UserDefaults.standard.stringArray(forKey: seenKey(account: account, token: token))).map(Set.init)
    }

    private func rememberSeen(_ list: [KusdtBalances.Coin], account: String, token: WalletToken) {
        let key = seenKey(account: account, token: token)
        var set = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        // the coins there now (and what Discover found), so the list never outgrows the wallet
        set = set.intersection(Set(coins.values.flatMap { $0 }.map(Self.outpointKey))).union(list.map(Self.outpointKey))
        UserDefaults.standard.set(Array(set), forKey: key)
    }

    // MARK: Checking while the app is open

    private var pollTask: Task<Void, Never>?

    /// While the app is open and signed in, the balances are checked every 90 seconds, so a token
    /// that arrives is announced. Only with Address Activity notifications on; the screens refresh
    /// themselves either way.
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 90_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard UIApplication.shared.applicationState == .active,
                      WalletManager.shared.currentWallet != nil,
                      Self.notificationsEnabled else { continue }
                await self.refreshIfStale(maxAge: 80)
            }
        }
    }

    // MARK: Discover

    /// Finds the addresses holding the token: the Chatting Address and the regular spending
    /// addresses from the first through 20 past the last one revealed, each looked up (and checked
    /// on the node). Any it finds past the revealed ones are revealed, so they stay on the list.
    /// Reports each address as it goes; returns how many hold some.
    func discoverHoldings(of token: WalletToken, progress: @escaping (_ checking: Int, _ found: Int) -> Void) async -> Int {
        let manager = WalletManager.shared
        guard let account = manager.currentWallet?.publicAddress else { return 0 }
        let last = manager.maxSpendingAddressIndex + 20
        let derived = manager.spendingAddresses(inRange: 0..<(max(last, 0) + 1))
        var targets: [(spendingIndex: Int?, address: String)] = [(nil, account)]
        for index in derived.keys.sorted() {
            if let address = derived[index] { targets.append((index, address)) }
        }
        let results: [(spendingIndex: Int?, result: KusdtBalances.AddressResult)]
        do {
            // four at a time, like a refresh, reporting as each batch answers
            results = try await lookUp(targets) { checkedThrough, soFar in
                progress(checkedThrough.map(WalletManager.addressNumber(forIndex:)) ?? 0, soFar)
            }
        } catch {
            lastError = error.localizedDescription
            return 0
        }
        let found = results.filter { !$0.result.coins.isEmpty }.count
        guard manager.currentWallet?.publicAddress == account else { return found }
        // what Discover finds was there already: known from now on, never announced as received
        rememberSeen(results.flatMap { $0.result.coins }, account: account, token: token)
        // the furthest address holding some goes on the list, and every slot before it
        if let furthest = results.filter({ !$0.result.coins.isEmpty }).compactMap(\.spendingIndex).max(),
           furthest > manager.maxSpendingAddressIndex {
            await revealFreshReceiveAddress(furthest)
        }
        apply(results, for: token)
        lastError = nil
        lastRefreshed = Date()
        return found
    }

    /// Every address together.
    func balance(of token: WalletToken) -> UInt64? {
        allHoldings(of: token).map { $0.reduce(0) { $0 + $1.units } }
    }

    // MARK: History (kept on this phone)

    /// Trestly's API keeps no history and a token coin never sits at your own address, so the
    /// history is what this phone saw: its sends and Combine Coins (`noteSent`), and kUSDT received
    /// from others (`announceNewCoins`), newest first, per account and token, 300 at most. What
    /// happened before, or in another app on the same words, isn't in it.
    private static let activityCap = 300
    private var activityAccount: String?

    private func activityKey(account: String, token: WalletToken) -> String { "token_activity_\(token.id)_\(account)" }

    /// The account's saved history, read once per account (never from a view's body).
    private func loadActivityIfNeeded(account: String) {
        guard activityAccount != account else { return }
        activityAccount = account
        var loaded: [String: [TokenActivity]] = [:]
        for token in tokens {
            if let data = UserDefaults.standard.data(forKey: activityKey(account: account, token: token)),
               let rows = try? JSONDecoder().decode([TokenActivity].self, from: data) {
                loaded[token.id] = rows
            }
        }
        activity = loaded
    }

    private func record(_ row: TokenActivity, token: WalletToken, account: String) {
        loadActivityIfNeeded(account: account)
        var rows = activity[token.id] ?? []
        rows.removeAll { $0.id == row.id }
        rows.insert(row, at: 0)
        rows.sort { $0.date > $1.date }
        if rows.count > Self.activityCap { rows.removeLast(rows.count - Self.activityCap) }
        activity[token.id] = rows
        if let data = try? JSONEncoder().encode(rows) {
            UserDefaults.standard.set(data, forKey: activityKey(account: account, token: token))
        }
    }

    func activity(of token: WalletToken) -> [TokenActivity] {
        Self.isSampleData ? sample().activity : (activity[token.id] ?? [])
    }

    /// One address's activity: its page's history.
    func activity(of token: WalletToken, at holding: TokenHolding) -> [TokenActivity] {
        activity(of: token).filter { $0.holdingID == holding.id }
    }

    private func allHoldings(of token: WalletToken) -> [TokenHolding]? {
        Self.isSampleData ? sample().holdings : holdings[token.id]
    }

    /// KAS held with the token's coins (1.5 KAS each for kUSDT), returned to you as they're merged
    /// or sent.
    func kasHeld(by token: WalletToken) -> UInt64 {
        UInt64(holdings(of: token).reduce(0) { $0 + $1.coins }) * token.kasPerCoinSompi
    }

    /// "Chatting Address", "Address #3", or "2 Addresses".
    func heldOnText(_ token: WalletToken) -> String {
        let list = holdings(of: token)
        if list.count == 1 { return list[0].label }
        return String(format: AppLocalization.string("%d Addresses"), list.count)
    }

    /// A brand-new regular address to receive on: the next legacy slot, never revealed, funded or
    /// handed out. Derived only; `revealFreshReceiveAddress` puts it on the list once it's copied
    /// or shared.
    func freshReceiveAddress() -> (index: Int, address: String)? {
        let manager = WalletManager.shared
        // past every revealed slot, and never one already holding a token (it isn't fresh)
        let taken = Set(tokens.flatMap { holdings(of: $0) }.compactMap(\.spendingIndex))
        var index = manager.maxSpendingAddressIndex + 1
        while taken.contains(index) { index += 1 }
        guard let address = manager.spendingAddress(at: index) else { return nil }
        return (index, address)
    }

    /// Generate New Address (kUSDT Actions): the next unused regular address, revealed (so it's on
    /// Manage Addresses' list and watched) and checked on in Manage kUSDT's list, though it holds
    /// nothing yet. Answers its number ("#5"), or nil if no address could be derived.
    func generateFreshAddress(for token: WalletToken) async -> Int? {
        guard let fresh = freshReceiveAddress() else { return nil }
        await revealFreshReceiveAddress(fresh.index)
        var shown = shownEmptyIndices(of: token)
        shown.insert(fresh.index)
        setShownEmptyIndices(shown, of: token)
        return WalletManager.addressNumber(forIndex: fresh.index)
    }

    /// The fresh receive address goes on Manage Addresses' list (and is watched) once it's handed out.
    func revealFreshReceiveAddress(_ index: Int) async {
        let manager = WalletManager.shared
        // up to that slot (a fresh address can skip one already holding a token)
        while index > manager.maxSpendingAddressIndex {
            let before = manager.maxSpendingAddressIndex
            await manager.generateNextSpendingAddress()
            if manager.maxSpendingAddressIndex <= before { break }
        }
    }

    /// The sample for the signed-in account (its own addresses), kept per account. Not published:
    /// screens read it while they draw.
    private var sampleCache: (account: String, holdings: [TokenHolding], activity: [TokenActivity])?

    private func sample() -> (holdings: [TokenHolding], activity: [TokenActivity]) {
        let chatting = WalletManager.shared.currentWallet?.publicAddress ?? ""
        if let sampleCache, sampleCache.account == chatting { return (sampleCache.holdings, sampleCache.activity) }
        let now = Date()
        let holdings = [
            TokenHolding(spendingIndex: nil, address: chatting, units: 25_500_000, coins: 1),
            TokenHolding(spendingIndex: 2, address: WalletManager.shared.spendingAddress(at: 2) ?? "", units: 100_000_000, coins: 1),
        ]
        let activity = [
            TokenActivity(kind: .received, units: 25_000_000, counterparty: "alice.kachat", date: now.addingTimeInterval(-300), pending: true, holdingID: "chatting"),
            TokenActivity(kind: .sent, units: 19_500_000, counterparty: "kaspa:qpz8x4rm7gk0f3l5w2n9c6vht8ajd3e5u7y2s4q6r8t0", date: now.addingTimeInterval(-86_400 * 2), holdingID: "chatting"),
            TokenActivity(kind: .swapped, units: 20_000_000, counterparty: "KasPool", date: now.addingTimeInterval(-86_400 * 5), holdingID: "chatting"),
            TokenActivity(kind: .bridged, units: 100_000_000, counterparty: "Ethereum", date: now.addingTimeInterval(-86_400 * 9), holdingID: "s2"),
        ]
        sampleCache = (chatting, holdings, activity)
        return (holdings, activity)
    }
}

// MARK: - Shared pieces

/// A token's round icon. A dollar token bridged from USDT shows the USDT mark (the white "T" with
/// its ring, on USDT green), drawn here rather than shipped as an image, with a small Kaspa "K" at
/// the corner: it's the bridged token on Kaspa, not USDT itself.
struct TokenIcon: View {
    let token: WalletToken
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(Self.green)
            if token.isDollarStable {
                USDTMark()
                    .fill(Color.white, style: FillStyle(eoFill: false))
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "circle.hexagongrid")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            // the small Kaspa mark: it lives on Kaspa L1
            Text(verbatim: "K")
                .font(.system(size: size * 0.26, weight: .heavy, design: .rounded))
                .foregroundColor(.black)
                .frame(width: size * 0.38, height: size * 0.38)
                .background(Circle().fill(Color.accentColor))
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
                .offset(x: size * 0.06, y: size * 0.06)
        }
        .accessibilityHidden(true)
    }

    /// USDT green.
    static let green = Color(red: 0x26 / 255, green: 0xA1 / 255, blue: 0x7B / 255)
}

/// The USDT mark in a square: the T's bar, its stem, and the flat ring across the stem, in the
/// proportions of the published logo.
private struct USDTMark: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        // the bar
        p.addRect(CGRect(x: rect.minX + w * 0.23, y: rect.minY + h * 0.24, width: w * 0.54, height: h * 0.13))
        // the stem, through the ring and below it
        p.addRect(CGRect(x: rect.minX + w * 0.425, y: rect.minY + h * 0.37, width: w * 0.15, height: h * 0.42))
        // the ring: a flat ellipse round the stem, drawn as a band
        let outer = CGRect(x: rect.minX + w * 0.17, y: rect.minY + h * 0.415, width: w * 0.66, height: h * 0.17)
        let band = w * 0.05
        p.addPath(Path(ellipseIn: outer).strokedPath(StrokeStyle(lineWidth: band)))
        return p
    }
}

/// "Sample Data": said on every token screen while `TokenWallet.isSampleData`.
struct TokenSampleBadge: View {
    var body: some View {
        if TokenWallet.isSampleData {
            Text("Sample Data")
                .font(.caption2.weight(.bold))
                .foregroundColor(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.orange.opacity(0.15)))
        }
    }
}
