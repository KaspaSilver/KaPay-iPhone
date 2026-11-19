import Foundation

/// Reads an address's kUSDT the way kusdt-open's wallet does (`wallet/extension/src/kusdt/verify.ts`):
/// Trestly's API says which coins the owner has (`GET /tokens?owner=`, SPEC section 13), and each
/// one is believed only once the node shows it:
///   1. the state is a plain coin of this address's key (`Kusdt.State.isPlain`),
///   2. its locking script is recomputed here from the state and the pinned template,
///   3. the node holds that exact outpoint at that script, carrying kUSDT's covenant id.
/// Anything else is dropped. Only the confirmed UTXO set counts (a coin still in the mempool shows
/// once it's accepted). The API learns the address asked about; nothing else leaves the phone.
enum KusdtBalances {
    struct Coin: Equatable {
        let transactionId: String
        let index: UInt32
        let state: Kusdt.State
        /// The KAS the coin carries (1.5 KAS for a new one).
        let kasSompi: UInt64
        /// The DAA score of the block that accepted it (the builder takes it with the coin).
        var blockDaaScore: UInt64 = 0
    }

    /// A coin this phone expects at the address (a send from here made it) that Trestly may not
    /// list yet: checked on the node like the listed ones, so it counts as soon as the node has it.
    struct Expected {
        let transactionId: String
        let index: UInt32
        let state: Kusdt.State
    }

    struct AddressResult {
        let address: String
        let coins: [Coin]
        /// The outpoints ("txid:index") Trestly listed itself, so an expected coin can be let go.
        var listedByAPI: Set<String> = []
        /// Coins the API lists at an address the node can't list (too many coins there): neither
        /// shown nor taken as gone.
        let uncheckedCount: Int

        var units: UInt64 { coins.reduce(0) { $0 + $1.state.amount } }
    }

    enum Failure: LocalizedError {
        case templateMissing
        case api(String)

        var errorDescription: String? {
            switch self {
            case .templateMissing: return AppLocalization.string("KaPay's kUSDT template is missing, so kUSDT can't be checked.")
            case .api(let why): return why
            }
        }
    }

    /// The biggest honest answer (500 coins with their states) is well under this.
    private static let maxAnswerBytes = 4 * 1024 * 1024

    /// The address's verified kUSDT coins. An address that isn't a Schnorr key address holds none
    /// KaPay can use, and isn't asked about.
    static func fetch(address: String, expected: [Expected] = []) async throws -> AddressResult {
        guard let owner = Kusdt.schnorrOwner(of: address) else {
            return AddressResult(address: address, coins: [], uncheckedCount: 0)
        }
        guard let template = Kusdt.template else { throw Failure.templateMissing }
        let deployment = Kusdt.current
        let answer = try await tokens(owner: address)

        // 1 and 2: plain coins of this key, with their scripts and addresses worked out here
        struct Wanted { let txid: String; let index: UInt32; let state: Kusdt.State; let script: Data; let address: String }
        var wanted: [Wanted] = []
        for entry in answer.states {
            guard let state = entry.state, state.isPlain(of: owner) else { continue }
            let script = Kusdt.lockingScript(state, template: template)
            guard let coinAddress = Kusdt.address(ofLockingScript: script) else { continue }
            wanted.append(Wanted(txid: entry.txid, index: entry.index, state: state, script: script, address: coinAddress))
        }
        let listedByAPI = Set(wanted.map { "\($0.txid):\($0.index)" })
        for e in expected where !listedByAPI.contains("\(e.transactionId):\(e.index)") && e.state.isPlain(of: owner) {
            let script = Kusdt.lockingScript(e.state, template: template)
            guard let coinAddress = Kusdt.address(ofLockingScript: script) else { continue }
            wanted.append(Wanted(txid: e.transactionId, index: e.index, state: e.state, script: script, address: coinAddress))
        }
        guard !wanted.isEmpty else {
            return AddressResult(address: address, coins: [], uncheckedCount: answer.unreadCount)
        }

        // 3: the node, one read for every address (never the REST fallback: it carries no covenant id)
        let utxos = try await NodePoolService.shared.getUtxosByAddresses(Array(Set(wanted.map(\.address))), allowRestFallback: false)
        let covenant = Kusdt.hex(deployment.covenantId)
        var coins: [Coin] = []
        for w in wanted {
            guard let u = utxos.first(where: { $0.outpoint.transactionId.lowercased() == w.txid && $0.outpoint.index == w.index }),
                  u.scriptPublicKey == w.script,
                  u.covenantId?.lowercased() == covenant else { continue }
            coins.append(Coin(transactionId: w.txid, index: w.index, state: w.state, kasSompi: u.amount, blockDaaScore: u.blockDaaScore))
        }
        if coins.count < wanted.count {
            AppLog.log("[kUSDT] %d of %d listed coins weren't on the node as listed: not shown", wanted.count - coins.count, wanted.count)
        }
        return AddressResult(address: address, coins: coins, uncheckedCount: answer.unreadCount, listedByAPI: listedByAPI)
    }

