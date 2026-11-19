import Foundation

/// A kUSDT send, as kusdt-open's wallet makes one (`wallet/extension/src/kusdt/tokens.ts`
/// `buildTransfer`, `build.ts` `buildFunded` and `checkBuilt`), with Trestly's own builder doing
/// the build and the signing (`KusdtCore`):
///   1. kUSDT coins of the sending address, largest first, at most 3 (more needs a merge first);
///   2. outputs: the recipient's coin, and the rest back to the sender as a change coin, each
///      carrying the token's 1.5 KAS;
///   3. plain KAS coins of the same address pay what the coins' own KAS doesn't, and the fee
///      (largest first, one more while the builder asks for more), so no other address is linked;
///   4. before anything is sent: every token output is exactly the approved state at its
///      recomputed script with its 1.5 KAS, every other output pays the sender back, and the fee
///      is under 3 KAS. Anything off and nothing is sent.
@MainActor
enum KusdtTransfer {
    /// A built, signed, checked transfer, ready to send.
    struct Prepared {
        let txid: String
        /// The network fee (sompi), exactly.
        let fee: UInt64
        /// KAS that goes to the recipient with the kUSDT (the new coin's 1.5 KAS).
        let kasToRecipient: UInt64
        let rpc: Protowire_RpcTransaction
        let spentCoins: [KusdtBalances.Coin]
        /// The change coin's output index, if there is one (yours: never announced as received).
        let changeIndex: UInt32?
        let holding: TokenHolding
        /// Where the kUSDT goes (output 0).
        let recipient: String
        let amount: UInt64
        /// All of the address's kUSDT went and it had no KAS: the fee came out of the KAS that
        /// travels with the tokens, so the recipient's coin holds a little under 1.5 KAS.
        let feeFromTokenKas: Bool
        let preparedAt = Date()
    }

    enum Failure: LocalizedError {
        case recipient
        case notEnoughToken
        case mergeFirst
        /// `short`: about how much KAS the sending address needs added (sompi), for Fund This Address.
        /// `forChangeCoin`: part of it is the 1.5 KAS your change coin holds (a partial send).
        case notEnoughKas(short: UInt64, forChangeCoin: Bool)
        case noKey
        case feeTooHigh
        case checkFailed
        case templateMissing

        var errorDescription: String? {
            switch self {
            case .recipient: return AppLocalization.string("kUSDT can only go to a regular Kaspa address.")
            case .notEnoughToken: return AppLocalization.string("This address doesn't hold that much kUSDT.")
            case .mergeFirst: return AppLocalization.string("That amount is spread over more than 3 kUSDT coins on this address. Send a smaller amount for now.")
            case .notEnoughKas(_, let forChangeCoin):
                return forChangeCoin
                    ? AppLocalization.string("This address needs a little KAS: the network fee, plus 1.5 KAS for your change coin (the kUSDT you keep). That 1.5 KAS stays yours.")
                    : AppLocalization.string("This address needs a little KAS for the network fee.")
            case .noKey: return AppLocalization.string("This address's key isn't available on this phone.")
            case .feeTooHigh: return AppLocalization.string("The network fee is above KaPay's safety limit. Nothing was sent.")
            case .checkFailed: return AppLocalization.string("The built transaction didn't match what you approved, so nothing was sent.")
            case .templateMissing: return AppLocalization.string("KaPay's kUSDT template is missing, so kUSDT can't be checked.")
            }
        }
    }

    /// The most a covenant transaction's fee may be (kusdt-open `MAX_FEE`).
    static let maxFee: UInt64 = 300_000_000
    /// Change the builder couldn't keep, above which one more KAS coin is tried (`ABSORB_LIMIT`).
    static let absorbLimit: UInt64 = 5_000_000
    /// The relay minimum, sompi per gram of normalized mass (kusdt-open tx.rs `MIN_FEERATE`).
    static let feerate: UInt64 = 100
    static let maxTokenInputs = 3
    /// The fee room Fund This Address adds on top of what a send needs (fees run about 0.02 to 0.05 KAS).
    static let fundingFeeMargin: UInt64 = 20_000_000

    // MARK: Build

