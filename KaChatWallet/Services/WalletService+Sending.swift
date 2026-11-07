import Foundation

// MARK: - Sending: plain KAS transfers from the chatting address and the spending addresses

extension WalletService {

    func enqueueOutgoingTxOperation<T>(
        _ operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let previous = outgoingTxTail
        let operationTask = Task<T, Error> { @MainActor in
            if let previous {
                await previous.value
            }
            return try await operation()
        }
        outgoingTxTail = Task<Void, Never> { @MainActor in
            _ = try? await operationTask.value
        }
        return try await operationTask.value
    }

    /// Sends a plain KAS transfer from the wallet's identity address to an arbitrary
    /// recipient address (Profile > Chatting Address > Withdraw Kaspa). Unlike sendPayment,
    /// this carries no KaChat protocol payload and no extra bookkeeping
    /// (pending message, delivery status, etc.) since the recipient isn't necessarily a
    /// contact. Returns the submitted transaction id.
    /// `expectedFeeSompi`: the fee the Review showed. A send built at the swipe that would pay more
    /// (its coins changed since the Review) throws `SendFeeChangedError` and sends nothing.
    func sendWithdrawal(toAddress: String, amountSompi: UInt64, manualUtxos: [UTXO]? = nil, extraFeeSompi: UInt64 = 0, expectedFeeSompi: UInt64? = nil) async throws -> String {
        guard amountSompi > 0 else {
            throw KasiaError.networkError("Amount must be greater than zero")
        }
        guard KaspaAddress.scriptPublicKey(from: toAddress) != nil else {
            throw KasiaError.invalidAddress
        }
        // the script ignores the prefix: a kaspatest: address on mainnet would pay real KAS
        if let reason = KaspaAddress.otherNetworkReason(toAddress) { throw KasiaError.networkError(reason) }
        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }
        guard let privateKey = WalletManager.shared.getPrivateKey() else {
            throw KasiaError.keychainError("Could not get private key")
        }