    // MARK: Trestly's API

    private struct Listed {
        let txid: String
        let index: UInt32
        let state: Kusdt.State?
    }

    private struct TokensAnswer {
        let states: [Listed]
        let unreadCount: Int
    }

    private static func tokens(owner address: String) async throws -> TokensAnswer {
        let base = AppSettings.load().trestlyAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(string: base.hasSuffix("/") ? String(base.dropLast()) + "/tokens" : base + "/tokens")
        components?.queryItems = [URLQueryItem(name: "owner", value: address)]
        guard let url = components?.url, url.scheme == "https" else {
            throw Failure.api(AppLocalization.string("The Trestly API address in Connection Settings isn't a valid https address."))
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.api(AppLocalization.string("Trestly didn't answer.")) }
        guard (200...299).contains(http.statusCode) else {
            throw Failure.api(String(format: AppLocalization.string("Trestly answered HTTP %d."), http.statusCode))
        }
        guard data.count <= maxAnswerBytes,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.api(AppLocalization.string("Trestly's answer couldn't be read."))
        }
        let states = (json["states"] as? [[String: Any]] ?? []).compactMap(listed)
        let unread = (json["unread"] as? [Any])?.count ?? 0
        return TokensAnswer(states: states, unreadCount: unread)
    }

    private static func listed(_ entry: [String: Any]) -> Listed? {
        guard let utxo = entry["utxo"] as? [String: Any],
              let txid = (utxo["transactionId"] as? String)?.lowercased(), txid.count == 64,
              Kusdt.unhexOrNil(txid) != nil,
              let index = natural(utxo["index"]), index <= UInt64(UInt32.max) else { return nil }
        return Listed(txid: txid, index: UInt32(index), state: (entry["state"] as? [String: Any]).flatMap(state))
    }

    /// A state as the API writes it (kusdt-open `parseTokenState`): hex32 fields, small ints, the
    /// amount as a JSON integer or a string of digits.
    private static func state(_ s: [String: Any]) -> Kusdt.State? {
        guard let amount = natural(s["amount"]),
              let owner = hex32(s["owner"]),
              let scheme = natural(s["ownerScheme"]), scheme <= 255 else { return nil }
        let borrow = natural(s["borrowScheme"] ?? 0) ?? 256
        guard borrow <= 255,
              let guardHash = hex32(s["borrowGuard"] ?? String(repeating: "0", count: 64)),
              let ext = hex32(s["extensionCommitment"] ?? String(repeating: "0", count: 64)) else { return nil }
        return Kusdt.State(amount: amount, owner: owner, ownerScheme: UInt8(scheme), borrowScheme: UInt8(borrow),
                           borrowGuard: guardHash, extensionCommitment: ext)
    }

    private static func hex32(_ v: Any?) -> Data? {
        guard let s = v as? String, s.count == 64 else { return nil }
        return Kusdt.unhexOrNil(s)
    }

    /// A non-negative integer under 2^63, from a JSON number or a string of digits.
    private static func natural(_ v: Any?) -> UInt64? {
        if let s = v as? String {
            guard !s.isEmpty, s.allSatisfy(\.isASCII), s.allSatisfy(\.isNumber), let n = UInt64(s), n < (1 << 63) else { return nil }
            return n
        }
        if let n = v as? NSNumber {
            // a Bool is an NSNumber too
            guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let i = n.int64Value
            guard i >= 0, NSNumber(value: i) == n else { return nil }
            return UInt64(i)
        }
        return nil
    }
}
