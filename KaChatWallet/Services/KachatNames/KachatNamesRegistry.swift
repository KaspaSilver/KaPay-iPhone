import Foundation
import UIKit
import UserNotifications

/// The `.kachat` registry for the screens: lookups, an owner's names, listings, lapsed names,
/// offers, history and identities, from one of two sources -
///
/// - **the names indexer** (KACHAT_NAMES_INDEXER.md Part D) at `AppSettings.indexerURL`, used when
///   that field is set and `GET /names/status` answers 200 for this manifest's registry id;
/// - **the chain walker** otherwise: the registry's live UTXO set (gaps and names, plus the offers
///   this device made) kept from the manifest's genesis gap forward. A refresh asks a node which
///   tracked UTXOs are still unspent, finds each spent one's spending transaction through the
///   Kaspa REST API (`GET /addresses/{p2sh}/full-transactions`), decodes the spend like the
///   indexer does (B3), verifies every new state against its output script and moves on. Cached
///   per network in Application Support.
///
/// Records from either source are only read here; every action re-reads its UTXOs from a node
/// (`KachatNamesService.liveRegistryUtxo`) before it builds anything. Testnet-10 only.
@MainActor
final class KachatNamesRegistry: ObservableObject {
    static let shared = KachatNamesRegistry()

    enum Source: Equatable {
        case indexer(String)
        case chain

        var isIndexer: Bool { if case .indexer = self { return true } else { return false } }
    }

    /// The address profile this wallet last wrote (the walker cannot read anyone's profile).
    struct OwnProfile: Codable, Equatable {
        var address: String
        var profile: KachatNames.Profile
        var txId: String
        var at: Int64
    }

    @Published private(set) var source: Source?
    @Published private(set) var chainState: KachatNames.RegistryState?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var refreshedAt: Date?
    /// Bumped whenever registry data may have changed, so screens reload.
    @Published private(set) var revision = 0
    /// When `refresh` last bumped `revision` (see `refresh(announce:)`).
    private var revisionBumpedAt = Date.distantPast

    private var cacheNetwork: String?
    private var ownProfiles: [String: OwnProfile] = [:]
    /// Addresses with no saved own-profile file. `ownProfile(for:)` runs for every name and
    /// avatar drawn - nearly always someone else's address - and each miss was a failing file
    /// read (plus a directory create and a hash) on the main thread, on every redraw.
    private var ownProfileMisses: Set<String> = []

    /// `.kachat` identities by lowercased address, for the app's display rules (names, avatars,
    /// banners, bios everywhere - see `cachedIdentity(for:)`). Kept on disk too
    /// (`KachatProfileCache`), so people's avatars and bios show at once after a launch while a
    /// fresh copy is fetched; Settings > Storage > Cache > Profiles clears it.
    private struct CachedIdentity: Codable {
        var identity: KachatNames.Identity
        var revision: Int
        var at: Date
    }
    /// Not `@Published`: a re-check that finds the same identity only stamps it, and stamping
    /// must not redraw every avatar and name on screen. `objectWillChange` is sent by hand when
    /// an identity really changes.
    private var identities: [String: CachedIdentity] = KachatNamesRegistry.loadIdentities()
    /// One disk write for a burst of identity changes (a screen full of avatars landing at once).
    private var identitiesPersistScheduled = false
    private var identityLookups: Set<String> = []
    /// When an address's lookup last failed: it isn't asked again for five minutes, so a view
    /// body that reads `cachedIdentity` can't turn an unreachable indexer into a request loop.
    private var identityMisses: [String: Date] = [:]
    /// Set when the indexer said it doesn't serve profiles (503) - see `profileOnlyIdentity`.
    private var profilesUnavailableUntil: Date?
    /// The walk under way: a refresh and the standby walk share it rather than racing.
    private var walkTask: Task<Bool, Error>?
    /// When the chain copy was last brought up to date while the indexer was in use.
    private var standbyWalkedAt: Date?
    /// When each address's profile was last looked for on the chain (`chainProfile`).
    private var chainProfileCheckedAt: [String: Date] = [:]
    /// Failed indexer requests in a row, and when the last one was (`indexerOutageConfirmed`).
    private var indexerFailuresInARow = 0
    private var lastIndexerFailureAt = Date.distantPast
    /// After a failover the indexer isn't asked again until this time, and each failover in a row
    /// doubles the wait: an indexer whose status page works while its data pages fail would
    /// otherwise be returned to at once and fail over again, with nothing in between.
    private var indexerRetryAfter: Date?
    private var failoversInARow = 0
    /// When a walk last reached the live UTXOs (`answersAreCurrent`).
    private var chainReachedTipAt: Date?
    /// The network the walk under way is for.
    private var walkTaskNetwork: String?
    /// Offers made while a walk runs: the walk's result is written over the copy, so they're
    /// added to it again at the end.
    private var offersTrackedDuringWalk: [KachatNames.OfferInfo] = []
    /// Chain profile lookups under way (`chainProfile`): each is up to two large REST pages.
    private var chainProfileLookups = 0

    private init() {}

    private var service: KachatNamesService { KachatNamesService.shared }

    // MARK: - Setup

    /// The verified manifest, with the source picked and the walker's cache loaded.
    @discardableResult
    func prepare(forceSourceCheck: Bool = false) async throws -> KachatNames.Manifest {
        let m = try await service.loadManifest()
        // a source picked on the other network (its indexer) is never this one's
        if preparedNetwork != m.network {
            source = nil
            chainState = nil
            cacheNetwork = nil
            standbyWalkedAt = nil
            chainReachedTipAt = nil
            preparedNetwork = m.network
        }
        if source == nil || forceSourceCheck {
            let chosen = await chooseSource(m)
            if let was = source, was != chosen {
                AppLog.log("[KachatNames] registry source: %@", chosen == .chain ? "the chain (the indexer is behind or elsewhere)" : "the indexer")
            }
            source = chosen
        }
        if source == .chain { loadChainCopyIfNeeded(m) }
        return m
    }

    private func loadChainCopyIfNeeded(_ m: KachatNames.Manifest) {
        guard chainState == nil || cacheNetwork != m.network else { return }
        chainState = Self.loadCache(m) ?? .atGenesis(m)
        cacheNetwork = m.network
    }

    /// The network `prepare` last ran for.
    private var preparedNetwork: String?

    /// Forget everything in memory (network switch, logout).
    func reset() {
        preparedNetwork = nil
        source = nil
        chainState = nil
        cacheNetwork = nil
        standbyWalkedAt = nil
        chainReachedTipAt = nil
        chainProfileCheckedAt = [:]
        ownProfiles = [:]
        ownProfileMisses = []
        lastError = nil
        refreshedAt = nil
        revision += 1
    }

    var graceMs: Int64 { service.manifest?.params.graceMs ?? 864_000_000 }

    /// An indexer further behind the network than this (DAA scores, about a minute) isn't used:
    /// its names would be stale - a name just claimed or sold missing, a registration waiting on
    /// it - so the app walks the chain itself until the indexer catches up (its node can lag on
    /// slow hardware).
    static let maxIndexerLagDaa: UInt64 = 600

    private func chooseSource(_ m: KachatNames.Manifest) async -> Source {
        guard let base = Self.indexerBase() else { return .chain }
        if let until = indexerRetryAfter, Date() < until { return .chain }
        let status: KachatNames.IndexerAPI.StatusJSON
        do {
            status = try await Self.get(base, "/names/status")
        } catch {
            // one missed status check doesn't take a working indexer out of use
            if case .indexer = source, Self.indexerIsDown(error), !indexerOutageConfirmed() { return .indexer(base) }
            return .chain
        }
        guard status.registryCovenantId?.lowercased() == KachatNames.hex(m.registryCovenantId),
              status.synced != false else {
            return .chain
        }
        // Without a network position to compare with, the indexer's own "synced" is trusted.
        if let indexed = status.indexedDaa, let dag = try? await NodePoolService.shared.currentDagPoint(),
           dag.virtualDaaScore > indexed + Self.maxIndexerLagDaa {
            return .chain
        }
        return .indexer(base)
    }