        return try await enqueueOutgoingTxOperation {
            let rpcManager = NodePoolService.shared
            let settings = self.currentSettings

            if !rpcManager.isConnected {
                try await rpcManager.connect(network: settings.networkType)
            }

            let utxos = try await rpcManager.getUtxosByAddresses([wallet.publicAddress])
            self.updateWalletBalanceIfNeeded(address: wallet.publicAddress, utxos: utxos)
            let spendable = self.withdrawalSpendable(utxos)
            guard !spendable.isEmpty else {
                throw KasiaError.networkError("No spendable UTXOs available")
            }

            // Coin control passes back whichever UTXOs the user picked in the picker sheet,
            // which may be stale by the time the send actually fires - re-resolve by outpoint
            // against the fresh `spendable` fetch above rather than trusting the picker's
            // snapshot outright. Same pattern as sendFromSpendingAddress.
            var resolvedManualUtxos: [UTXO]?
            if let manualUtxos, !manualUtxos.isEmpty {
                func outpointKey(_ utxo: UTXO) -> String { "\(utxo.outpoint.transactionId):\(utxo.outpoint.index)" }
                let spendableByOutpoint = Dictionary(uniqueKeysWithValues: spendable.map { (outpointKey($0), $0) })
                let resolved = manualUtxos.compactMap { spendableByOutpoint[outpointKey($0)] }
                guard !resolved.isEmpty else {
                    throw KasiaError.networkError("Selected UTXOs are no longer available - please reselect")
                }
                resolvedManualUtxos = resolved
            }

            let tx = try KasiaTransactionBuilder.buildPlainTransferTx(
                from: wallet.publicAddress,
                to: toAddress,
                amount: amountSompi,
                senderPrivateKey: privateKey,
                utxos: spendable,
                manualUtxos: resolvedManualUtxos,
                extraFeeSompi: extraFeeSompi
            )
            try self.checkFeeAgainstReview(tx, spending: spendable, expectedFeeSompi: expectedFeeSompi)

            AppLog.log("[WalletService] Submitting withdrawal via RPC manager...")
            let txId: String
            let endpoint: String
            do {
                (txId, endpoint) = try await rpcManager.submitTransaction(tx, allowOrphan: false)
            } catch let unknown as SendOutcomeUnknownError {
                // it may have landed: its coins stay out of the next send
                self.recordSpend(tx)
                throw unknown
            }
            AppLog.log("[WalletService] Withdrawal submitted: \(txId) via \(endpoint)")
            self.recordSpend(tx)
            return txId
        }
    }

    /// Estimates the total fee (base + optional priority tip) for a withdrawal, without
    /// requiring a gRPC connection (uses the same REST-fallback UTXO fetch as other fee
    /// previews, since this only needs read access for the estimate).
    func estimateWithdrawalFee(toAddress: String, amountSompi: UInt64, manualUtxos: [UTXO]? = nil, extraFeeSompi: UInt64 = 0) async throws -> SendFeeEstimate {
        guard amountSompi > 0 else { throw KasiaError.networkError("Amount is zero") }
        guard let wallet = WalletManager.shared.currentWallet else { throw KasiaError.walletNotFound }
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress),
              let recipientScriptPubKey = KaspaAddress.scriptPublicKey(from: toAddress) else {
            throw KasiaError.invalidAddress
        }

        let spendable = try await withdrawalSpendableUtxos(for: wallet.publicAddress)
        guard !spendable.isEmpty else {
            throw KasiaError.networkError("No spendable UTXOs")
        }
        let resolvedManualUtxos = try resolveReviewSelection(manualUtxos, against: spendable)

        return try KasiaTransactionBuilder.estimatePlainTransferFee(
            utxos: spendable,
            amount: amountSompi,
            recipientScriptPubKey: recipientScriptPubKey,
            senderScriptPubKey: senderScriptPubKey,
            manualUtxos: resolvedManualUtxos,
            extraFeeSompi: extraFeeSompi
        )
    }

    /// Maximum sendable amount for a withdrawal (balance minus the send-all fee, no change
    /// output). With
    /// [manualUtxos] set (coin control active), "max" means max spendable from just that
    /// selected subset - same semantics as estimateMaxSpendingAddressAmount. An address with more
    /// coins than one transaction can spend gets the most its largest `maxInputsPerTransaction`
    /// coins can send (what the send itself picks, largest first): no single transaction could
    /// carry the whole balance (`cappedAtInputLimit`, which the screen says). Compound uses this
    /// too, one chunk at a time.
    /// `feeMultiplier`: the speed tier (Fast 2, Priority 5). Its extra is worked out from the base
    /// fee of the send this Max builds, as the Review does (`maxSendAmount`); `extraFeeSompi` is a
    /// fixed extra on top (a custom fee).
    func estimateMaxWithdrawalAmount(toAddress: String, manualUtxos: [UTXO]? = nil, extraFeeSompi: UInt64 = 0, feeMultiplier: UInt64 = 1) async throws -> (amountSompi: UInt64, cappedAtInputLimit: Bool) {
        guard let wallet = WalletManager.shared.currentWallet else { throw KasiaError.walletNotFound }
        guard let recipientScriptPubKey = KaspaAddress.scriptPublicKey(from: toAddress),
              let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress) else {
            throw KasiaError.invalidAddress
        }

        let spendable = try await withdrawalSpendableUtxos(for: wallet.publicAddress)
        guard !spendable.isEmpty else {
            throw KasiaError.networkError("No spendable UTXOs")
        }
        let resolvedManualUtxos = try resolveReviewSelection(manualUtxos, against: spendable)
        let chunk = resolvedManualUtxos == nil ? Self.oneTransactionChunk(spendable) : nil
        let maxSet = resolvedManualUtxos ?? chunk ?? spendable

        let totalBalance = try maxSet.totalAmount()

        let amount = try Self.maxSendAmount(
            total: totalBalance,
            extraFeeSompi: extraFeeSompi,
            feeMultiplier: feeMultiplier,
            sendAllFee: { extra in
                KasiaTransactionBuilder.estimateSendAllFee(
                    utxos: maxSet,
                    payload: Data(),
                    recipientScriptPubKey: recipientScriptPubKey,
                    senderScriptPubKey: senderScriptPubKey,
                    extraFeeSompi: extra
                )
            },
            baseFee: { sompi in
                // the Review's Normal fee for this amount (`estimateWithdrawalFee` with no extra)
                (try? KasiaTransactionBuilder.estimatePlainTransferFee(
                    utxos: spendable,
                    amount: sompi,
                    recipientScriptPubKey: recipientScriptPubKey,
                    senderScriptPubKey: senderScriptPubKey,
                    manualUtxos: resolvedManualUtxos
                ))?.networkFee
            }
        )

        return (amount, chunk != nil)
    }

    /// Max at a speed tier. The Review prices a send's tier extra as a share of that same send's
    /// base (Normal) fee, so Max does too: worked out at one extra, then again at the extra the
    /// resulting amount's base fee gives, until the two agree. A tier extra taken from another
    /// amount's base fee (a typed amount, other coins) was too small for Max's own inputs, and
    /// the Review then could not price the Max at all ("Insufficient funds").
    static func maxSendAmount(
        total: UInt64,
        extraFeeSompi: UInt64,
        feeMultiplier: UInt64,
        sendAllFee: (UInt64) -> UInt64,
        baseFee: (UInt64) -> UInt64?
    ) throws -> UInt64 {
        func amount(extra: UInt64) throws -> UInt64 {
            let fee = sendAllFee(extra)
            guard total > fee else {
                throw KasiaError.networkError("Balance too low to cover fee")
            }
            return total - fee
        }
        var extra = extraFeeSompi
        var result = try amount(extra: extra)
        guard feeMultiplier > 1 else { return result }
        // two rounds settle it; the cap only guards against a shape that flips back and forth
        for _ in 0..<4 {
            guard let base = baseFee(result) else { break }
            let next = extraFeeSompi + base * (feeMultiplier - 1)
            if next == extra { break }
            extra = next
            result = try amount(extra: extra)
        }
        return result
    }

    /// Sends a plain KAS transfer from a specific spending-chain address (Manage Addresses'
    /// per-row Withdraw action).
    ///
    /// For a NON-primary index the change stays on the same address: that is a scoped,
    /// explicit single-address operation, and the row's own balance is what the user is
    /// managing. The primary is different. A send from it puts its change on a fresh index and
    /// rotates the primary to that index, so the address
    /// you spend from and hand out next has never been used before. This path used to leave
    /// the primary sitting on the address it had just spent from. The old primary keeps
    /// whatever it still holds, listed in Manage Addresses like any other revealed slot.
    func sendFromSpendingAddress(index: Int, toAddress: String, amountSompi: UInt64, manualUtxos: [UTXO]? = nil, extraFeeSompi: UInt64 = 0, expectedFeeSompi: UInt64? = nil) async throws -> String {
        // the account this send belongs to: what it writes after the network answers goes here,
        // even if another account is active by then (IOS-109)
        let owner = WalletManager.shared.currentWallet?.publicAddress
        guard amountSompi > 0 else {
            throw KasiaError.networkError("Amount must be greater than zero")
        }
        guard KaspaAddress.scriptPublicKey(from: toAddress) != nil else {
            throw KasiaError.invalidAddress
        }
        // the script ignores the prefix: a kaspatest: address on mainnet would pay real KAS
        if let reason = KaspaAddress.otherNetworkReason(toAddress) { throw KasiaError.networkError(reason) }
        guard let fromAddress = WalletManager.shared.spendingAddress(at: index),
              let privateKey = WalletManager.shared.spendingPrivateKey(at: index) else {
            throw KasiaError.keychainError("Could not derive this spending address")
        }
        // Fresh change index for the primary only: past the all-time max, so it has never been
        // revealed, funded or offered (the same rule `sendPaymentInternal` uses). Decided up
        // front and applied only after the node accepts the transaction, so a failed send moves
        // nothing. If the fresh address cannot be derived this instant, change stays put and
        // the primary stays put with it - rotating onto an address the change did not reach
        // would strand the funds behind a pointer. A self-send (the Compound action) moves
        // nothing out of the address, so it neither splits its consolidation onto a fresh
        // address nor rotates.
        var freshChangeIndex: Int?
        var changeAddress: String?
        let isSelfSend = toAddress.lowercased() == fromAddress.lowercased()
        // A quantum source's change must NEVER return to it - the spend reveals its key, and
        // change back would park funds on a revealed address (KIP-22). A legacy primary keeps
        // rotating as before; both rotate onto a fresh quantum slot now. A self-send (Compound)
        // still consolidates into the address itself, shield off.
        if !isSelfSend, WalletManager.isQuantumIndex(index) || index == WalletManager.shared.currentSpendingAddressIndex {
            if let slot = await WalletManager.shared.verifiedFreshQuantumSlot() {
                freshChangeIndex = slot.index
                changeAddress = slot.address
            } else if WalletManager.isQuantumIndex(index) {
                // never change back onto the key this spend reveals (IOS-104)
                throw KasiaError.keychainError(AppLocalization.string("Couldn't prepare the next address. Try again."))
            }
        }

        return try await enqueueOutgoingTxOperation {
            let rpcManager = NodePoolService.shared
            let settings = self.currentSettings

            if !rpcManager.isConnected {
                try await rpcManager.connect(network: settings.networkType)
            }

            let utxos = try await rpcManager.getUtxosByAddresses([fromAddress])
            // Spendable = non-coinbase + matured coinbase (mining rewards). The old `!isCoinbase`
            // gate dropped every coinbase UTXO, which is why compounding/withdrawing a mining
            // address failed with a bare "No spendable UTXOs".
            let vds = await self.resolveVirtualDaaScore(nil, utxos: utxos)
            var spendable = self.unreservedUtxos(WalletService.spendableUtxos(utxos, virtualDaaScore: vds))
            if spendable.isEmpty, let manualUtxos, !manualUtxos.isEmpty {
                // The fresh fetch came back empty (transient pool/node condition) but the caller
                // pinned an explicit set (e.g. a compound chunk) - fall back to it; the node will
                // reject any of those inputs that were actually already spent.
                spendable = self.unreservedUtxos(WalletService.spendableUtxos(manualUtxos, virtualDaaScore: vds))
            }
            guard !spendable.isEmpty else {
                throw KasiaError.networkError("No spendable UTXOs available")
            }

            // Coin control passes back whichever UTXOs the user picked in the picker sheet,
            // which may be stale by the time the send actually fires (spent by another device,
            // aged out, etc.) - re-resolve by outpoint against the fresh `spendable` fetch above
            // rather than trusting the picker's snapshot outright.
            var resolvedManualUtxos: [UTXO]?
            if let manualUtxos, !manualUtxos.isEmpty {
                func outpointKey(_ utxo: UTXO) -> String { "\(utxo.outpoint.transactionId):\(utxo.outpoint.index)" }
                let spendableByOutpoint = Dictionary(uniqueKeysWithValues: spendable.map { (outpointKey($0), $0) })
                let resolved = manualUtxos.compactMap { spendableByOutpoint[outpointKey($0)] }
                guard !resolved.isEmpty else {
                    throw KasiaError.networkError("Selected UTXOs are no longer available - please reselect")
                }
                resolvedManualUtxos = resolved
            }

            var senderRedeemScript: Data?
            if WalletManager.isQuantumIndex(index) {
                guard let redeem = WalletManager.shared.quantumRedeemScript(at: index) else {
                    throw KasiaError.keychainError("Could not derive the quantum address's key")
                }
                senderRedeemScript = redeem
            }
            let tx = try KasiaTransactionBuilder.buildPlainTransferTx(
                from: fromAddress,
                to: toAddress,
                amount: amountSompi,
                senderPrivateKey: privateKey,
                utxos: spendable,
                manualUtxos: resolvedManualUtxos,
                extraFeeSompi: extraFeeSompi,
                changeAddress: changeAddress,
                virtualDaaScore: vds,
                senderRedeemScript: senderRedeemScript
            )
            try self.checkFeeAgainstReview(tx, spending: spendable, expectedFeeSompi: expectedFeeSompi)

            AppLog.log("[WalletService] Submitting spending-address withdrawal via RPC manager...")
            @MainActor func noteSpend() async {
                // its coins stay out of the next send from this address until the spend is in a block
                self.recordSpend(tx)
                if WalletManager.isQuantumIndex(index) {
                    // the spend put this address's key on chain for good (self-sends included)
                    await WalletManager.shared.markQuantumAddressSpent(fromAddress, owner: owner)
                }
                if let freshChangeIndex {
                    // The primary follows its change onto the fresh address. Manage Addresses
                    // listens for this and moves its star at once.
                    await WalletManager.shared.setActiveSpendingAddress(freshChangeIndex, owner: owner)
                }
            }
            do {
                let (txId, endpoint) = try await rpcManager.submitTransaction(tx, allowOrphan: false)
                AppLog.log("[WalletService] Spending-address withdrawal submitted: \(txId) via \(endpoint)")
                await noteSpend()
                return txId
            } catch let unknown as SendOutcomeUnknownError {
                // It may have landed: its change has to stay visible, and a quantum source counts as spent.
                await noteSpend()
                throw unknown
            }
        }
    }

    /// Kaspa coinbase (mining-reward) maturity, in DAA-score units: a coinbase UTXO is only
    /// spendable once `blockDaaScore + coinbaseMaturity < virtualDaaScore`. Matches Kaspa consensus
    /// and Kaspium (which uses the same 1000).
    static let coinbaseMaturity: UInt64 = 1000

    /// Filters a UTXO set to what's actually spendable *right now*. Non-coinbase UTXOs always are;
    /// coinbase (mining rewards) only once matured against `virtualDaaScore`. When the score is
    /// unknown (nil) coinbase is included and the node arbitrates - better than silently hiding a
    /// mining balance. This is why an address full of coinbase UTXOs used to fail every send/
    /// compound with a bare "No spendable UTXOs" (the old `!isCoinbase` filter dropped them all).
    static func spendableUtxos(_ utxos: [UTXO], virtualDaaScore: UInt64?) -> [UTXO] {
        utxos.filter { utxo in
            guard utxo.isCoinbase else { return true }
            guard let vds = virtualDaaScore else { return true }
            // overflow (a nonsense DAA score from a node) counts as not yet mature
            let (matureAt, overflow) = utxo.blockDaaScore.addingReportingOverflow(coinbaseMaturity)
            return !overflow && matureAt < vds
        }
    }

    /// Resolves the virtual DAA score needed for coinbase-maturity checks, fetching it from the
    /// pool only when it matters (the UTXO set actually contains coinbase). Non-mining addresses
    /// - the common case - never pay for a network round trip.
    func resolveVirtualDaaScore(_ provided: UInt64?, utxos: [UTXO]) async -> UInt64? {
        if let provided { return provided }
        guard utxos.contains(where: { $0.isCoinbase }) else { return nil }
        return await NodePoolService.shared.currentVirtualDaaScore()
    }

    /// The largest set of UTXOs that fit in a single mass-safe transaction (up to
    /// `KasiaTransactionBuilder.maxInputsPerTransaction`, largest-first), plus the max self-send
    /// amount for exactly that set. Kaspa caps a transaction's mass (~89 inputs), so the compound
    /// UI's "Max" uses this to reflect *one transaction's worth* of consolidatable value instead of
    /// the whole (over-mass) balance - the user consolidates that chunk, then repeats to reduce
    /// further. Returns the chunk so the send spends exactly those inputs.
    func maxConsolidatableChunk(index: Int, extraFeeSompi: UInt64 = 0, feeMultiplier: UInt64 = 1, availableUtxos: [UTXO] = []) async throws -> (amountSompi: UInt64, utxos: [UTXO]) {
        guard let fromAddress = WalletManager.shared.spendingAddress(at: index) else {
            throw KasiaError.keychainError("Could not derive this spending address")
        }
        // Prefer the UTXOs the caller already loaded for this address (exactly what the user sees
        // in the list) so the estimate never depends on a second pooled fetch that can transiently
        // come back empty while the first succeeded. Only fetch (with one retry) if none supplied.
        var utxos = availableUtxos
        if utxos.isEmpty {
            let rpcManager = NodePoolService.shared
            if !rpcManager.isConnected {
                try await rpcManager.connect(network: currentSettings.networkType)
            }
            utxos = try await rpcManager.getUtxosByAddresses([fromAddress])
            if utxos.isEmpty {
                utxos = try await rpcManager.getUtxosByAddresses([fromAddress])
            }
        }
        // Spendable = non-coinbase (always) + matured coinbase. A pure `!isCoinbase` gate is what
        // broke compounding on mining-reward addresses: it dropped every one of their coinbase
        // UTXOs. Fetch the virtual DAA score only when coinbase is actually present.
        let virtualDaaScore = await resolveVirtualDaaScore(nil, utxos: utxos)
        let spendable = unreservedUtxos(WalletService.spendableUtxos(utxos, virtualDaaScore: virtualDaaScore))
        guard !spendable.isEmpty else {
            if utxos.contains(where: { $0.isCoinbase }) {
                throw KasiaError.networkError("These are mining (coinbase) rewards that haven't matured yet. Each becomes spendable a short time (about 1–2 minutes) after it's mined - try again shortly.")
            }
            throw KasiaError.networkError("No spendable UTXOs available")
        }
        // Largest-first, capped to what fits one transaction's mass.
        let chunk = Array(spendable.sorted { $0.amount > $1.amount }.prefix(KasiaTransactionBuilder.maxInputsPerTransaction))
        let amount = try await estimateMaxSpendingAddressAmount(index: index, toAddress: fromAddress, manualUtxos: chunk, extraFeeSompi: extraFeeSompi, feeMultiplier: feeMultiplier, availableUtxos: utxos, virtualDaaScore: virtualDaaScore).amountSompi
        return (amount, chunk)
    }

    /// Estimates the total fee for a spending-address withdrawal. Calls NodePoolService
    /// directly rather than fetchUtxosWithFallback, whose single-address UTXO cache would
    /// return the wrong address's data when estimating for anything but the identity address.
    func estimateSpendingAddressWithdrawalFee(index: Int, toAddress: String, amountSompi: UInt64, manualUtxos: [UTXO]? = nil, extraFeeSompi: UInt64 = 0, availableUtxos: [UTXO] = [], virtualDaaScore: UInt64? = nil) async throws -> SendFeeEstimate {
        guard amountSompi > 0 else { throw KasiaError.networkError("Amount is zero") }
        guard let fromAddress = WalletManager.shared.spendingAddress(at: index) else {
            throw KasiaError.keychainError("Could not derive this spending address")
        }
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: fromAddress),
              let recipientScriptPubKey = KaspaAddress.scriptPublicKey(from: toAddress) else {
            throw KasiaError.invalidAddress
        }

        let utxos = availableUtxos.isEmpty ? try await NodePoolService.shared.getUtxosByAddresses([fromAddress]) : availableUtxos
        let vds = await resolveVirtualDaaScore(virtualDaaScore, utxos: utxos)
        // the send leaves out coins just spent, so the estimate does too
        let spendable = unreservedUtxos(WalletService.spendableUtxos(utxos, virtualDaaScore: vds))
        guard !spendable.isEmpty else {
            throw KasiaError.networkError("No spendable UTXOs")
        }
        let resolvedManualUtxos = try resolveReviewSelection(manualUtxos, against: spendable)

        return try KasiaTransactionBuilder.estimatePlainTransferFee(
            utxos: spendable,
            amount: amountSompi,
            recipientScriptPubKey: recipientScriptPubKey,
            senderScriptPubKey: senderScriptPubKey,
            manualUtxos: resolvedManualUtxos,
            extraFeeSompi: extraFeeSompi,
            virtualDaaScore: vds,
            signatureScriptSize: WalletManager.isQuantumIndex(index)
                ? KasiaTransactionBuilder.kip22SignatureScriptSize : 66
        )
    }

    /// Maximum sendable amount from a specific spending address (balance minus the send-all
    /// fee, no change output). With coin control active (`manualUtxos` non-empty and still
    /// resolvable), "max" means max spendable from just the selected UTXOs, not the whole
    /// address - same semantics `KasiaTransactionBuilder.estimateSendAllFee` already applies.
    /// More coins than one transaction can spend: the most its largest coins can send, as in
    /// `estimateMaxWithdrawalAmount` (`cappedAtInputLimit`). `feeMultiplier` as there too.
    func estimateMaxSpendingAddressAmount(index: Int, toAddress: String, manualUtxos: [UTXO]? = nil, extraFeeSompi: UInt64 = 0, feeMultiplier: UInt64 = 1, availableUtxos: [UTXO] = [], virtualDaaScore: UInt64? = nil) async throws -> (amountSompi: UInt64, cappedAtInputLimit: Bool) {
        guard let fromAddress = WalletManager.shared.spendingAddress(at: index) else {
            throw KasiaError.keychainError("Could not derive this spending address")
        }
        guard let recipientScriptPubKey = KaspaAddress.scriptPublicKey(from: toAddress),
              let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: fromAddress) else {
            throw KasiaError.invalidAddress
        }

        let utxos = availableUtxos.isEmpty ? try await NodePoolService.shared.getUtxosByAddresses([fromAddress]) : availableUtxos
        let vds = await resolveVirtualDaaScore(virtualDaaScore, utxos: utxos)
        // the send leaves out coins just spent, so the estimate does too
        let spendable = unreservedUtxos(WalletService.spendableUtxos(utxos, virtualDaaScore: vds))
        guard !spendable.isEmpty else {
            throw KasiaError.networkError("No spendable UTXOs")
        }
        let resolvedManualUtxos = try resolveReviewSelection(manualUtxos, against: spendable)
        let chunk = resolvedManualUtxos == nil ? Self.oneTransactionChunk(spendable) : nil
        let maxSet = resolvedManualUtxos ?? chunk ?? spendable

        let totalBalance = try maxSet.totalAmount()
        let signatureScriptSize = WalletManager.isQuantumIndex(index)
            ? KasiaTransactionBuilder.kip22SignatureScriptSize : 66

        let amount = try Self.maxSendAmount(
            total: totalBalance,
            extraFeeSompi: extraFeeSompi,
            feeMultiplier: feeMultiplier,
            sendAllFee: { extra in
                KasiaTransactionBuilder.estimateSendAllFee(
                    utxos: maxSet,
                    payload: Data(),
                    recipientScriptPubKey: recipientScriptPubKey,
                    senderScriptPubKey: senderScriptPubKey,
                    extraFeeSompi: extra,
                    virtualDaaScore: vds,
                    signatureScriptSize: signatureScriptSize
                )
            },
            baseFee: { sompi in
                // the Review's Normal fee for this amount (`estimateSpendingAddressWithdrawalFee`)
                (try? KasiaTransactionBuilder.estimatePlainTransferFee(
                    utxos: spendable,
                    amount: sompi,
                    recipientScriptPubKey: recipientScriptPubKey,
                    senderScriptPubKey: senderScriptPubKey,
                    manualUtxos: resolvedManualUtxos,
                    virtualDaaScore: vds,
                    signatureScriptSize: signatureScriptSize
                ))?.networkFee
            }
        )

        return (amount, chunk != nil)
    }

    /// Coin control for a Review's fee or Max: the picked coins that are still spendable, nil for
    /// automatic. When none of the picked coins are left it throws the send's own error, rather
    /// than estimating automatic selection for a send that would then refuse to go.
    private func resolveReviewSelection(_ manualUtxos: [UTXO]?, against spendable: [UTXO]) throws -> [UTXO]? {
        guard let manualUtxos, !manualUtxos.isEmpty else { return nil }
        guard let resolved = resolveManualUtxos(manualUtxos, against: spendable) else {
            throw KasiaError.networkError("Selected UTXOs are no longer available - please reselect")
        }
        return resolved
    }

    /// Within this of the Review's fee a rebuilt send still goes out.
    static let reviewFeeMarginSompi: UInt64 = 1_000

    /// A send is built again at the swipe, from the coins of that moment. If they changed since
    /// the Review (another send spent one, a coin arrived) it can pick other coins and pay more,
    /// change too small to keep included: then nothing is sent and the Review shows the new fee.
    func checkFeeAgainstReview(_ tx: KaspaRpcTransaction, spending candidates: [UTXO], expectedFeeSompi: UInt64?) throws {
        guard let expectedFeeSompi else { return }
        let byOutpoint = Dictionary(candidates.map { (Self.outpointKey($0.outpoint), $0.amount) }, uniquingKeysWith: { a, _ in a })
        let inputs = tx.inputs.compactMap { byOutpoint[Self.outpointKey($0.previousOutpoint)] }
        guard inputs.count == tx.inputs.count else { return }
        let inTotal = inputs.reduce(UInt64(0), +)
        let outTotal = tx.outputs.reduce(UInt64(0)) { $0 + $1.value }
        guard inTotal >= outTotal else { return }
        let fee = inTotal - outTotal
        if fee > expectedFeeSompi + Self.reviewFeeMarginSompi {
            AppLog.log("[WalletService] send would pay \(fee) sompi, the Review showed \(expectedFeeSompi): not sent")
            throw SendFeeChangedError(feeSompi: fee)
        }
    }

    /// Re-resolves a coin-control selection by outpoint against a freshly-fetched spendable
    /// list, since the selection may be stale by the time a fee/max preview or the actual send
    /// runs (spent by another device, aged out, etc.). Returns nil (fall back to automatic
    /// selection) if nothing manual was passed, or if every previously-selected UTXO is gone -
    /// callers that need to distinguish "gone" from "never selected" (i.e. the actual send,
    /// where silently falling back to automatic would spend UTXOs the user didn't choose) do
    /// their own stricter check instead of using this helper - see `sendFromSpendingAddress`.
    private func resolveManualUtxos(_ manualUtxos: [UTXO]?, against spendable: [UTXO]) -> [UTXO]? {
        guard let manualUtxos, !manualUtxos.isEmpty else { return nil }
        func outpointKey(_ utxo: UTXO) -> String { "\(utxo.outpoint.transactionId):\(utxo.outpoint.index)" }
        let spendableByOutpoint = Dictionary(uniqueKeysWithValues: spendable.map { (outpointKey($0), $0) })
        let resolved = manualUtxos.compactMap { spendableByOutpoint[outpointKey($0)] }
        return resolved.isEmpty ? nil : resolved
    }

    /// The largest `maxInputsPerTransaction` coins, when there are more than one transaction can
    /// spend; nil when every coin fits. Largest first, the order `selectUtxosForPayment` adds them
    /// in, so a Max (or Compound) worked out from this chunk is exactly what the send then builds.
    static func oneTransactionChunk(_ spendable: [UTXO]) -> [UTXO]? {
        guard spendable.count > KasiaTransactionBuilder.maxInputsPerTransaction else { return nil }
        return Array(spendable.sorted { $0.amount > $1.amount }.prefix(KasiaTransactionBuilder.maxInputsPerTransaction))
    }

    /// What a send from the chatting address may spend, fetched fresh rather than from the
    /// 20-second `fetchUtxosWithFallback` cache, and with the send's own filter, so the estimate
    /// and the send agree.
    /// What a plain send from the chatting address may spend out of `utxos`: confirmed, not mining
    /// rewards, and not just spent by this app (`unreservedUtxos`). Compound, the send's Available
    /// and Coin Control count the same coins the send does.
    func withdrawalSpendable(_ utxos: [UTXO]) -> [UTXO] {
        unreservedUtxos(utxos.filter { $0.blockDaaScore > 0 && !$0.isCoinbase })
    }

    private func withdrawalSpendableUtxos(for address: String) async throws -> [UTXO] {
        let utxos = try await NodePoolService.shared.getUtxosByAddresses([address])
        updateWalletBalanceIfNeeded(address: address, utxos: utxos)
        return withdrawalSpendable(utxos)
    }

    private static func outpointKey(_ outpoint: UTXO.Outpoint) -> String {
        "\(outpoint.transactionId):\(outpoint.index)"
    }

    /// Leaves out coins a send from this app has just spent (`reservedOutpoints`).
    func unreservedUtxos(_ utxos: [UTXO]) -> [UTXO] {
        let now = Date()
        reservedOutpoints = reservedOutpoints.filter { $0.value > now }
        guard !reservedOutpoints.isEmpty else { return utxos }
        return utxos.filter { reservedOutpoints[Self.outpointKey($0.outpoint)] == nil }
    }

    /// After a send, or one whose outcome is unknown: its inputs stay out of the next send, Max
    /// and fee for `spentOutpointHold`, and the UTXO cache, which still lists them, is dropped.
    func recordSpend(_ tx: KaspaRpcTransaction) {
        reserveOutpoints(tx.inputs.map { Self.outpointKey($0.previousOutpoint) })
    }

    /// `recordSpend` for outpoints given as "txid:index" (any transaction `NodePoolService`
    /// submits: .kas and .kachat names, profiles, combines, Cold Storage).
    func reserveOutpoints(_ keys: [String]) {
        let until = Date().addingTimeInterval(spentOutpointHold)
        for key in keys {
            reservedOutpoints[key] = until
        }
        cachedUtxos = []
        cachedUtxosTimestamp = nil
    }

    /// Whether an address has ever appeared in a transaction, independent of its current
    /// balance (a swept-to-zero address still counts as used) — powers the "Used"/"Unused"
    /// badge in Manage Addresses. A transaction-count lookup, not a balance check.
    ///
    /// "Used" is MONOTONIC and address-intrinsic: once true it can never become false again,
    /// so positive answers are cached persistently and answered without a network round-trip
    /// forever after. Negative ("unused") answers are cached ONLY for this process's lifetime
    /// (`sessionUnusedAddresses`) — an unused address can become used at any moment, but only
    /// via our own sends or an external deposit, and a deposit means a nonzero balance, which
    /// every list load short-circuits to "used" before consulting any cache. Never persisted
    /// across launches. This is what makes Manage Addresses / Address Visibility (and cold
    /// storage discovery, which shares this primitive) open instantly instead of re-deriving
    /// used-ness over the network every time.
    private static let usedAddressCacheKey = "kachat_used_addresses_v1"
    /// Session-only memory of CONFIRMED-unused probe results. In-memory by design: it must
    /// die with the process so a stale "unused" can never survive into a later launch.
    private static var sessionUnusedAddresses: Set<String> = []

    /// Cache-only, synchronous view of used-ness: `true` = persistently confirmed used,
    /// `false` = confirmed unused earlier THIS session, `nil` = no cached answer (a network
    /// probe is needed). Lets list loads label rows on the first frame without a round-trip.
    func cachedSpendingAddressUsedState(_ address: String) -> Bool? {
        let cached = UserDefaults.standard.array(forKey: Self.usedAddressCacheKey) as? [String] ?? []
        if cached.contains(address) { return true }
        if Self.sessionUnusedAddresses.contains(address) { return false }
        return nil
    }

    /// Marks an address confirmed-used without a probe — e.g. it holds a balance right now,
    /// which proves history. "Used" is monotonic, so persisting this is always safe and makes
    /// every future launch answer instantly even after the balance is swept back to zero.
    func markSpendingAddressUsed(_ address: String) {
        Self.sessionUnusedAddresses.remove(address)
        var updated = UserDefaults.standard.array(forKey: Self.usedAddressCacheKey) as? [String] ?? []
        guard !updated.contains(address) else { return }
        updated.append(address)
        UserDefaults.standard.set(updated, forKey: Self.usedAddressCacheKey)
    }

    /// Tri-state variant of `hasSpendingAddressBeenUsed`: `true` = confirmed used (cached or a
    /// successful count lookup found history), `false` = CONFIRMED unused (the REST probe
    /// succeeded and the count is genuinely zero), `nil` = the probe FAILED (network error,
    /// non-2xx, decode failure) so used-ness is unknown right now. Callers that make
    /// decisions off "unused" (the Generate recyclers, the Used/Unused badge) must treat `nil`
    /// as "don't know" - never as "unused" - so a rate-limited or offline probe can't recycle
    /// or mislabel an address that actually has history.
    ///
    /// The network probe is `GET /addresses/{address}/transactions-count` — a one-integer JSON
    /// body ({"total": N}, ~14 bytes) instead of the old `full-transactions?limit=1&
    /// resolve_previous_outpoints=light`, which made the server assemble (and us download and
    /// decode) an entire transaction with resolved outpoints just to answer a yes/no question.
    /// A short per-request timeout keeps a hung host from pinning a sweep's concurrency slot.
    func spendingAddressUsedState(_ address: String) async -> Bool? {
        if let cached = cachedSpendingAddressUsedState(address) { return cached }
        guard let url = kaspaRestURL(path: "/addresses/\(address)/transactions-count") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }
            let count = try JSONDecoder().decode(KaspaAddressTransactionsCountResponse.self, from: data)
            let used = count.total > 0
            if used {
                markSpendingAddressUsed(address)
            } else {
                Self.sessionUnusedAddresses.insert(address)
            }
            return used
        } catch {
            return nil
        }
    }

    func updateWalletBalanceIfNeeded(address: String, utxos: [UTXO]) {
        WalletManager.shared.updateBalanceIfCurrentWallet(address: address, utxos: utxos)
    }

    /// Fetch UTXOs with automatic fallback - tries gRPC if connected, otherwise uses REST API
    /// This is useful for fee estimation where we don't want to block waiting for gRPC connection
    func fetchUtxosWithFallback(for address: String) async throws -> [UTXO] {
        // Check cache first
        if let timestamp = cachedUtxosTimestamp,
           Date().timeIntervalSince(timestamp) < utxoCacheInterval,
           !cachedUtxos.isEmpty {
            return cachedUtxos
        }

        // getUtxosByAddresses already has REST fallback built in
        let utxos = try await NodePoolService.shared.getUtxosByAddresses([address])
        updateWalletBalanceIfNeeded(address: address, utxos: utxos)
        cachedUtxos = utxos
        cachedUtxosTimestamp = Date()
        return utxos
    }
}

/// Response of `GET /addresses/{address}/transactions-count` on the Kaspa REST API — the
/// one-integer body backing `spendingAddressUsedState`. Extra fields (e.g. `limit_exceeded`
/// on newer servers) are ignored by the decoder.
private struct KaspaAddressTransactionsCountResponse: Decodable {
    let total: Int
}