    static func prepare(holding: TokenHolding, coins: [KusdtBalances.Coin], recipient: String, amount: UInt64) async throws -> Prepared {
        guard let template = Kusdt.template else { throw Failure.templateMissing }
        guard let senderKey = Kusdt.schnorrOwner(of: holding.address) else { throw Failure.noKey }
        guard let recipientKey = Kusdt.schnorrOwner(of: recipient) else { throw Failure.recipient }
        let deployment = Kusdt.current
        let network = AppSettings.load().networkType == .mainnet ? "mainnet" : "testnet-10"

        // 1. the coins, largest first, at most 3
        let sorted = coins.filter { $0.state.amount > 0 }.sorted { $0.state.amount > $1.state.amount }
        var picked: [KusdtBalances.Coin] = []
        var sum: UInt64 = 0
        for coin in sorted where sum < amount && picked.count < maxTokenInputs {
            picked.append(coin)
            sum += coin.state.amount
        }
        guard sum >= amount else {
            throw sorted.reduce(0, { $0 + $1.state.amount }) >= amount ? Failure.mergeFirst : Failure.notEnoughToken
        }

        // 2. the outputs
        var outputs: [(state: Kusdt.State, value: UInt64)] = [(Kusdt.State.plain(owner: recipientKey, amount: amount), deployment.tokenValue)]
        if sum > amount {
            outputs.append((Kusdt.State.plain(owner: senderKey, amount: sum - amount), deployment.tokenValue))
        }
        let kasIn = picked.reduce(UInt64(0)) { $0 + $1.kasSompi }
        let kasOut = outputs.reduce(UInt64(0)) { $0 + $1.value }
        let need = kasOut > kasIn ? kasOut - kasIn : 0

        // the key of the sending address, for this one build
        guard let secret = (holding.spendingIndex.map { WalletManager.shared.spendingPrivateKey(at: $0) } ?? WalletManager.shared.getPrivateKey()) else {
            throw Failure.noKey
        }
        let secretHex = Kusdt.hex(secret)

        // 3. KAS of the same address: plain Schnorr coins, not held by another send, largest first
        let utxos = try await NodePoolService.shared.getUtxosByAddresses([holding.address], allowRestFallback: false)
        let plain = utxos.filter { u in
            let s = [UInt8](u.scriptPublicKey)
            return u.covenantId == nil && !u.isCoinbase && s.count == 34 && s[0] == 0x20 && s[33] == 0xac
        }
        let funding = WalletService.shared.unreservedUtxos(plain).sorted { $0.amount > $1.amount }

        let inputsJSON: [[String: Any]] = picked.map { coin in
            [
                "utxo": [
                    "transactionId": coin.transactionId, "index": coin.index, "amount": coin.kasSompi,
                    "scriptPublicKey": "0000" + Kusdt.hex(Kusdt.lockingScript(coin.state, template: template)),
                    "blockDaaScore": coin.blockDaaScore, "isCoinbase": false,
                    "covenantId": Kusdt.hex(deployment.covenantId),
                ] as [String: Any],
                "state": stateJSON(coin.state),
                "secretKey": secretHex,
            ]
        }
        // All of the address's kUSDT goes (no change coin): with no KAS here to pay the fee, it comes
        // out of the KAS that travels with the tokens (kusdt-open `feeFromTokenKas`).
        let wholeSend = outputs.count == 1
        var feeFromTokenKas = false

        var n = 0
        var covered: UInt64 = 0
        let margin: UInt64 = 50_000_000
        while n < funding.count && covered < need + margin {
            covered += funding[n].amount
            n += 1
        }
        let available = funding.reduce(UInt64(0)) { $0 + $1.amount }
        /// what to add so the send can go: what it needs, a fee margin, less what's there (0.1 KAS at least)
        func shortfall() -> UInt64 {
            let target = need + fundingFeeMargin
            let short = target > available ? target - available : 0
            let rounded = (max(short, 10_000_000) + 999_999) / 1_000_000 * 1_000_000
            return rounded
        }
        if n == 0 && need > 0 { throw Failure.notEnoughKas(short: shortfall(), forChangeCoin: !wholeSend) }

        var built: [String: Any]?
        var tokenKasFees: [UInt64] = [2_000_000, 5_000_000, 10_000_000, 19_000_000]
        if wholeSend && funding.isEmpty {
            feeFromTokenKas = true
            n = 0
        }
        for _ in 0..<16 {
            if feeFromTokenKas {
                // the fee taken from the coins' own KAS, the least that does; under the builder's 0.2 KAS
                // change floor, so nothing comes back as change
                guard let take = tokenKasFees.first, kasIn > take else {
                    throw Failure.notEnoughKas(short: shortfall(), forChangeCoin: false)
                }
                tokenKasFees.removeFirst()
                outputs[0].value = kasIn - take
            }
            let outputsJSON: [[String: Any]] = outputs.map { ["state": stateJSON($0.state), "value": $0.value] }
            let fundingJSON: [[String: Any]] = funding.prefix(n).map { u in
                [
                    "utxo": [
                        "transactionId": u.outpoint.transactionId.lowercased(), "index": u.outpoint.index, "amount": u.amount,
                        "scriptPublicKey": "0000" + Kusdt.hex(u.scriptPublicKey),
                        "blockDaaScore": u.blockDaaScore, "isCoinbase": false,
                    ] as [String: Any],
                    "secretKey": secretHex,
                ]
            }
            let request: [String: Any] = [
                "network": network, "feerate": feerate, "changeAddress": holding.address,
                "funding": fundingJSON, "inputs": inputsJSON, "outputs": outputsJSON, "redeem": [] as [Any],
            ]
            do {
                let answer = try await KusdtCore.shared.run("transfer", request: request)
                let fee = number(answer["fee"]) ?? .max
                let feeMass = number((answer["mass"] as? [String: Any])?["feeMass"]) ?? 0
                let absorbed = fee > feeMass * feerate ? fee - feeMass * feerate : 0
                if !feeFromTokenKas && absorbed > absorbLimit && n < funding.count { n += 1; continue }
                built = answer
                break
            } catch KusdtCore.CoreError.refused(let why) {
                // the builder wants more KAS, or its fee didn't settle at this change: one more coin
                if why.contains("add funding") || why.contains("fee did not settle") {
                    if feeFromTokenKas { continue }
                    if n < funding.count { n += 1; continue }
                    // a whole send whose KAS here isn't enough either: the fee from the tokens' KAS
                    if wholeSend {
                        feeFromTokenKas = true
                        n = 0
                        continue
                    }
                    throw Failure.notEnoughKas(short: shortfall(), forChangeCoin: true)
                }
                throw KusdtCore.CoreError.refused(why)
            }
        }
        guard let built, let txid = built["txid"] as? String, txid.count == 64,
              let fee = number(built["fee"]), let transaction = built["transaction"] as? [String: Any] else {
            throw Failure.checkFailed
        }
        guard fee <= maxFee else { throw Failure.feeTooHigh }

        // 4. what was built is what was approved
        guard let builtOutputs = built["outputs"] as? [[String: Any]] else { throw Failure.checkFailed }
        let mine = "0000" + Kusdt.hex(KachatNames.Codec.p2pkScript(senderKey))
        for (index, output) in builtOutputs.enumerated() {
            let script = (output["scriptPublicKey"] as? String)?.lowercased() ?? ""
            if index < outputs.count {
                let expected = outputs[index]
                guard let token = output["token"] as? [String: Any], sameState(token, expected.state),
                      number(output["value"]) == expected.value,
                      script == "0000" + Kusdt.hex(Kusdt.lockingScript(expected.state, template: template)) else {
                    throw Failure.checkFailed
                }
            } else if script != mine {
                throw Failure.checkFailed
            }
        }
        let mass = number((built["mass"] as? [String: Any])?["storage"]) ?? 0
        let rpc = try rpcTransaction(transaction, storageMass: mass)
        return Prepared(txid: txid.lowercased(), fee: fee, kasToRecipient: outputs[0].value, rpc: rpc,
                        spentCoins: picked, changeIndex: outputs.count > 1 ? 1 : nil, holding: holding,
                        recipient: recipient, amount: amount,
                        feeFromTokenKas: feeFromTokenKas)
    }