    static func indexerBase() -> String? {
        let raw = AppSettings.load().indexerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    // MARK: - Refresh

    /// Walks the chain forward (no indexer) or just marks fresh data (indexer). Safe to call often.
    /// Every refresh re-checks the source, so an indexer that fell behind is dropped and one that
    /// caught up is used again.
    ///
    /// `announce: false` (the automatic `refreshIfStale`) bumps `revision` - which reloads every
    /// screen keyed on it and re-checks identities - only when something may have changed: the
    /// walk applied a transaction, the source changed, the last refresh had failed, or the last
    /// bump is five minutes old (an indexer can't say whether anything changed). Pull to refresh
    /// and read-your-writes always announce.
    func refresh(announce: Bool = true) async {
        guard KachatNamesService.isLaunched else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let previousError = lastError
        let previousSource = source
        do {
            let m = try await prepare(forceSourceCheck: true)
            var walkedChanges = false
            if source == .chain {
                walkedChanges = try await walkShared(m)
            } else {
                walkStandbyCopyIfDue(m)
            }
            lastError = nil
            refreshedAt = Date()
            let quiet = !announce && !walkedChanges && source == previousSource && previousError == nil
                && Date().timeIntervalSince(revisionBumpedAt) < 300
            if !quiet {
                revision += 1
                revisionBumpedAt = Date()
            }
            // what changed for this wallet's names and offers, into the Profile bell
            Task { await KachatNamesNotifier.shared.check() }
        } catch {
            let message = error.localizedDescription
            lastError = message
            // A failed refresh counts as an attempt too: `refreshIfStale` waits `maxAge` before
            // the next one, and screens that reload on `revision` (and refresh from there) are
            // only nudged when the error changed - a refusal can't turn into a refresh loop.
            refreshedAt = Date()
            if message != previousError {
                if !KachatNamesService.isRegistryUpgrading(error) {
                    AppLog.log("[KachatNames] registry refresh failed: %@", message)
                }
                revision += 1
            }
        }
    }

    /// Read-your-writes after this app's own transaction: refreshes until the registry shows it -
    /// an indexer that has indexed up to `daa` (the block it landed in), or a chain walk that has
    /// applied it - so every screen reloading on `revision` (Your Domains, the marketplace, the
    /// name) shows the change without being opened again. Gives up after 45 s.
    func refreshUntilIncludes(txId: String, daa: UInt64?) async {
        let deadline = Date().addingTimeInterval(45)
        repeat {
            await refresh()
            if await includes(txId: txId, daa: daa) { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        } while Date() < deadline
    }

    private func includes(txId: String, daa: UInt64?) async -> Bool {
        switch source {
        case .indexer(let base):
            guard let daa else { return true }
            guard let status: KachatNames.IndexerAPI.StatusJSON = try? await Self.get(base, "/names/status") else { return false }
            return (status.indexedDaa ?? 0) >= daa
        default:
            let id = txId.lowercased()
            return chainState?.applied.contains { $0.lowercased() == id } ?? false
        }
    }

    /// `refresh()` unless the last one is younger than `maxAge` seconds (lookups from typed names).
    func refreshIfStale(maxAge: TimeInterval = 60) async {
        if let at = refreshedAt, Date().timeIntervalSince(at) < maxAge { return }
        await refresh(announce: false)
    }

    /// One walk at a time: whoever comes while one runs waits for it. A walk for the network
    /// just switched away from is no answer for this one, so it is waited out, then this one runs.
    private func walkShared(_ m: KachatNames.Manifest) async throws -> Bool {
        if let walkTask {
            if walkTaskNetwork == m.network { return try await walkTask.value }
            _ = try? await walkTask.value
        }
        let task = Task { @MainActor in try await self.walk(m) }
        walkTask = task
        walkTaskNetwork = m.network
        defer { walkTask = nil }
        return try await task.value
    }

    /// While the indexer answers, the chain copy is still kept up to date now and then, so the
    /// moment it stops answering the names are already here instead of a walk from the genesis
    /// away. Nothing is read from this copy until then.
    private func walkStandbyCopyIfDue(_ m: KachatNames.Manifest) {
        let expensive = NetworkEpochMonitor.shared.isExpensivePath
        let interval: TimeInterval = expensive ? 7200 : 1800
        loadChainCopyIfNeeded(m)
        // the saved copy says how old it is: a launch isn't a reason to walk again
        if standbyWalkedAt == nil, let ms = chainState?.verifiedAt {
            standbyWalkedAt = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        }
        if let at = standbyWalkedAt, Date().timeIntervalSince(at) < interval { return }
        // reading the whole history for the first time waits for an unmetered connection
        if expensive, chainState?.reachedTip != true { return }
        guard walkTask == nil else { return }
        standbyWalkedAt = Date()
        Task { @MainActor [weak self] in
            do {
                _ = try await self?.walkShared(m)
            } catch {
                AppLog.log("[KachatNames] standby walk of the registry failed: %@", error.localizedDescription)
            }
        }
    }

    /// True when the walk applied a transaction (or started over from the genesis).
    @discardableResult
    private func walk(_ m: KachatNames.Manifest) async throws -> Bool {
        var state = chainState ?? .atGenesis(m)
        var report = try await walkToTip(&state, m)
        // An inconsistent result (a stale UTXO, or gaps and names that don't tile the key
        // space) is walked again once from the genesis rather than kept.
        if report.stale || (try? state.checkInvariants()) == nil {
            AppLog.log("[KachatNames] the walked registry is inconsistent; walking again from the genesis")
            // not to be answered from if the walk below fails
            if var bad = chainState {
                bad.reachedTip = nil
                chainState = bad
                Self.saveCache(bad)
            }
            chainReachedTipAt = nil
            state = .atGenesis(m)
            report = try await walkToTip(&state, m)
            try state.checkInvariants()
        }
        if report.reachedTip { state.reachedTip = true }
        state.verifiedAt = KachatNames.nowMs()
        if !report.applied.isEmpty {
            AppLog.log("[KachatNames] walked %d registry transaction(s) in %d round(s)", report.applied.count, report.rounds)
        }
        if !report.unresolved.isEmpty {
            AppLog.log("[KachatNames] %d spent registry UTXO(s) wait for the REST API to index their spend", report.unresolved.count)
        }
        // a network switch while this walked: the answer is the other network's
        guard preparedNetwork == m.network else { return false }
        // a copy that has just become readable is a change too: screens are waiting on it
        let changed = !report.applied.isEmpty || chainState == nil
            || (chainState?.reachedTip != true && state.reachedTip == true)
        if report.reachedTip { chainReachedTipAt = Date() }
        for offer in offersTrackedDuringWalk { state.trackOffer(offer, at: KachatNames.nowMs()) }
        offersTrackedDuringWalk = []
        chainState = state
        Self.saveCache(state)
        return changed
    }

    /// A long history takes more than one walk's rounds: keeps going, saving what it has between
    /// them, so a walk that fails later doesn't lose the part already read.
    private func walkToTip(_ state: inout KachatNames.RegistryState, _ m: KachatNames.Manifest) async throws -> KachatNames.RegistryState.WalkReport {
        var total = try await walkOnce(&state, m)
        var passes = 1
        while total.ranOutOfRounds, !total.stale, passes < Self.maxWalkPasses, preparedNetwork == m.network {
            chainState = state
            Self.saveCache(state)
            let next = try await walkOnce(&state, m)
            total.rounds += next.rounds
            total.applied += next.applied
            total.events += next.events
            total.unresolved = next.unresolved
            total.stale = next.stale
            total.reachedTip = next.reachedTip
            total.ranOutOfRounds = next.ranOutOfRounds
            passes += 1
        }
        return total
    }

    private static let maxWalkPasses = 20

    private func walkOnce(_ state: inout KachatNames.RegistryState, _ m: KachatNames.Manifest) async throws -> KachatNames.RegistryState.WalkReport {
        // the registry's gaps and names (registry v4 has no price record)
        let covenantIds: Set<String> = [KachatNames.hex(m.registryCovenantId)]
        return try await state.walk(
            manifest: m,
            address: { KachatNamesService.p2shAddress(script: $0) },
            live: { addresses in
                var out = Set<String>()
                var start = 0
                while start < addresses.count {
                    let chunk = Array(addresses[start..<min(start + 50, addresses.count)])
                    for u in try await NodePoolService.shared.getUtxosByAddresses(chunk) {
                        // A node reports the covenant id; the REST fallback cannot (nil). A UTXO
                        // carrying another id is not the registry's.
                        if let c = u.covenantId, !c.isEmpty, !covenantIds.contains(c.lowercased()) { continue }
                        out.insert("\(u.outpoint.transactionId.lowercased()):\(u.outpoint.index)")
                    }
                    start += 50
                }
                return out
            },
            transactions: { address, wanted in try await Self.restTransactions(address: address, spending: wanted) }
        )
    }

    /// Accepted transactions touching `address`, newest first (kaspa-rest-server), paged until
    /// every outpoint in `spending` has its spender, the history ends, or `restMaxPages` pages.
    /// One page is not enough: 50 dust payments to a registry address would hide the spend that
    /// moved it on, and the names behind it would never resolve (IOS-065).
    static func restTransactions(address: String, spending wanted: Set<String>) async throws -> [KachatNames.TxView] {
        let base = AppSettings.load().kaspaRestAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        var out: [KachatNames.TxView] = []
        var missing = wanted
        for page in 0..<restMaxPages {
            guard let url = URL(string: "\(root)/addresses/\(address)/full-transactions?limit=\(restPageSize)&offset=\(page * restPageSize)&resolve_previous_outpoints=no") else {
                throw KachatNames.Failure("bad Kaspa REST API URL")
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw KachatNames.Failure("the Kaspa REST API answered \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(address)")
            }
            guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { break }
            let txs = try list.compactMap { try KachatNames.TxView.fromREST($0) }
            out.append(contentsOf: txs)
            for tx in txs {
                for input in tx.inputs { missing.remove("\(KachatNames.hex(input.outpoint.txid)):\(input.outpoint.index)") }
            }
            if missing.isEmpty || list.count < restPageSize { break }
        }
        return out
    }

    static let restPageSize = 50
    /// 1,000 transactions per address: past the newest dust anyone would pay to send
    static let restMaxPages = 20

    /// Whether the REST API has seen `txId` accepted.
    static func isAccepted(txId: String) async -> Bool {
        let base = AppSettings.load().kaspaRestAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "\(base.hasSuffix("/") ? String(base.dropLast()) : base)/transactions/\(txId)?inputs=false&outputs=false&resolve_previous_outpoints=no"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (j["is_accepted"] as? Bool) == true
    }

    /// After a submit: wait (up to ~2 minutes) for the transaction to be accepted, then refresh.
    func refreshAfter(txId: String) {
        Task { @MainActor in
            for attempt in 0..<40 {
                try? await Task.sleep(nanoseconds: UInt64(attempt < 5 ? 2 : 3) * 1_000_000_000)
                if await Self.isAccepted(txId: txId) { break }
            }
            await refresh()
        }
    }

    // MARK: - Reads

    /// Whether a registry answer right now reflects the chain as it stands. The indexer's does (it
    /// was checked to be keeping up); the chain copy's only just after a walk reached the live
    /// UTXOs. Anything that spends or withdraws on a registry answer asks this first: a copy
    /// minutes old can say a name is free that has since been taken.
    var answersAreCurrent: Bool {
        guard source == .chain else { return true }
        guard let at = chainReachedTipAt else { return false }
        return Date().timeIntervalSince(at) < 120
    }

    /// Any registry answer is only a claim about the past: an indexer's can be false, and the
    /// chain copy can be minutes or hours old. Before a payment trusts one, the chain has to hold
    /// the name record it describes, unspent, right now: the script commits to the name and its
    /// owner, and carries the registry's covenant id, so a name can't point at another address or
    /// at an owner who has since sold it. Throws if it doesn't.
    func confirmOnChain(_ n: KachatNames.NameInfo) async throws {
        guard let fields = n.fields else { throw KachatNames.Failure("the indexer's record can't be checked") }
        let m = try await service.loadManifest()
        _ = try await service.liveRegistryUtxo(script: m.name.script(fields.encoded), outpoint: n.outpoint)
    }

    func lookup(_ raw: String) async throws -> KachatNames.Lookup {
        try await prepare()
        let name = KachatNames.Codec.normalize(raw)
        try KachatNames.Codec.validate(name)
        if case .indexer(let base) = source,
           let j = try await fromIndexer(KachatNames.IndexerAPI.NameJSON.self, base, "/names/\(name)") {
            if let info = j.info(keyOf: Self.keyOf) { return .registered(info) }
            return .free(name: name, gap: j.gap?.info)
        }
        let st = try readChainState()
        if let n = st.name(name) { return .registered(KachatNames.RegistryState.info(n)) }
        return .free(name: name, gap: st.gap(containing: KachatNames.Codec.key(name)).map(KachatNames.RegistryState.info))
    }

    /// The indexer's answer, or nil once it has stopped answering (`indexerOutageConfirmed`): the
    /// registry then moves to the chain and the caller reads it from there. A single failure is
    /// thrown for the caller's own retry, and a 404 and the like are answers, thrown as they
    /// always were.
    private func fromIndexer<T: Decodable>(_ type: T.Type, _ base: String, _ path: String) async throws -> T? {
        do {
            let answer: T = try await Self.get(base, path)
            indexerFailuresInARow = 0
            failoversInARow = 0
            indexerRetryAfter = nil
            return answer
        } catch {
            guard Self.indexerIsDown(error) else {
                indexerFailuresInARow = 0
                throw error
            }
            guard indexerOutageConfirmed() else { throw error }
            failOverToChain(after: error)
            return nil
        }
    }

    /// Counts a failed request; true from the third in a row within two minutes, so one timeout
    /// never moves the registry off a working indexer. Failures within 5 seconds count once: one
    /// Wi-Fi to cellular handoff fails every request in flight together.
    private func indexerOutageConfirmed() -> Bool {
        let now = Date()
        let since = now.timeIntervalSince(lastIndexerFailureAt)
        if since > 120 { indexerFailuresInARow = 0 }
        if since >= 5 {
            lastIndexerFailureAt = now
            indexerFailuresInARow += 1
        }
        return indexerFailuresInARow >= 3
    }

    private nonisolated static func indexerIsDown(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let failure = error as? KachatNames.Failure {
            let prefix = "the names indexer answered "
            guard failure.message.hasPrefix(prefix), let code = Int(failure.message.dropFirst(prefix.count)) else { return false }
            return code == 0 || code == 429 || code >= 500
        }
        if let urlError = error as? URLError { return urlError.code != .cancelled }
        // a body it couldn't decode is still the indexer answering
        return false
    }

    /// The indexer stopped answering: the names are on the chain, so read them there from now on.
    /// The next refresh (once a minute while on the chain) goes back to it when it recovers.
    private func failOverToChain(after error: Error) {
        guard case .indexer = source, let m = service.manifest else { return }
        AppLog.log("[KachatNames] the indexer didn't answer (%@): reading the registry from the chain", error.localizedDescription)
        source = .chain
        indexerFailuresInARow = 0
        indexerRetryAfter = Date().addingTimeInterval(min(120 * pow(2, Double(failoversInARow)), 900))
        failoversInARow += 1
        revision += 1
        revisionBumpedAt = Date()
        loadChainCopyIfNeeded(m)
        Task { @MainActor [weak self] in await self?.refresh(announce: false) }
    }

    /// The chain copy, only once it holds the whole registry. Before that "not in here" says
    /// nothing, so a read fails (and whatever is saved keeps showing) rather than answering
    /// that a name is free or an address has none.
    /// Reading it also keeps it current, and goes back to the indexer once that recovers: KaPay
    /// has no timer for this, so the reads drive it (`refreshIfStale` holds it to once a minute).
    private func readChainState() throws -> KachatNames.RegistryState {
        guard let st = chainState, st.reachedTip == true else {
            Task { @MainActor [weak self] in await self?.refreshIfStale(maxAge: 30) }
            throw KachatNames.Failure("the registry is still being read from the chain")
        }
        if source == .chain {
            Task { @MainActor [weak self] in await self?.refreshIfStale(maxAge: 60) }
        }
        return st
    }

    /// Which of `addresses` hold at least one .kachat name (active or in grace - the same set
    /// Your Domains lists, `heldNames`). Drives the "Contains domain" tag on Manage Addresses and KasSigner.
    /// Empty off testnet; an address whose lookup fails just isn't tagged.
    func ownersOfNames(among addresses: [String]) async -> Set<String> {
        guard KachatNamesService.isLaunched, !addresses.isEmpty else { return [] }
        if refreshedAt == nil { await refresh() }
        var owners = Set<String>()
        for address in addresses {
            guard let key = Self.keyOf(address),
                  let owned = try? await heldNames(owner: key),
                  !owned.isEmpty else { continue }
            owners.insert(address)
        }
        return owners
    }

    /// The names an owner still holds, oldest first: active ones and expired ones in grace (still
    /// renewable). A lapsed name is no longer theirs - it's in the marketplace's Reclaimable tab.
    /// Your Domains, its count on Profile and the "Contains domain" tag all show this set.
    func heldNames(owner: Data) async throws -> [KachatNames.NameInfo] {
        let grace = graceMs
        return try await names(owner: owner, includeInactive: true).filter { $0.status(graceMs: grace) != .lapsed }
    }

    /// Keeps a `heldNames` answer true as time passes: waits until the next of `names` lapses,
    /// then hands back the ones still held, until none is left to lapse (or the task is
    /// cancelled). A lapse is just the clock running out, so no registry change announces it.
    func dropLapsed(from names: [KachatNames.NameInfo], update: ([KachatNames.NameInfo]) -> Void) async {
        var held = names
        while let next = held.map({ $0.expiresAt + graceMs }).filter({ $0 > KachatNames.nowMs() }).min() {
            let wait = UInt64(max(0, next - KachatNames.nowMs()) + 500) * 1_000_000
            try? await Task.sleep(nanoseconds: wait)
            if Task.isCancelled { return }
            let grace = graceMs
            held = held.filter { $0.status(graceMs: grace) != .lapsed }
            update(held)
        }
    }

    /// The names an owner holds, oldest first; `includeInactive` adds grace and lapsed ones.
    func names(owner: Data, includeInactive: Bool) async throws -> [KachatNames.NameInfo] {
        try await prepare()
        var answered: [KachatNames.NameInfo]?
        if case .indexer(let base) = source {
            guard let address = Self.address(of: owner) else { return [] }
            let j = try await fromIndexer(KachatNames.IndexerAPI.NamesJSON.self, base, "/names/by-owner/\(address)?includeInactive=\(includeInactive)")
            answered = j?.names.compactMap { $0.info(keyOf: Self.keyOf) }
        }
        let all: [KachatNames.NameInfo]
        if let answered {
            all = answered
        } else {
            let ownerHex = KachatNames.hex(owner)
            all = try readChainState().names.filter { $0.owner == ownerHex }.map(KachatNames.RegistryState.info)
        }
        let grace = graceMs
        return all
            .filter { includeInactive || $0.status(graceMs: grace) == .active }
            .sorted { ($0.registeredAt ?? .max, $0.name) < ($1.registeredAt ?? .max, $1.name) }
    }

    /// Active names listed for sale, most recently changed first.
    func listings() async throws -> [KachatNames.NameInfo] {
        try await prepare()
        let grace = graceMs
        if case .indexer(let base) = source,
           let j = try await fromIndexer(KachatNames.IndexerAPI.ListingsJSON.self, base, "/market/listings?sort=recent") {
            // an expired name's old listing is not for sale, whatever the indexer kept
            return j.listings.compactMap { $0.info(keyOf: Self.keyOf) }.filter { $0.status(graceMs: grace) == .active }
        }
        return try readChainState().names.map(KachatNames.RegistryState.info)
            .filter { $0.isListed && $0.status(graceMs: grace) == .active }
            .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
    }

    /// Lapsed names anyone may reclaim, oldest expiry first.
    func lapsed() async throws -> [KachatNames.NameInfo] {
        try await prepare()
        if case .indexer(let base) = source,
           let j = try await fromIndexer(KachatNames.IndexerAPI.NamesJSON.self, base, "/names/expiring") {
            return j.names.compactMap { $0.info(keyOf: Self.keyOf) }
        }
        let grace = graceMs
        return try readChainState().names.map(KachatNames.RegistryState.info)
            .filter { $0.status(graceMs: grace) == .lapsed }
            .sorted { $0.expiresAt < $1.expiresAt }
    }

    /// Names that expired and are still in their grace period (only their owner can renew them),
    /// soonest release first: each is free to claim at `expiresAt + graceMs`. The indexer serves
    /// `GET /names/grace` (kachat-indexer docs/KACHAT_NAMES_GRACE.md); an indexer without it yet
    /// is answered from this device's own chain walk when it has one.
    func inGrace() async throws -> [KachatNames.NameInfo] {
        try await prepare()
        let grace = graceMs
        var answered: [KachatNames.NameInfo]?
        if case .indexer(let base) = source {
            do {
                answered = try await fromIndexer(KachatNames.IndexerAPI.NamesJSON.self, base, "/names/grace")?
                    .names.compactMap { $0.info(keyOf: Self.keyOf) }
            } catch {
                // one failed request isn't "none in grace": the screen keeps what it shows
                if Self.indexerIsDown(error) { throw error }
                // an indexer without this endpoint yet: this device's walk, if it has read one
                answered = chainState?.reachedTip == true ? chainState?.names.map(KachatNames.RegistryState.info) ?? [] : []
            }
        }
        let all = try answered ?? readChainState().names.map(KachatNames.RegistryState.info)
        return all.filter { $0.status(graceMs: grace) == .grace }.sorted { $0.expiresAt < $1.expiresAt }
    }

    /// Open offers on a name. Without an indexer only the offers this device made are known.
    func offers(for name: String) async throws -> [KachatNames.OfferInfo] {
        try await prepare()
        if case .indexer(let base) = source,
           let j = try await fromIndexer(KachatNames.IndexerAPI.OffersJSON.self, base, "/names/\(name)/offers") {
            return j.offers.compactMap { $0.info(name: name, keyOf: Self.keyOf) }.sorted { $0.amount > $1.amount }
        }
        let key = KachatNames.hex(KachatNames.Codec.key(name))
        return try readChainState().offers.filter { $0.key == key }.map(KachatNames.RegistryState.info).sorted { $0.amount > $1.amount }
    }

    /// The offers `buyer` made that are still open.
    func myOffers(buyer: Data) async throws -> [KachatNames.OfferInfo] {
        try await prepare()
        if case .indexer(let base) = source {
            guard let address = Self.address(of: buyer) else { return [] }
            if let j = try await fromIndexer(KachatNames.IndexerAPI.OffersJSON.self, base, "/offers/by-buyer/\(address)") {
                return j.offers.compactMap { $0.info(name: nil, keyOf: Self.keyOf) }
            }
        }
        let me = KachatNames.hex(buyer)
        return try readChainState().offers.filter { $0.buyer == me }.map(KachatNames.RegistryState.info)
    }

    /// A name's history, newest first. The walker knows every registry transition it walked.
    func history(name: String) async throws -> [KachatNames.Event] {
        try await prepare()
        if case .indexer(let base) = source,
           let j = try await fromIndexer(KachatNames.IndexerAPI.EventsJSON.self, base, "/names/\(name)/history") {
            return j.events.map(\.event)
        }
        return try readChainState().events.filter { $0.name == name }.reversed()
    }

    /// Recent registry activity, newest first: every registration, renewal, extension, listing,
    /// sale, offer, transfer, release and reclaim. An indexer serves it at `GET /names/activity`;
    /// one without that endpoint yet answers only market events (`/market/activity`).
    func activity() async throws -> [KachatNames.Event] {
        try await prepare()
        if case .indexer(let base) = source {
            if let all: KachatNames.IndexerAPI.EventsJSON = try? await Self.get(base, "/names/activity") {
                return all.events.map(\.event)
            }
            if let j = try await fromIndexer(KachatNames.IndexerAPI.EventsJSON.self, base, "/market/activity") {
                return j.events.map(\.event)
            }
        }
        return Array(try readChainState().events.reversed().prefix(200))
    }


    /// A count or amount over the last 24 hours, the last 7 days and all time.
    struct Totals: Equatable {
        var last24h: UInt64
        var last7d: UInt64
        var total: UInt64
    }

    /// How many .kachat transactions there were and what they paid, across the registry - for
    /// the market's Activity page. An indexer reports both (`GET /stats/names`:
    /// fees = what each transaction paid miners, the registry's price included, since that is
    /// how the price is paid). Read from the chain instead, the walker counts its events and
    /// prices each registration, extension and renewal at the registry's fixed prices.
    /// `fees` is nil where they can't be worked out (an indexer too old to record them).
    func activityTotals() async throws -> (transactions: Totals, fees: Totals?) {
        let m = try await prepare()
        if case .indexer(let base) = source {
            // `/names/activity/stats` first: a proxy may send /stats/* to a server without the
            // names module (mainnet today). Neither answering, the activity feed is counted.
            var stats: KachatNames.IndexerAPI.StatsJSON?
            if let j: KachatNames.IndexerAPI.StatsJSON = try? await Self.get(base, "/names/activity/stats") {
                stats = j
            } else if let j: KachatNames.IndexerAPI.StatsJSON = try? await Self.get(base, "/stats/names") {
                stats = j
            } else {
                do {
                    return Self.totals(of: try await allIndexerEvents(base), params: m.params)
                } catch {
                    guard Self.indexerIsDown(error), indexerOutageConfirmed() else { throw error }
                    failOverToChain(after: error)
                }
            }
            if let j = stats {
                let fees = j.fees.flatMap { f -> Totals? in
                    guard let t = UInt64(f.total), let d = UInt64(f.last24h), let w = UInt64(f.last7d) else { return nil }
                    return Totals(last24h: d, last7d: w, total: t)
                }
                if let t = j.transactions {
                    return (Totals(last24h: t.last24h, last7d: t.last7d, total: t.total), fees)
                }
                // an indexer from before `transactions`: the per-kind figures, added up
                let kinds = (j.activity ?? [:]).values
                return (Totals(last24h: kinds.reduce(0) { $0 + $1.last24h },
                               last7d: kinds.reduce(0) { $0 + $1.last7d },
                               total: kinds.reduce(0) { $0 + $1.total }), fees)
            }
        }
        return Self.totals(of: try readChainState().events, params: m.params)
    }

    /// Every registry event an indexer's `/names/activity` holds, newest first, page by page
    /// (at most 50 pages of 200).
    private func allIndexerEvents(_ base: String) async throws -> [KachatNames.Event] {
        var events: [KachatNames.Event] = []
        var cursor: String?
        for _ in 0..<50 {
            var path = "/names/activity?length=200"
            if let cursor { path += "&cursor=\(cursor)" }
            let page: KachatNames.IndexerAPI.EventsJSON = try await Self.get(base, path)
            events += page.events.map(\.event)
            guard let next = page.next, !next.isEmpty, !page.events.isEmpty else { break }
            cursor = next
        }
        return events
    }

    /// Counts and prices registry events (`activityTotals` without an indexer's figures), one per
    /// transaction: registrations, extensions and renewals at the registry's fixed prices.
    static func totals(of events: [KachatNames.Event], params: KachatNames.Params,
                       nowMs: Int64 = KachatNames.nowMs()) -> (transactions: Totals, fees: Totals?) {
        let d1 = nowMs - 86_400_000
        let d7 = nowMs - 7 * 86_400_000
        var at: [String: Int64] = [:]
        var paid: [String: UInt64] = [:]
        for e in events {
            at[e.txId] = max(at[e.txId] ?? 0, e.at ?? 0)
            guard let name = e.name, let years = e.years, years > 0 else { continue }
            let length = name.utf8.count
            switch e.op {
            case "register":
                paid[e.txId, default: 0] += params.registerCost(forLength: length, years: years)
            case "extend", "renew":
                paid[e.txId, default: 0] += params.renewPrice(forLength: length) * UInt64(years)
            default:
                break
            }
        }
        var transactions = Totals(last24h: 0, last7d: 0, total: 0)
        var fees = Totals(last24h: 0, last7d: 0, total: 0)
        for (tx, time) in at {
            let fee = paid[tx] ?? 0
            transactions.total += 1
            fees.total += fee
            if time > d7 { transactions.last7d += 1; fees.last7d += fee }
            if time > d1 { transactions.last24h += 1; fees.last24h += fee }
        }
        return (transactions, fees)
    }

    /// The fixed prices (registry v4, baked into the pinned templates): sompi for a name's first
    /// period, and for every further one, by length 1, 2, 3, 4, 5+ bytes. nil until a manifest loads.
    var registerPrices: [UInt64]? { service.manifest?.params.registerPrices }
    var renewPrices: [UInt64]? { service.manifest?.params.renewPrices }

    /// The free gap a lapsed name's reclaim reopens - the two gaps around it, merged: where a
    /// claim of it registers. The claim sheet prices with it; the registration driver reclaims
    /// the old record first and then looks the gap up again.
    func claimGap(for n: KachatNames.NameInfo) async throws -> KachatNames.GapInfo {
        let gaps = try await exitGaps(for: n)
        return KachatNames.GapInfo(lo: gaps.below.lo, hi: gaps.above.hi, outpoint: gaps.below.outpoint)
    }

    /// `lookup` as the app shows a name to someone who wants it: a lapsed name is free to claim
    /// (claiming it frees the old record and registers it in one go - see the driver), in the
    /// gap its reclaim reopens.
    func claimLookup(_ name: String) async throws -> KachatNames.Lookup {
        let found = try await lookup(name)
        if case .registered(let n) = found, n.status(graceMs: graceMs) == .lapsed {
            return .free(name: n.name, gap: try? await claimGap(for: n))
        }
        return found
    }

    /// The two gaps around a registered name (what release and reclaim spend).
    func exitGaps(for n: KachatNames.NameInfo) async throws -> (below: KachatNames.GapInfo, above: KachatNames.GapInfo) {
        try await prepare()
        if case .indexer(let base) = source {
            guard let down = KachatNames.step(n.key, by: -1), let up = KachatNames.step(n.key, by: 1) else {
                throw KachatNames.Failure("no gaps around \(n.name)")
            }
            if let below = try await fromIndexer(KachatNames.IndexerAPI.GapJSON.self, base, "/names/gap/\(KachatNames.hex(down))"),
               let above = try await fromIndexer(KachatNames.IndexerAPI.GapJSON.self, base, "/names/gap/\(KachatNames.hex(up))") {
                guard let b = below.info, let a = above.info, b.hi == n.key, a.lo == n.key else {
                    throw KachatNames.Failure("the indexer has no gaps around \(n.name)")
                }
                return (b, a)
            }
        }
        guard let nb = try readChainState().neighbours(of: n.key) else { throw KachatNames.Failure("no gaps around \(n.name) yet - refresh") }
        return (KachatNames.RegistryState.info(nb.below), KachatNames.RegistryState.info(nb.above))
    }

    // MARK: - Identity and profiles

    /// The label and profile of an address (KACHAT_NAMES.md section 7). Without an indexer the
    /// label comes from the walked names and the profile from the address's own record on the
    /// chain (`chainProfile`); this wallet's own last write comes first.
    func identity(address: String) async throws -> KachatNames.Identity {
        let address = address.lowercased()
        // No registry on this network yet (mainnet): no names or label, only the profile.
        guard KachatNamesService.isLaunched else { return try await profileOnlyIdentity(address: address) }
        try await prepare()
        if case .indexer(let base) = source,
           let j = try await fromIndexer(KachatNames.IndexerAPI.IdentityJSON.self, base, "/identity/\(address)") {
            return j.identity
        }
        guard let key = Self.keyOf(address) else { return KachatNames.Identity(address: address, label: nil, names: [], profile: nil) }
        // held names: a name in grace still labels and resolves to its owner
        let owned = try await heldNames(owner: key)
        var profile = ownProfile(for: address)?.profile
        if profile == nil { profile = await chainProfile(address: address) }
        let label = KachatNames.label(owned: owned, primaryName: profile?.primaryName, graceMs: graceMs)
        return KachatNames.Identity(address: address, label: label, names: owned.map(\.name), profile: profile)
    }

    /// The address's profile with no indexer: its latest record on the chain, looked for at most
    /// every half hour. Not found (too far back in a busy address's history, or the REST API not
    /// answering) keeps the profile already saved, since that is no proof it was ever cleared.
    private func chainProfile(address: String) async -> KachatNames.Profile? {
        let saved = identities[address]?.identity.profile
        if let at = chainProfileCheckedAt[address], Date().timeIntervalSince(at) < Self.chainProfileRecheck { return saved }
        // a long contact list asks for many at once: the rest are asked for on a later pass
        guard chainProfileLookups < Self.maxChainProfileLookups else { return saved }
        chainProfileLookups += 1
        defer { chainProfileLookups -= 1 }
        chainProfileCheckedAt[address] = Date()
        return await Self.latestProfileRecord(address: address) ?? saved
    }

    private static let chainProfileRecheck: TimeInterval = 1800
    private static let maxChainProfileLookups = 3
    /// Two pages, newest first: profile records are rare, and this runs per person shown.
    private nonisolated static let profilePages = 2
    private nonisolated static let profilePageSize = 100

    /// The newest `kchat:1:profile:` record `address` wrote (KACHAT_NAMES.md section 7): one of
    /// its inputs is the address's and one of its outputs pays back to it, so only the key holder
    /// can write one. Whether an input is the address's is the REST API's word.
    private nonisolated static func latestProfileRecord(address: String) async -> KachatNames.Profile? {
        let base = AppSettings.load().kaspaRestAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        let marker = KachatNames.hex(Data("kchat:1:profile:".utf8))
        for page in 0..<profilePages {
            guard let url = URL(string: "\(root)/addresses/\(address)/full-transactions?limit=\(profilePageSize)&offset=\(page * profilePageSize)&resolve_previous_outpoints=light&fields=is_accepted,payload,inputs,outputs,block_time"),
                  let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
            for tx in list {
                if let accepted = tx["is_accepted"] as? Bool, !accepted { continue }
                guard let payload = (tx["payload"] as? String)?.lowercased(), payload.hasPrefix(marker),
                      ((tx["inputs"] as? [[String: Any]]) ?? []).contains(where: { ($0["previous_outpoint_address"] as? String)?.lowercased() == address }),
                      ((tx["outputs"] as? [[String: Any]]) ?? []).contains(where: { ($0["script_public_key_address"] as? String)?.lowercased() == address }),
                      let json = Data(hexString: String(payload.dropFirst(marker.count))),
                      json.count <= KachatNames.Codec.maxProfileJSONBytes,
                      let profile = try? JSONDecoder().decode(KachatNames.Profile.self, from: json),
                      profile.v == 1 else { continue }
                return profile.sanitized()
            }
            if list.count < profilePageSize { break }
        }
        return nil
    }

    /// An address's profile where the network has no registry yet (mainnet): the indexer's
    /// `GET /profiles/{address}`, falling back to the record this device last wrote for its own
    /// address. The indexer answers 503 until it follows profiles on this network
    /// (kachat-indexer docs/KACHAT_PROFILES.md); then only this wallet's own profile shows.
    private func profileOnlyIdentity(address: String) async throws -> KachatNames.Identity {
        if let own = ownProfile(for: address)?.profile {
            return KachatNames.Identity(address: address, label: nil, names: [], profile: own)
        }
        // An indexer without profiles on this network answers 503 for every address: one such
        // answer pauses all profile lookups for ten minutes instead of one request per contact.
        // With no indexer to ask, the address's own record on the chain answers (`chainProfile`).
        // Not during the 503 pause: an indexer that doesn't serve profiles here isn't an outage,
        // and every contact would then fetch two large pages of history.
        let fromChain = { [self] in
            KachatNames.Identity(address: address, label: nil, names: [], profile: await chainProfile(address: address))
        }
        guard let base = Self.indexerBase() else { return await fromChain() }
        guard (profilesUnavailableUntil ?? .distantPast) < Date() else {
            throw KachatNames.Failure("profiles are not indexed on this network yet")
        }
        do {
            let j: KachatNames.IndexerAPI.ProfileJSON = try await Self.get(base, "/profiles/\(address)")
            return KachatNames.Identity(address: address, label: nil, names: [], profile: j.profile?.sanitized())
        } catch {
            if (error as? KachatNames.Failure)?.message.hasSuffix("answered 503") == true {
                profilesUnavailableUntil = Date().addingTimeInterval(600)
                throw error
            }
            guard Self.indexerIsDown(error) else { throw error }
            return await fromChain()
        }
    }

    /// Files a fetched identity in the cache; true when it changed (the caller then tells
    /// AddressBookManager). An unchanged answer only stamps the entry fresh.
    private func storeFetchedIdentity(_ found: KachatNames.Identity, for key: String) -> Bool {
        if identities[key]?.identity != found {
            objectWillChange.send()
            identities[key] = CachedIdentity(identity: found, revision: revision, at: Date())
            persistIdentities()
            return true
        }
        identities[key]?.revision = revision
        identities[key]?.at = Date()
        return false
    }

    /// The address's `.kachat` identity as the app shows it, from a cache that fills in the
    /// background: callable from any view body (on mainnet, profile only). An answer is
    /// re-asked once the registry moved on or after five minutes, and this wallet's own saved
    /// profile always wins for its own address. When an answer lands, views that read Address
    /// Book names re-render (AddressBookManager is told).
    func cachedIdentity(for address: String) -> KachatNames.Identity? {
        guard KachatNamesService.profilesEnabled else { return nil }
        let key = address.lowercased()
        guard NetworkType(address: key) != nil, NetworkType.isOnActiveNetwork(key) else { return nil }
        let entry = identities[key]
        // Five minutes old, or older than a minute once the registry changed: every refresh
        // bumps `revision`, and re-asking for every address on screen after each one cost a
        // request per avatar and redrew the whole list as each answer came back.
        let stale = entry.map {
            let age = Date().timeIntervalSince($0.at)
            return age > 300 || ($0.revision != revision && age > 60)
        } ?? true
        // a failed lookup (the registry still loading, a network blip) is asked again after a
        // minute, not five - until then the person shows as their address
        let missedRecently = identityMisses[key].map { Date().timeIntervalSince($0) < 60 } ?? false
        if stale, !missedRecently, !identityLookups.contains(key) {
            identityLookups.insert(key)
            Task { [weak self] in
                guard let self else { return }
                let found = try? await self.identity(address: key)
                self.identityLookups.remove(key)
                guard let found else {
                    self.identityMisses[key] = Date()
                    return
                }
                self.identityMisses[key] = nil
                if self.storeFetchedIdentity(found, for: key) {
                    AddressBookManager.shared.objectWillChange.send()
                }
            }
        }
        var identity = entry?.identity
        if let own = ownProfile(for: key)?.profile {
            identity = identity ?? KachatNames.Identity(address: key, label: nil, names: [], profile: nil)
            identity?.profile = own
        }
        return identity
    }

    // MARK: Profile cache on disk

    private nonisolated static let identitiesFile = "identities.json"
    private static let identitiesKeep = 1000

    /// The identities cached on the last run. Each is marked stale (an impossible revision), so it
    /// is shown at once and re-fetched on first use.
    private nonisolated static func loadIdentities() -> [String: CachedIdentity] {
        guard let data = KachatProfileCache.read(identitiesFile),
              let stored = try? JSONDecoder().decode([String: CachedIdentity].self, from: data) else { return [:] }
        return stored.mapValues { var c = $0; c.revision = -1; return c }
    }

    private func persistIdentities() {
        guard !identitiesPersistScheduled else { return }
        identitiesPersistScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            self.identitiesPersistScheduled = false
            self.writeIdentities()
        }
    }

    private func writeIdentities() {
        var keep = identities
        if keep.count > Self.identitiesKeep {
            for (k, _) in keep.sorted(by: { $0.value.at < $1.value.at }).prefix(keep.count - Self.identitiesKeep) { keep[k] = nil }
        }
        guard let data = try? JSONEncoder().encode(keep) else { return }
        Task.detached(priority: .utility) { KachatProfileCache.write(Self.identitiesFile, data) }
    }

    /// Settings > Storage > Cache > Profiles: forgets every cached identity (on disk too). Views
    /// re-fetch them as they need them. This device's own saved profile record is not cache and
    /// stays.
    func clearProfileCache() {
        objectWillChange.send()
        identities = [:]
        identityMisses = [:]
        identityLookups = []
        KachatProfileCache.remove(Self.identitiesFile)
        revision += 1
        AddressBookManager.shared.objectWillChange.send()
    }

    /// The profile record this device last wrote for `address`.
    func ownProfile(for address: String) -> OwnProfile? {
        let address = address.lowercased()
        if let p = ownProfiles[address] { return p }
        guard !ownProfileMisses.contains(address) else { return nil }
        guard let data = Self.readFile(Self.profileFile(address), network: Self.profileNetwork(address)), let p = try? JSONDecoder().decode(OwnProfile.self, from: data) else {
            ownProfileMisses.insert(address)
            return nil
        }
        ownProfiles[address] = p
        return p
    }

    func noteOwnProfile(_ profile: KachatNames.Profile, address: String, txId: String) {
        storeOwnProfile(OwnProfile(address: address.lowercased(), profile: profile.sanitized(), txId: txId, at: KachatNames.nowMs()))
    }

    private func storeOwnProfile(_ record: OwnProfile) {
        ownProfiles[record.address] = record
        ownProfileMisses.remove(record.address)
        if let data = try? JSONEncoder().encode(record) {
            Self.writeFile(Self.profileFile(record.address), data, network: Self.profileNetwork(record.address))
        }
        revision += 1
    }

    /// Brings this device's copy of its own profile up to date with the chain, so a profile saved
    /// on another device - KaChat for Android or Desktop, another iPhone - shows here too, and the
    /// editor starts from it instead of overwriting it with an older one. The indexer's record
    /// (`GET /profiles/{address}`, every network) is adopted when this device has none (a fresh
    /// import) or when it is a different, newer record. The local copy stays when it is the same
    /// record or newer (the indexer hasn't seen this device's latest save yet).
    func syncOwnProfile(address: String) async {
        guard KachatNamesService.profilesEnabled, let base = Self.indexerBase() else { return }
        let key = address.lowercased()
        guard NetworkType.isOnActiveNetwork(key),
              let j: KachatNames.IndexerAPI.ProfileJSON = try? await Self.get(base, "/profiles/\(key)"),
              j.address.lowercased() == key, let remote = j.profile?.sanitized(), let txId = j.txId else { return }
        if let local = ownProfile(for: key) {
            guard local.txId != txId, let at = j.updatedAt, at > local.at else { return }
        }
        AppLog.log("[KachatNames] own profile updated from the chain (saved on another device): %@", String(txId.prefix(12)))
        storeOwnProfile(OwnProfile(address: key, profile: remote, txId: txId, at: j.updatedAt ?? KachatNames.nowMs()))
    }

    /// An offer this wallet just created: tracked by the walker from now on.
    func trackOffer(_ offer: KachatNames.OfferInfo) {
        if walkTask != nil { offersTrackedDuringWalk.append(offer) }
        guard var st = chainState else { return }
        st.trackOffer(offer, at: KachatNames.nowMs())
        chainState = st
        Self.saveCache(st)
        revision += 1
    }

    // MARK: - Addresses

    nonisolated static func address(of xonly: Data) -> String? {
        guard xonly.count == 32 else { return nil }
        return KaspaAddress(hrp: KachatNamesService.addressPrefix, type: .pubKey, payload: xonly).address
    }

    /// The x-only key of a Schnorr address on the network the app runs on.
    nonisolated static func keyOf(_ address: String) -> Data? {
        guard let a = KaspaAddress(address: address.lowercased()), a.hrp == KachatNamesService.addressPrefix, a.type == .pubKey, a.payload.count == 32 else { return nil }
        return a.payload
    }

    /// The network prefix plus both ends of the address on one line:
    /// `kaspatest:qr4x7k...a9z2pq`. Used where the full address doesn't fit (the Owner card).
    nonisolated static func compactAddress(_ address: String) -> String {
        guard let colon = address.firstIndex(of: ":") else { return address }
        let prefix = address[...colon]
        let body = address[address.index(after: colon)...]
        guard body.count > 14 else { return address }
        return "\(prefix)\(body.prefix(6))...\(body.suffix(6))"
    }

    /// `kaspatest:qr...xyz4`.
    nonisolated static func shortAddress(_ address: String) -> String {
        guard address.count > 20 else { return address }
        return "\(address.prefix(14))...\(address.suffix(6))"
    }

    // MARK: - HTTP

    private nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Off the main actor: listings, history and activity answers decode on the shared pool.
    private nonisolated static func get<T: Decodable>(_ base: String, _ path: String) async throws -> T {
        guard let url = URL(string: base + path) else { throw KachatNames.Failure("bad indexer URL") }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            if code == 404 { throw KachatNames.Failure("not found") }
            throw KachatNames.Failure("the names indexer answered \(code)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Off the main actor, like `get`: a JSON POST to the names indexer.
    private nonisolated static func post<Body: Encodable, T: Decodable>(_ base: String, _ path: String, _ body: Body) async throws -> T {
        guard let url = URL(string: base + path) else { throw KachatNames.Failure("bad indexer URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            if code == 404 { throw KachatNames.Failure("not found") }
            throw KachatNames.Failure("the names indexer answered \(code)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Cache files (Application Support/KachatNames/<network>/)

    private nonisolated static func directory(network: String = KachatNamesService.networkName) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("KachatNames", isDirectory: true).appendingPathComponent(network, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func readFile(_ name: String, network: String = KachatNamesService.networkName) -> Data? {
        guard let dir = directory(network: network) else { return nil }
        return try? Data(contentsOf: dir.appendingPathComponent(name))
    }

    nonisolated static func writeFile(_ name: String, _ data: Data, network: String = KachatNamesService.networkName) {
        guard let dir = directory(network: network) else { return }
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    /// The cache folder an address's own profile lives in: its network's (testnet keeps the
    /// registry's folder, so profiles saved before mainnet profiles existed are still found).
    private static func profileNetwork(_ address: String) -> String {
        NetworkType(address: address) == .mainnet ? "mainnet" : "testnet-10"
    }

    static func walletSuffix(_ address: String) -> String {
        KeychainService.walletHashSuffix(address.lowercased())
    }

    private static func profileFile(_ address: String) -> String { "profile-\(walletSuffix(address)).json" }

    private static func loadCache(_ m: KachatNames.Manifest) -> KachatNames.RegistryState? {
        guard let data = readFile("registry.json"),
              let st = try? JSONDecoder().decode(KachatNames.RegistryState.self, from: data),
              st.matches(m), (try? st.checkInvariants()) != nil else { return nil }
        return st
    }

    /// The whole registry as JSON: encoded and written off the main thread, in order.
    private static let cacheQueue = DispatchQueue(label: "kachat.names.registry-cache", qos: .utility)

    private static func saveCache(_ st: KachatNames.RegistryState) {
        let network = KachatNamesService.networkName
        cacheQueue.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(st) { writeFile("registry.json", data, network: network) }
        }
    }
}

// MARK: - Social profile: avatar, banner and bio (looked up on the device)

/// The profile cache folder (Caches/KachatProfiles): what the app knows about people's profiles -
/// their identity records and the avatars, banners and bios looked up from their social links.
/// Rebuilt on demand, so it lives in Caches and is measured and cleared by Settings > Storage >
/// Cache > Profiles (with the avatar and banner images, `KNSProfileImages`).
enum KachatProfileCache {
    static var directory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("KachatProfiles", isDirectory: true)
    }

    static func read(_ name: String) -> Data? {
        guard let url = directory?.appendingPathComponent(name) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func write(_ name: String, _ data: Data) {
        guard let dir = directory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    static func remove(_ name: String) {
        guard let url = directory?.appendingPathComponent(name) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Turns a profile's social link (`KachatNames.SocialSource`) into what that platform shows right
/// now - avatar, banner, bio - and caches the answer on this device; no indexer involved.
///
/// The cache holds the picture URLs and the bio; `KNSAvatarView` / `KNSBannerImageView` download
/// and keep the images. An answer is fresh for 5 days; a stale one is still shown while it is
/// looked up again. When the platform answers but no longer shows something (taken down, account
/// gone), it is dropped at once, so the platform's moderation carries over. When the platform
/// can't be reached, the last answer stays.
@MainActor
final class KachatSocialImageResolver: ObservableObject {
    static let shared = KachatSocialImageResolver()

    private struct Entry: Codable {
        var profile: KachatNames.SocialProfile
        var checkedAt: Date
    }

    /// The cache file in `KachatProfileCache` (it lived in UserDefaults before 2026-10-07).
    private static let cacheFile = "social.json"
    private static let legacyDefaultsKey = "kachat_social_profile_cache"
    /// Avatars, banners and bios are looked up afresh once their answer is 5 days old, so an
    /// updated profile reaches everyone eventually (the last answer shows meanwhile).
    private static let freshFor: TimeInterval = 5 * 24 * 3600
    private static let maxEntries = 500
    /// The link-preview crawler user agent: X, TikTok and others serve their Open Graph tags to it.
    private static let crawlerAgent = "facebookexternalhit/1.1"
    /// A desktop browser: YouTube's desktop channel page carries the banner in plain form (the
    /// mobile page escapes it); GitHub's API wants a User-Agent.
    private static let browserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// Not `@Published`: a re-check that finds the same profile only stamps `checkedAt`, and
    /// that must not redraw every avatar on screen. `objectWillChange` is sent by hand when a
    /// profile really changes.
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<Lookup, Never>] = [:]
    /// Links a view body already started a lookup for: `profile(for:)` runs on every redraw of
    /// every avatar, and must start one lookup, not one per redraw.
    private var requested: Set<String> = []
    /// When a link's platform last couldn't be reached: not asked again for ten minutes, so an
    /// unreachable platform isn't hit again on every redraw.
    private var unreachableAt: [String: Date] = [:]
    private static let unreachableRetry: TimeInterval = 600
    private var persistScheduled = false

    private init() {
        if let data = KachatProfileCache.read(Self.cacheFile),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else if let data = UserDefaults.standard.data(forKey: Self.legacyDefaultsKey),
                  let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            // moved out of UserDefaults into the measurable, clearable profile cache folder
            entries = decoded
            KachatProfileCache.write(Self.cacheFile, data)
        }
        UserDefaults.standard.removeObject(forKey: Self.legacyDefaultsKey)
        // Answers with nothing at all are looked up again once: earlier builds cached FxTwitter's
        // wrong "User not found" as an account with no avatar, banner or bio for a day.
        if !UserDefaults.standard.bool(forKey: Self.emptyRecheckKey) {
            entries = entries.filter { $0.value.profile != KachatNames.SocialProfile() }
            UserDefaults.standard.set(true, forKey: Self.emptyRecheckKey)
        }
    }

    private static let emptyRecheckKey = "kachat_social_empty_rechecked_v1"

    /// Settings > Storage > Cache > Profiles: forgets every looked-up avatar, banner and bio;
    /// they are looked up again when next shown.
    func clearAll() {
        objectWillChange.send()
        entries = [:]
        requested = []
        unreachableAt = [:]
        inFlight.values.forEach { $0.cancel() }
        inFlight = [:]
        KachatProfileCache.remove(Self.cacheFile)
    }

    /// The stored answer for `source`, however old - read only, no lookup started. The profile
    /// editor's preview rows use it: a Form rebuilds rows on scroll, and one scrolled back in
    /// must show its answer again at once instead of debouncing and looking it up afresh.
    func cachedProfile(_ source: KachatNames.SocialSource) -> KachatNames.SocialProfile? {
        entries[source.link]?.profile
    }

    /// The cached profile for `link`, starting a lookup when there is none or it is stale.
    /// Views read this in `body`; the published cache re-renders them when the lookup lands.
    func profile(for link: String?) -> KachatNames.SocialProfile? {
        guard let link, let source = KachatNames.SocialSource(link: link, for: .avatar) else { return nil }
        let key = source.link
        let entry = entries[key]
        let stale = entry.map { Date().timeIntervalSince($0.checkedAt) > Self.freshFor } ?? true
        let unreachableRecently = unreachableAt[key].map { Date().timeIntervalSince($0) < Self.unreachableRetry } ?? false
        if stale, !unreachableRecently, inFlight[key] == nil, !requested.contains(key) {
            requested.insert(key)
            Task {
                _ = await self.resolve(source, maxAge: Self.freshFor)
                self.requested.remove(key)
            }
        }
        return entry?.profile
    }

    /// Looks these profile links up again now, whatever the cache holds (User Info > Rescan
    /// Profile): an avatar, banner or bio changed on the platform shows at once. Returns the
    /// fresh answers by link.
    func rescan(_ links: [String?]) async -> [String: KachatNames.SocialProfile] {
        var answers: [String: KachatNames.SocialProfile] = [:]
        for link in Set(links.compactMap { $0 }) {
            guard let source = KachatNames.SocialSource(link: link, for: .avatar) else { continue }
            unreachableAt[source.link] = nil
            if let profile = await resolve(source, maxAge: 0).profile { answers[link] = profile }
        }
        return answers
    }

    /// What a lookup came back with.
    enum Lookup: Equatable {
        /// The platform answered (possibly with nothing: taken down, account gone).
        case answered(KachatNames.SocialProfile)
        /// It couldn't be reached in time; the last answer this device had, if any.
        case unreachable(KachatNames.SocialProfile?)

        var profile: KachatNames.SocialProfile? {
            switch self {
            case .answered(let p): return p
            case .unreachable(let p): return p
            }
        }
    }

    /// Hard limit for one lookup, every request and fallback included: a preview never spins
    /// longer than this. Each step has its own shorter timeout (`fetch(timeout:)`), so a slow
    /// first source can't use up the time the next one needs.
    private static let deadline: UInt64 = 20_000_000_000

    /// Looks the profile up now (the editor's preview), sharing a lookup in flight.
    @discardableResult
    func resolve(_ source: KachatNames.SocialSource, maxAge: TimeInterval = 300) async -> Lookup {
        let key = source.link
        // A recent answer is the answer: three fields on one account cost one request.
        if let entry = entries[key], Date().timeIntervalSince(entry.checkedAt) < maxAge {
            return .answered(entry.profile)
        }
        if let running = inFlight[key] { return await running.value }
        let task = Task<Lookup, Never> { [weak self] in
            let started = Date()
            let outcome = await Self.withDeadline { await Self.lookUp(source) }
            AppLog.log("[KachatSocial] %@ %@ in %.1fs", source.platform.rawValue,
                       outcome == nil ? "unreachable" : "answered", Date().timeIntervalSince(started))
            guard let self else { return .unreachable(nil) }
            guard let answered = outcome else {
                self.unreachableAt[key] = Date()
                return .unreachable(self.entries[key]?.profile) // keep the last answer
            }
            self.unreachableAt[key] = nil
            if self.entries[key]?.profile != answered { self.objectWillChange.send() }
            self.entries[key] = Entry(profile: answered, checkedAt: Date())
            self.persist()
            return .answered(answered)
        }
        inFlight[key] = task
        let value = await task.value
        inFlight[key] = nil
        return value
    }

    /// `work`'s result, or nil once the deadline passes (the work is cancelled).
    private nonisolated static func withDeadline(_ work: @escaping @Sendable () async -> KachatNames.SocialProfile?) async -> KachatNames.SocialProfile? {
        await withTaskGroup(of: KachatNames.SocialProfile??.self) { group in
            group.addTask { .some(await work()) }
            group.addTask {
                try? await Task.sleep(nanoseconds: deadline)
                return .none
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
    }

    /// One disk write for a burst of answers, off the main thread.
    private func persist() {
        guard !persistScheduled else { return }
        persistScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            self.persistScheduled = false
            self.writeEntries()
        }
    }

    private func writeEntries() {
        if entries.count > Self.maxEntries {
            let oldest = entries.sorted { $0.value.checkedAt < $1.value.checkedAt }.prefix(entries.count - Self.maxEntries)
            for (k, _) in oldest { entries[k] = nil }
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let file = Self.cacheFile
        Task.detached(priority: .utility) { KachatProfileCache.write(file, data) }
    }

    /// The platform's answer (possibly empty: taken down, account gone), or nil when it
    /// couldn't be reached or answered with an error - nothing is known then.
    private nonisolated static func lookUp(_ source: KachatNames.SocialSource) async -> KachatNames.SocialProfile? {
        typealias S = KachatNames.SocialSource
        switch source.platform {
        case .discord:
            guard let url = URL(string: "https://discord.com/api/v10/invites/\(source.handle)"),
                  let (data, status) = await fetch(url, agent: browserAgent) else { return nil }
            if status == 404 { return KachatNames.SocialProfile() }
            guard status == 200 else { return nil }
            return KachatNames.SocialProfile(avatar: S.discordImage(fromInviteJSON: data, kind: .avatar),
                                             banner: S.discordImage(fromInviteJSON: data, kind: .banner),
                                             bio: S.discordDescription(fromInviteJSON: data))
        case .x:
            // FxTwitter first: one small JSON answer with avatar, banner and bio. X's own page
            // (served to link-preview crawlers) is the fallback, and unavatar.io the last resort
            // for the avatar alone. Each step's outcome is logged: a phone network can be
            // challenged or rate-limited where a desktop is not.
            if let url = URL(string: "https://api.fxtwitter.com/\(source.handle)") {
                let answer = await fetch(url, agent: browserAgent, timeout: 5)
                // Only a profile is taken from FxTwitter. Its "User not found" is not final: it
                // says that for real accounts too (@Curiousbeing99, 2026-10-07), so X's own page
                // below decides whether the account is gone.
                if let (data, status) = answer, status == 200,
                   let p = S.fxTwitterProfile(fromJSON: data), p != KachatNames.SocialProfile() {
                    return p
                }
                AppLog.log("[KachatSocial] x %@: FxTwitter %@", source.handle,
                           answer.map { "HTTP \($0.1)" } ?? "no answer")
            }
        case .github:
            guard let url = URL(string: "https://api.github.com/users/\(source.handle)"),
                  let (data, status) = await fetch(url, agent: browserAgent) else { return nil }
            if status == 404 { return KachatNames.SocialProfile() }
            guard status == 200 else { return nil }
            let gh = S.githubProfile(fromJSON: data)
            return KachatNames.SocialProfile(avatar: gh.avatar, banner: nil, bio: gh.bio)
        default:
            break
        }
        guard let url = URL(string: source.link), let (data, status) = await fetch(url, agent: crawlerAgent) else {
            AppLog.log("[KachatSocial] %@ %@: page no answer", source.platform.rawValue, source.handle)
            return await xAvatarOnly(source)
        }
        if status == 404 || status == 410 { return KachatNames.SocialProfile() }
        guard status == 200 else {
            AppLog.log("[KachatSocial] %@ %@: page HTTP %d", source.platform.rawValue, source.handle, status)
            return await xAvatarOnly(source)
        }
        let html = String(decoding: data, as: UTF8.self)
        // A page with no profile tags at all is not a profile without an avatar: it's a login
        // wall, a challenge or a script shell. That is "couldn't look it up", never cached as
        // an empty answer that would read as "this account has no avatar".
        guard S.openGraphImage(in: html) != nil || S.openGraphDescription(in: html) != nil else {
            AppLog.log("[KachatSocial] %@ %@: page has no profile tags (%d bytes)", source.platform.rawValue, source.handle, data.count)
            return await xAvatarOnly(source)
        }
        var result = KachatNames.SocialProfile()
        if let image = S.openGraphImage(in: html) {
            result.avatar = source.platform == .x ? S.xAvatar(fromOpenGraph: image) : image
        }
        result.bio = S.bio(for: source.platform, openGraphDescription: S.openGraphDescription(in: html))
        switch source.platform {
        case .x:
            result.banner = S.xBanner(in: html)
        case .youtube:
            if let (page, st) = await fetch(url, agent: browserAgent, cookie: "CONSENT=YES+1"), st == 200 {
                result.banner = S.youtubeBanner(in: String(decoding: page, as: UTF8.self))
            }
        default:
            break
        }
        return result
    }

    /// X only, when FxTwitter and X's page both failed: the avatar from unavatar.io, which answers
    /// with the image itself (404 when the account has none). nil = still unreachable.
    private nonisolated static func xAvatarOnly(_ source: KachatNames.SocialSource) async -> KachatNames.SocialProfile? {
        guard source.platform == .x,
              let url = URL(string: "https://unavatar.io/x/\(source.handle)?fallback=false"),
              let (data, status) = await fetch(url, agent: browserAgent, timeout: 5) else { return nil }
        guard status == 200, data.count > 0 else {
            AppLog.log("[KachatSocial] x %@: unavatar HTTP %d", source.handle, status)
            return nil
        }
        var p = KachatNames.SocialProfile()
        p.avatar = url.absoluteString
        return p
    }

    /// Ephemeral (nothing written to the shared cookie store or cache), and no request outlives 8 s.
    private nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private nonisolated static func fetch(_ url: URL, agent: String, cookie: String? = nil, timeout: TimeInterval = 6) async -> (Data, Int)? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (data.prefix(3_000_000), http.statusCode)
    }
}

// MARK: - The Profile bell: what happened to your names and offers

/// Turns registry changes into Profile-bell rows (`GlobalNotificationCenter`, source `.kachat`),
/// so a missed push still leaves a trace: an offer on one of your names, a name sold or
/// reclaimed, its renewal window opening, its expiry and lapse, and what became of your own
/// offers (accepted, declined, expired and returned). It compares what the registry says now
/// with what it saw on the last check (persisted per wallet), after every registry refresh.
/// The first check of a wallet only records where things stand.
@MainActor
final class KachatNamesNotifier {
    static let shared = KachatNamesNotifier()
    private init() {}

    private struct Snapshot: Codable {
        struct Name: Codable {
            var expiresAt: Int64
            var renewNoted = false
            var graceNoted = false
            var lapsedNoted = false
        }
        /// the names this wallet owned at the last check
        var names: [String: Name] = [:]
        /// open offers on those names, by id
        var offersOnMine: Set<String> = []
        /// this wallet's own open offers: id -> name
        var myOffers: [String: String] = [:]
    }

    private var checking = false
    /// Offers this person closed themselves (Withdraw, Refund): not news when they disappear.
    var selfClosedOffers: Set<String> = []

    private func key(_ wallet: String) -> String { "kachatNamesNotifier.\(wallet)" }

    func check() async {
        guard KachatNamesService.isLaunched, !checking,
              let me = KachatNamesActions.shared.myKey, let wallet = KachatNamesActions.shared.myAddress,
              let p = KachatNamesService.shared.manifest?.params else { return }
        checking = true
        defer { checking = false }
        let registry = KachatNamesRegistry.shared
        // every address of this wallet, not only the main one: a name claimed with Buy From
        // gets its notices too (IOS-085 / XP-024)
        guard let own = try? await KachatNamesActions.shared.ownNamesAndOffers(heldOnly: false) else { return }
        let owned = own.names
        let myOpenOffers = own.offers
        let ownKeys = KachatNamesActions.shared.allOwnKeys
        var offersOnMine: [KachatNames.OfferInfo] = []
        for n in owned where n.status(graceMs: p.graceMs) == .active {
            // a failed read isn't "no offers": comparing it would announce them all gone, then new
            guard let offers = try? await registry.offers(for: n.name) else { return }
            offersOnMine += offers.filter { ownKeys.contains($0.seller) }
        }
        // The indexer pushes name reminders only to the chatting address: for a name on another
        // address of this wallet the phone schedules its own (XP-024).
        // a different wallet signed in meanwhile: this answer isn't its
        guard KachatNamesActions.shared.myAddress == wallet else { return }
        await KachatNameReminders.schedule(for: owned.filter { $0.owner != me }, params: p, wallet: wallet)

        let old: Snapshot? = UserDefaults.standard.data(forKey: key(wallet)).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
        let quiet = old == nil // the first check only records where things stand
        var new = Snapshot()
        let now = KachatNames.nowMs()

        func post(_ id: String, _ name: String, _ title: String, _ body: String) {
            // the history reads below can outlast a sign-out: the bell is the signed-in account's
            guard !quiet, KachatNamesActions.shared.myAddress == wallet else { return }
            GlobalNotificationCenter.shared.record(id: "kachat-\(id)", source: .kachat, title: title, body: body,
                                                   timestamp: now, targetId: name)
        }
        func S(_ key: String, _ args: CVarArg...) -> String {
            KaspaUnit.label(String(format: AppLocalization.string(key), locale: AppLocalization.locale, arguments: args))
        }

        // Your names: renewal open, expired (grace), lapsed - once per paid period.
        for n in owned {
            let display = "\(n.name).kachat"
            var s = old?.names[n.name].flatMap { $0.expiresAt == n.expiresAt ? $0 : nil } ?? Snapshot.Name(expiresAt: n.expiresAt)
            switch n.status(graceMs: p.graceMs, nowMs: now) {
            case .active:
                if n.renewOpen(p, nowMs: now), !s.renewNoted {
                    post("renew-\(n.name)-\(n.expiresAt)", n.name, S("Renew %@", display),
                         S("Renewal is open: renew it before %@ to keep it.", KachatNamesActions.dayString(n.expiresAt)))
                    s.renewNoted = true
                }
            case .grace:
                s.renewNoted = true
                if !s.graceNoted {
                    post("grace-\(n.name)-\(n.expiresAt)", n.name, S("%@ has expired", display),
                         S("Renew it before %@ or anyone can claim it.", KachatNamesActions.dayString(n.expiresAt + p.graceMs)))
                    s.graceNoted = true
                }
            case .lapsed:
                s.renewNoted = true
                s.graceNoted = true
                if !s.lapsedNoted {
                    post("lapsed-\(n.name)-\(n.expiresAt)", n.name, S("%@ is no longer yours", display),
                         AppLocalization.string("It expired and wasn't renewed, so it's now available to anyone in the marketplace. Your bond comes back to you when someone claims it."))
                    s.lapsedNoted = true
                }
            }
            new.names[n.name] = s
        }

        // Names that left this wallet: sold, bought through an offer, or reclaimed by someone.
        // A transfer or release is your own doing and needs no notice.
        for name in old.map({ Array($0.names.keys) }) ?? [] where new.names[name] == nil {
            let history = (try? await registry.history(name: name)) ?? []
            guard let last = history.first(where: { ["sale", "offer_accepted", "offer_accept", "transfer", "release", "reclaim"].contains($0.op) }) else { continue }
            let display = "\(name).kachat"
            switch last.op {
            case "sale":
                post("sold-\(last.txId)", name, S("%@ sold", display),
                     last.price.map { S("%@ KAS was paid to you.", KaspaUnit.plain($0)) } ?? AppLocalization.string("Your listing was bought."))
            case "offer_accepted", "offer_accept":
                post("sold-\(last.txId)", name, S("%@ sold", display), AppLocalization.string("You accepted an offer for it."))
            case "reclaim":
                post("reclaimed-\(last.txId)", name, S("%@ was freed", display),
                     AppLocalization.string("It expired and was cleared from the registry. Your bond is back with you."))
            default:
                break
            }
        }

        // The chain copy knows only the offers this device tracked. Another device's offer isn't
        // gone just because the registry is being read from the chain: those stay as they were,
        // and are compared once the indexer is back.
        let offersAreComplete = registry.source != .chain
        if !offersAreComplete {
            new.offersOnMine = old?.offersOnMine ?? []
            new.myOffers = old?.myOffers ?? [:]
        }

        // Offers on your names.
        for o in offersOnMine {
            new.offersOnMine.insert(o.id)
            guard old?.offersOnMine.contains(o.id) != true, let name = o.name else { continue }
            post("offer-\(o.id)", name, S("New offer on %@", "\(name).kachat"), S("%@ KAS offered for it.", KaspaUnit.plain(o.amount)))
        }

        // Your offers: accepted, or back with you.
        for o in myOpenOffers { new.myOffers[o.id] = o.name ?? "" }
        for (id, name) in old?.myOffers ?? [:] where offersAreComplete && new.myOffers[id] == nil && !name.isEmpty {
            if selfClosedOffers.contains(id) { continue }
            let display = "\(name).kachat"
            if owned.contains(where: { $0.name == name }) {
                post("myoffer-\(id)", name, AppLocalization.string("Offer accepted"), S("%@ is yours now.", display))
                continue
            }
            let history = (try? await registry.history(name: name)) ?? []
            switch history.first(where: { ["offer_decline", "offer_refund", "offer_withdraw"].contains($0.op) })?.op {
            case "offer_decline":
                post("myoffer-\(id)", name, S("Offer on %@ declined", display), AppLocalization.string("The owner declined it. The KAS is back with you."))
            case "offer_refund":
                post("myoffer-\(id)", name, S("Offer on %@ expired", display), AppLocalization.string("Nobody accepted it in time. The KAS is back with you."))
            default:
                post("myoffer-\(id)", name, S("Offer on %@ returned", display), AppLocalization.string("It can no longer be accepted. The KAS is back with you."))
            }
        }

        if let data = try? JSONEncoder().encode(new) { UserDefaults.standard.set(data, forKey: key(wallet)) }
    }
}

/// Local reminders for .kachat names held by one of this wallet's spending addresses (Buy From):
/// the indexer's renewal and expiry pushes reach only the chatting address, so the phone
/// schedules its own - renewal opens, the name expired, and a day before grace ends - from each
/// name's expiry (XP-024). Nothing leaves the phone. Rescheduled on every notifier check: a
/// renewed name moves its reminders, a name that left the wallet loses them. Tapping one opens
/// the name (thread "kachat-names", like the pushes).
@MainActor
enum KachatNameReminders {
    /// `kachat-reminder-<network>-<wallet tag>-<name>-<expiresAt>-<kind>`: each wallet and
    /// network keeps its own set, so a check on one never removes another's (IOS-088).
    private static let root = "kachat-reminder-"
    /// The first build's ids, one device-wide set: removed wherever they are found.
    private static let legacyPrefix = "kachat-local-"

    /// A short, stable tag for a wallet in the ids (the address's last 12 characters).
    private static func walletTag(_ wallet: String) -> String {
        String(wallet.lowercased().suffix(12))
    }

    private static func prefix(wallet: String, network: String) -> String {
        "\(root)\(network)-\(walletTag(wallet))-"
    }

    /// A wallet's reminders, for when it leaves this phone. The tag comes from the address as
    /// given, whose checksum differs between kaspa: and kaspatest:, so a caller removing an
    /// account calls this for each of its network variants (`accountAddressVariants`).
    static func removeAll(forWallet wallet: String) async {
        let center = UNUserNotificationCenter.current()
        let tag = "-\(walletTag(wallet))-"
        let ids = await center.pendingNotificationRequests().map(\.identifier)
            .filter { $0.hasPrefix(root) && $0.contains(tag) }
        if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
    }

    static func schedule(for names: [KachatNames.NameInfo], params p: KachatNames.Params, wallet: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let all = await center.pendingNotificationRequests().map(\.identifier)
        let legacy = all.filter { $0.hasPrefix(legacyPrefix) }
        if !legacy.isEmpty { center.removePendingNotificationRequests(withIdentifiers: legacy) }
        let prefix = prefix(wallet: wallet, network: KachatNamesService.networkName)
        // only this wallet's reminders on this network are this call's to keep or drop
        let pending = all.filter { $0.hasPrefix(prefix) }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            center.removePendingNotificationRequests(withIdentifiers: pending)
            return
        }
        let now = KachatNames.nowMs()
        var wanted: [String: (date: Int64, title: String, body: String, name: String)] = [:]
        func S(_ key: String, _ args: CVarArg...) -> String {
            KaspaUnit.label(String(format: AppLocalization.string(key), locale: AppLocalization.locale, arguments: args))
        }
        for n in names {
            let display = "\(n.name).kachat"
            let base = "\(prefix)\(n.name)-\(n.expiresAt)-"
            let renewAt = n.expiresAt - p.renewWindowMs
            if renewAt > now {
                wanted[base + "renew"] = (renewAt, S("Renew %@", display),
                                          S("Renewal is open: renew it before %@ to keep it.", KachatNamesActions.dayString(n.expiresAt)), n.name)
            }
            if n.expiresAt > now {
                wanted[base + "grace"] = (n.expiresAt, S("%@ has expired", display),
                                          S("Renew it before %@ or anyone can claim it.", KachatNamesActions.dayString(n.expiresAt + p.graceMs)), n.name)
            }
            let lastCall = n.expiresAt + p.graceMs - min(p.graceMs / 2, 86_400_000)
            if lastCall > now {
                wanted[base + "lastcall"] = (lastCall, S("%@ has expired", display),
                                             S("Renew it before %@ or anyone can claim it.", KachatNamesActions.dayString(n.expiresAt + p.graceMs)), n.name)
            }
        }
        let stale = pending.filter { wanted[$0] == nil }
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
        for (id, r) in wanted where !pending.contains(id) {
            let content = UNMutableNotificationContent()
            content.title = r.title
            content.body = r.body
            content.sound = .default
            content.threadIdentifier = "kachat-names"
            content.userInfo = ["name": r.name]
            let seconds = max(1, TimeInterval(r.date - now) / 1000)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }
}