    // MARK: Send

    /// Sends a prepared transfer; answers its id. The node pool holds every coin it spends, and a
    /// node whose answer is lost is looked up by id before anything fails, so it never sends twice.
    static func send(_ prepared: Prepared) async throws -> String {
        let (txid, endpoint) = try await NodePoolService.shared.submitRpcTransaction(prepared.rpc, expectedTxId: prepared.txid)
        AppLog.log("[kUSDT] sent %@ via %@", String(txid.prefix(12)), endpoint)
        TokenWallet.shared.noteSent(prepared)
        return txid
    }

    // MARK: JSON

    private static func stateJSON(_ s: Kusdt.State) -> [String: Any] {
        [
            "amount": s.amount, "owner": Kusdt.hex(s.owner), "ownerScheme": s.ownerScheme,
            "borrowScheme": s.borrowScheme, "borrowGuard": Kusdt.hex(s.borrowGuard),
            "extensionCommitment": Kusdt.hex(s.extensionCommitment),
        ]
    }

    private static func sameState(_ j: [String: Any], _ s: Kusdt.State) -> Bool {
        number(j["amount"]) == s.amount
            && (j["owner"] as? String)?.lowercased() == Kusdt.hex(s.owner)
            && number(j["ownerScheme"]) == UInt64(s.ownerScheme)
            && (number(j["borrowScheme"]) ?? 0) == UInt64(s.borrowScheme)
            && (j["borrowGuard"] as? String)?.lowercased() == Kusdt.hex(s.borrowGuard)
            && (j["extensionCommitment"] as? String)?.lowercased() == Kusdt.hex(s.extensionCommitment)
    }

    /// A non-negative integer from a JSON number or a string of digits.
    private static func number(_ v: Any?) -> UInt64? {
        if let s = v as? String { return UInt64(s) }
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.int64Value >= 0 { return n.uint64Value }
        return nil
    }

    /// The builder's transaction (the node's JSON form) as the gRPC submit takes it, with the
    /// storage mass filled in as KaPay's other version-1 transactions do (the id doesn't cover it).
    private static func rpcTransaction(_ t: [String: Any], storageMass: UInt64) throws -> Protowire_RpcTransaction {
        func hexData(_ v: Any?) throws -> Data {
            guard let s = v as? String, let d = Kusdt.unhexOrNil(s) else { throw Failure.checkFailed }
            return d
        }
        guard let version = number(t["version"]),
              let inputs = t["inputs"] as? [[String: Any]], let outputs = t["outputs"] as? [[String: Any]] else {
            throw Failure.checkFailed
        }
        var r = Protowire_RpcTransaction()
        r.version = UInt32(version)
        r.inputs = try inputs.map { i in
            guard let op = i["previousOutpoint"] as? [String: Any],
                  let txid = op["transactionId"] as? String, let index = number(op["index"]) else { throw Failure.checkFailed }
            var input = Protowire_RpcTransactionInput()
            var outpoint = Protowire_RpcOutpoint()
            outpoint.transactionID = txid.lowercased()
            outpoint.index = UInt32(index)
            input.previousOutpoint = outpoint
            input.signatureScript = Kusdt.hex(try hexData(i["signatureScript"]))
            input.sequence = number(i["sequence"]) ?? 0
            input.sigOpCount = UInt32(number(i["sigOpCount"]) ?? 0)
            input.computeBudget = UInt32(number(i["computeBudget"]) ?? 0)
            return input
        }
        r.outputs = try outputs.map { o in
            let spk = try hexData(o["scriptPublicKey"])
            guard spk.count >= 2, let value = number(o["value"]) else { throw Failure.checkFailed }
            var output = Protowire_RpcTransactionOutput()
            output.amount = value
            var script = Protowire_RpcScriptPublicKey()
            script.version = UInt32(spk[spk.startIndex]) << 8 | UInt32(spk[spk.startIndex + 1])
            script.scriptPublicKey = Kusdt.hex(spk.dropFirst(2))
            output.scriptPublicKey = script
            if let c = o["covenant"] as? [String: Any] {
                var binding = Protowire_RpcCovenantBinding()
                binding.authorizingInput = UInt32(number(c["authorizingInput"]) ?? 0)
                binding.covenantID = ((c["covenantId"] as? String) ?? "").lowercased()
                output.covenant = binding
            }
            return output
        }
        r.lockTime = number(t["lockTime"]) ?? 0
        r.subnetworkID = ((t["subnetworkId"] as? String) ?? String(repeating: "0", count: 40)).lowercased()
        r.gas = number(t["gas"]) ?? 0
        r.payload = ((t["payload"] as? String) ?? "").lowercased()
        r.storageMass = storageMass
        return r
    }
}
