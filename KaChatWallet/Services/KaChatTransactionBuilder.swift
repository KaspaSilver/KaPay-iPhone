import Foundation
import CryptoKit
import P256K

/// Builds Kaspa transactions for Kasia messaging protocol
struct KasiaTransactionBuilder {

    // Kaspa constants
    /// A sizing reference, no longer a rule. This was the floor every output and every change
    /// had to clear, standing in for KIP-9 storage mass: an output of this size carved from a
    /// large input costs C / amount = 50,000 grams, half the standard budget, so it was a safe
    /// worst case. But storage mass is not a per-output minimum - it charges the change in the
    /// UTXO set's harmonic cost, outputs minus inputs - and the same 0.198 KAS output spent
    /// from a 0.2 KAS input costs 500 grams. Treating the worst case as the rule meant a wallet
    /// whose only coin was a received handshake could neither accept it nor reply, and change
    /// under this figure on any payment went to the miners as fee.
    ///
    /// Validity is decided by `fitsStorageMass` now, everywhere a transaction is built. What is
    /// left of this constant is `WalletService.messageCompactionTargetOutputSompi`, which sizes a
    /// consolidated coin as "this much plus a burst of message fees" - a reserve, where 0.2 KAS
    /// is still a sensible reserve.
    static let dustThreshold: UInt64 = 20_000_000 // 0.2 KAS

    /// The most a payment may fold into its fee when its change cannot stand as an output.
    /// A change output is only ever too small for storage mass below about 0.1 KAS (its own
    /// harmonic term is C / change), so a larger remainder that does not fit means the
    /// RECIPIENT amount is what breaks the budget - and folding then paid the whole change to
    /// the miners: a 0.0999 KAS send from a 10.1 KAS coin built a ~10 KAS fee. Anything over
    /// this is refused (or fixed by adding an input) rather than given away.
    static let maxFoldedChangeSompi: UInt64 = 10_000_000 // 0.1 KAS

    static let smallSendMassMessage = "This amount can't be sent from these coins without giving most of the change away as a network fee. Try a slightly larger amount, or compound this address first."

    /// Kaspa caps transaction mass (~100,000 grams); each input costs ~1,118 grams (dominated by
    /// 1,000 grams of sig-op mass), so a transaction tops out near ~89 inputs before the node
    /// rejects it as over-mass. Cap selection well under that so we never build a doomed transaction
    /// whose node rejection surfaces as a confusing "network error"; a wallet with more UTXOs than
    /// this must consolidate them one transaction at a time (see WalletService.maxConsolidatableChunk).
    static let maxInputsPerTransaction = 80

    static let standardSubnetworkId = Data(repeating: 0, count: 20)

    private static func addSompiChecked(_ current: UInt64, _ amount: UInt64, context: String) throws -> UInt64 {
        let (next, overflow) = current.addingReportingOverflow(amount)
        guard !overflow else {
            AppLog.log("[TxBuilder] Rejecting suspicious UTXO sum overflow (%@): current=%llu add=%llu", context, current, amount)
            throw KasiaError.networkError("Invalid UTXO data: amount overflow")
        }
        return next
    }

    /// Generic self-send transaction carrying an arbitrary payload - the exact shape K protocol
    /// writes use (the .kachat profile record): spend own UTXOs, single change-back-to-self output,
    /// payload attached.
    /// Identical mechanics to buildContextualMessageTx minus the Kasia encryption.
    static func buildPayloadSelfSendTx(
        from senderAddress: String,
        senderPrivateKey: Data,
        utxos: [UTXO],
        payload: Data
    ) throws -> KaspaRpcTransaction {
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: senderAddress) else {
            throw KasiaError.invalidAddress
        }
        let selection = try selectUtxosForContextualMessage(
            utxos: utxos,
            payload: payload,
            senderScriptPubKey: senderScriptPubKey,
            feeOverride: nil
        )
        let outputs = [KaspaRpcTransactionOutput(
            value: selection.totalInput - selection.fee,
            scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey)
        )]
        let unsignedTx = KaspaRpcTransaction(
            version: 0,
            inputs: selection.utxos.map { utxo in
                KaspaRpcTransactionInput(
                    previousOutpoint: utxo.outpoint,
                    signatureScript: Data(),
                    sequence: 0,
                    sigOpCount: 1
                )
            },
            outputs: outputs,
            lockTime: 0,
            subnetworkId: standardSubnetworkId,
            gas: 0,
            payload: payload
        )
        return try signTransaction(unsignedTx, privateKey: senderPrivateKey, utxos: selection.utxos)
    }


    /// Build a plain KAS transfer transaction — no KaChat protocol payload, just a payment
    /// to an arbitrary address (used by the Profile "Withdraw Kaspa" flow). Reuses the same
    /// UTXO-selection/fee/signing machinery as buildPaymentTx, just without requiring a
    /// recipient public key or attaching an encrypted payload.
    static func buildPlainTransferTx(
        from senderAddress: String,
        to recipientAddress: String,
        amount: UInt64,
        senderPrivateKey: Data,
        utxos: [UTXO],
        manualUtxos: [UTXO]? = nil,
        extraFeeSompi: UInt64 = 0,
        changeAddress: String? = nil,
        virtualDaaScore: UInt64? = nil,
        /// KIP-22 (quantum-safe) sender: its redeem script, pushed after each signature and
        /// priced into the fee.
        senderRedeemScript: Data? = nil
    ) throws -> KaspaRpcTransaction {
        let signatureScriptSize = senderRedeemScript.map { 66 + canonicalPushDataSize($0.count) } ?? 66
        guard amount > 0 else {
            throw KasiaError.networkError("Amount must be greater than zero")
        }

        guard let recipientScriptPubKey = KaspaAddress.scriptPublicKey(from: recipientAddress) else {
            throw KasiaError.invalidAddress
        }
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: senderAddress) else {
            throw KasiaError.invalidAddress
        }
        // The change output is priced at ITS OWN script: change to a fresh quantum (KIP-22)
        // slot is a 35-byte P2SH script, a byte longer than P2PK - 11 mass grams the fee must
        // cover, and the fee is the network minimum per gram (KaspaFeePolicy).
        let changeScriptPubKey: Data
        if let changeAddress {
            guard let script = KaspaAddress.scriptPublicKey(from: changeAddress) else {
                throw KasiaError.invalidAddress
            }
            changeScriptPubKey = script
        } else {
            changeScriptPubKey = senderScriptPubKey
        }

        let selection: PaymentSelection
        if let manualUtxos, !manualUtxos.isEmpty {
            selection = try selectManualUtxosForPayment(
                utxos: manualUtxos,
                amount: amount,
                payload: Data(),
                recipientScriptPubKey: recipientScriptPubKey,
                senderScriptPubKey: changeScriptPubKey,
                extraFeeSompi: extraFeeSompi,
                virtualDaaScore: virtualDaaScore,
                signatureScriptSize: signatureScriptSize
            )
        } else {
            selection = try selectUtxosForPayment(
                utxos: utxos,
                amount: amount,
                payload: Data(),
                recipientScriptPubKey: recipientScriptPubKey,
                senderScriptPubKey: changeScriptPubKey,
                extraFeeSompi: extraFeeSompi,
                virtualDaaScore: virtualDaaScore,
                signatureScriptSize: signatureScriptSize
            )
        }

        var outputs: [KaspaRpcTransactionOutput] = [
            KaspaRpcTransactionOutput(
                value: amount,
                scriptPublicKey: KaspaScriptPublicKey(version: 0, script: recipientScriptPubKey)
            )
        ]
        if selection.keepsChange(withRecipientAmount: amount) {
            outputs.append(KaspaRpcTransactionOutput(
                value: selection.change,
                scriptPublicKey: KaspaScriptPublicKey(version: 0, script: changeScriptPubKey)
            ))
        }

        let unsignedTx = KaspaRpcTransaction(
            version: 0,
            inputs: selection.utxos.map { utxo in
                KaspaRpcTransactionInput(
                    previousOutpoint: utxo.outpoint,
                    signatureScript: Data(),
                    sequence: 0,
                    sigOpCount: 1
                )
            },
            outputs: outputs,
            lockTime: 0,
            subnetworkId: standardSubnetworkId,
            gas: 0,
            payload: Data()
        )

        return try signTransaction(unsignedTx, privateKey: senderPrivateKey, utxos: selection.utxos,
                                   redeemScript: senderRedeemScript)
    }

    /// Estimate fee for a plain transfer (no payload). `extraFeeSompi` is the same optional
    /// priority tip accepted by buildPlainTransferTx, reflected here so the UI can show the
    /// real total the user will pay before sending.
    /// Kaspa coinbase (mining-reward) maturity, in DAA-score units. Matches Kaspa consensus and
    /// Kaspium (which uses the same 1000).
    static let coinbaseMaturity: UInt64 = 1000

    /// Filters a candidate UTXO set to what a transaction may actually spend. Non-coinbase UTXOs
    /// always qualify; coinbase (mining rewards) only once matured (`blockDaaScore + coinbaseMaturity
    /// < virtualDaaScore`). When `virtualDaaScore` is nil the builder keeps its long-standing
    /// conservative behavior of excluding coinbase entirely - callers that want to spend mining
    /// rewards must supply the current virtual DAA score.
    static func spendableForBuild(_ utxos: [UTXO], virtualDaaScore: UInt64?) -> [UTXO] {
        utxos.filter { utxo in
            guard utxo.isCoinbase else { return true }
            guard let vds = virtualDaaScore else { return false }
            // overflow (a nonsense DAA score from a node) counts as not yet mature
            let (matureAt, overflow) = utxo.blockDaaScore.addingReportingOverflow(coinbaseMaturity)
            return !overflow && matureAt < vds
        }
    }

    static func estimatePlainTransferFee(
        utxos: [UTXO],
        amount: UInt64,
        recipientScriptPubKey: Data,
        senderScriptPubKey: Data,
        manualUtxos: [UTXO]? = nil,
        extraFeeSompi: UInt64 = 0,
        virtualDaaScore: UInt64? = nil,
        signatureScriptSize: Int = 66
    ) throws -> SendFeeEstimate {
        let selection: PaymentSelection
        if let manualUtxos, !manualUtxos.isEmpty {
            selection = try selectManualUtxosForPayment(
                utxos: manualUtxos,
                amount: amount,
                payload: Data(),
                recipientScriptPubKey: recipientScriptPubKey,
                senderScriptPubKey: senderScriptPubKey,
                extraFeeSompi: extraFeeSompi,
                virtualDaaScore: virtualDaaScore,
                signatureScriptSize: signatureScriptSize
            )
        } else {
            selection = try selectUtxosForPayment(
                utxos: utxos,
                amount: amount,
                payload: Data(),
                recipientScriptPubKey: recipientScriptPubKey,
                senderScriptPubKey: senderScriptPubKey,
                extraFeeSompi: extraFeeSompi,
                virtualDaaScore: virtualDaaScore,
                signatureScriptSize: signatureScriptSize
            )
        }
        var outputs: [KaspaRpcTransactionOutput] = [
            KaspaRpcTransactionOutput(value: amount, scriptPublicKey: KaspaScriptPublicKey(version: 0, script: recipientScriptPubKey))
        ]
        if selection.keepsChange(withRecipientAmount: amount) {
            outputs.append(KaspaRpcTransactionOutput(value: selection.change, scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey)))
        }
        return SendFeeEstimate(
            networkFee: estimateFee(payload: Data(), inputCount: selection.utxos.count, outputs: outputs,
                                    signatureScriptSize: signatureScriptSize) + extraFeeSompi,
            foldedChange: selection.keepsChange(withRecipientAmount: amount) ? 0 : selection.change
        )
    }

    /// Estimate fee for send-all transaction (all UTXOs, single output, no change)
    /// Uses 2 outputs in calculation to be conservative (matches selectUtxosForPayment behavior)
    static func estimateSendAllFee(
        utxos: [UTXO],
        payload: Data,
        recipientScriptPubKey: Data,
        senderScriptPubKey: Data,
        manualUtxos: [UTXO]? = nil,
        extraFeeSompi: UInt64 = 0,
        virtualDaaScore: UInt64? = nil,
        signatureScriptSize: Int = 66
    ) -> UInt64 {
        // With coin control active, "max" means "max spendable from the selected UTXOs", not
        // from the whole address - use exactly the manual set instead of every spendable UTXO.
        let spendable = spendableForBuild(manualUtxos?.isEmpty == false ? manualUtxos! : utxos, virtualDaaScore: virtualDaaScore)
        // Calculate with 2 outputs to match selectUtxosForPayment which always estimates with change first
        let outputs = [
            KaspaRpcTransactionOutput(value: 0, scriptPublicKey: KaspaScriptPublicKey(version: 0, script: recipientScriptPubKey)),
            KaspaRpcTransactionOutput(value: 0, scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey))
        ]
        return estimateFee(payload: payload, inputCount: spendable.count, outputs: outputs,
                           signatureScriptSize: signatureScriptSize) + 3 + extraFeeSompi
    }

    // MARK: - KNS Commit-Reveal

    struct KNSCommitContext {
        let redeemScript: Data
        let commitAddress: String
        let commitScriptPubKey: Data
        let commitAmountSompi: UInt64
        let revealAmountSompi: UInt64
        let commitOutputIndex: UInt32
    }

    /// Build commit transaction for a KNS `addProfile` inscription. `ownerAddress`'s pubkey
    /// is embedded in the redeem script — that's what the KNS indexer treats as the
    /// domain/profile's owner. `fundingAddress`/`fundingPrivateKey` only pay for the commit
    /// output (UTXO inputs, change) and sign this transaction; they never touch ownership.
    /// Matches Android's buildAndSubmitCommit(fundingAddress:fundingPrivateKey:ownerPrivateKey:)
    /// split, letting a spending address fund domain/profile writes while the identity
    /// address remains the resolved owner. `changeAddress` redirects the funding change
    /// (default: back to `fundingAddress`) - used when the primary spending address funds a
    /// transfer and its change must land on a fresh address.
    static func buildKNSAddProfileCommitTx(
        ownerAddress: String,
        fundingAddress: String,
        fundingPrivateKey: Data,
        payloadJSON: Data,
        utxos: [UTXO],
        title: String = "kns",
        commitAmountSompi: UInt64 = 200_000_000,
        revealAmountSompi: UInt64 = 100_000_000,
        changeAddress: String? = nil
    ) throws -> (transaction: KaspaRpcTransaction, context: KNSCommitContext) {
        guard commitAmountSompi > 0 else {
            throw KasiaError.networkError("KNS commit amount must be positive")
        }

        guard let fundingScriptPubKey = KaspaAddress.scriptPublicKey(from: fundingAddress) else {
            throw KasiaError.invalidAddress
        }
        let changeScriptPubKey: Data
        if let changeAddress {
            guard let script = KaspaAddress.scriptPublicKey(from: changeAddress) else {
                throw KasiaError.invalidAddress
            }
            changeScriptPubKey = script
        } else {
            changeScriptPubKey = fundingScriptPubKey
        }

        let redeemScript = try buildKNSRedeemScript(
            walletAddress: ownerAddress,
            title: title,
            payloadJSON: payloadJSON
        )
        let commitAddress = try makeKNSCommitAddress(
            redeemScript: redeemScript,
            walletAddress: ownerAddress
        )
        guard let commitScriptPubKey = KaspaAddress.scriptPublicKey(from: commitAddress) else {
            throw KasiaError.invalidAddress
        }

        let selection = try selectUtxosForPayment(
            utxos: utxos,
            amount: commitAmountSompi,
            payload: Data(),
            recipientScriptPubKey: commitScriptPubKey,
            senderScriptPubKey: fundingScriptPubKey
        )

        var outputs: [KaspaRpcTransactionOutput] = [
            KaspaRpcTransactionOutput(
                value: commitAmountSompi,
                scriptPublicKey: KaspaScriptPublicKey(version: 0, script: commitScriptPubKey)
            )
        ]
        if selection.keepsChange(withRecipientAmount: commitAmountSompi) {
            outputs.append(
                KaspaRpcTransactionOutput(
                    value: selection.change,
                    scriptPublicKey: KaspaScriptPublicKey(version: 0, script: changeScriptPubKey)
                )
            )
        }

        let unsignedTx = KaspaRpcTransaction(
            version: 0,
            inputs: selection.utxos.map { utxo in
                KaspaRpcTransactionInput(
                    previousOutpoint: utxo.outpoint,
                    signatureScript: Data(),
                    sequence: 0,
                    sigOpCount: 1
                )
            },
            outputs: outputs,
            lockTime: 0,
            subnetworkId: standardSubnetworkId,
            gas: 0,
            payload: Data()
        )
        let signedTx = try signTransaction(unsignedTx, privateKey: fundingPrivateKey, utxos: selection.utxos)
        let context = KNSCommitContext(
            redeemScript: redeemScript,
            commitAddress: commitAddress,
            commitScriptPubKey: commitScriptPubKey,
            commitAmountSompi: commitAmountSompi,
            revealAmountSompi: revealAmountSompi,
            commitOutputIndex: 0
        )
        return (signedTx, context)
    }

    /// Build reveal transaction that spends the commit output and reveals KNS data. The
    /// commit output's redeem script requires a signature from `ownerAddress`'s key (the
    /// identity address — see buildKNSAddProfileCommitTx), so `ownerPrivateKey` must always
    /// be that key regardless of which address funded the commit. `changeAddress` is where
    /// any leftover value (commit amount minus reveal amount minus fee) lands — pass the
    /// funding/spending address here so leftover value returns to spending, not identity.
    static func buildKNSAddProfileRevealTx(
        ownerAddress: String,
        ownerPrivateKey: Data,
        changeAddress: String,
        commitTxId: String,
        commitContext: KNSCommitContext,
        revealTargetAddress: String? = nil,
        revealPriorityFeeSompi: UInt64 = 2_000_000
    ) throws -> KaspaRpcTransaction {
        let targetAddress = revealTargetAddress ?? ownerAddress

        guard let targetScriptPubKey = KaspaAddress.scriptPublicKey(from: targetAddress) else {
            throw KasiaError.invalidAddress
        }
        guard let changeScriptPubKey = KaspaAddress.scriptPublicKey(from: changeAddress) else {
            throw KasiaError.invalidAddress
        }

        let recipientOutput: KaspaRpcTransactionOutput? = commitContext.revealAmountSompi > 0
            ? KaspaRpcTransactionOutput(
                value: commitContext.revealAmountSompi,
                scriptPublicKey: KaspaScriptPublicKey(version: 0, script: targetScriptPubKey)
            )
            : nil

        // Signature script is push(sig+hashtype) + push(redeemScript)
        let signatureScriptSize = 66 + canonicalPushDataSize(commitContext.redeemScript.count)
        let baseOutputs = recipientOutput.map { [$0] } ?? []
        let feeWithChange = estimateFee(
            payload: Data(),
            inputCount: 1,
            outputs: baseOutputs + [
                KaspaRpcTransactionOutput(
                    value: 0,
                    scriptPublicKey: KaspaScriptPublicKey(version: 0, script: changeScriptPubKey)
                )
            ],
            signatureScriptSize: signatureScriptSize
        ) + revealPriorityFeeSompi

        guard commitContext.commitAmountSompi >= commitContext.revealAmountSompi,
              commitContext.commitAmountSompi - commitContext.revealAmountSompi >= feeWithChange else {
            throw KasiaError.networkError("KNS reveal amount cannot be covered by commit output")
        }

        var outputs: [KaspaRpcTransactionOutput] = baseOutputs
        var change = commitContext.commitAmountSompi - commitContext.revealAmountSompi - feeWithChange

        // The reveal spends exactly one input, the commit output, so the shape is fully known
        // here: that input against the reveal output (if any) plus this change.
        let revealInputs = [commitContext.commitAmountSompi]
        if fitsStorageMass(inputAmounts: revealInputs, outputAmounts: baseOutputs.map(\.value) + [change]) {
            outputs.append(
                KaspaRpcTransactionOutput(
                    value: change,
                    scriptPublicKey: KaspaScriptPublicKey(version: 0, script: changeScriptPubKey)
                )
            )
        } else {
            let feeNoChange = estimateFee(
                payload: Data(),
                inputCount: 1,
                outputs: baseOutputs,
                signatureScriptSize: signatureScriptSize
            ) + revealPriorityFeeSompi
            guard commitContext.commitAmountSompi >= commitContext.revealAmountSompi,
                  commitContext.commitAmountSompi - commitContext.revealAmountSompi >= feeNoChange else {
                throw KasiaError.networkError("Insufficient commit amount for KNS reveal fee")
            }
            change = commitContext.commitAmountSompi - commitContext.revealAmountSompi - feeNoChange
            if fitsStorageMass(inputAmounts: revealInputs, outputAmounts: baseOutputs.map(\.value) + [change]) {
                outputs.append(
                    KaspaRpcTransactionOutput(
                        value: change,
                        scriptPublicKey: KaspaScriptPublicKey(version: 0, script: changeScriptPubKey)
                    )
                )
            }
        }

        guard !outputs.isEmpty else {
            throw KasiaError.networkError("KNS reveal transaction has no spendable outputs after fees")
        }

        let unsignedTx = KaspaRpcTransaction(
            version: 0,
            inputs: [
                KaspaRpcTransactionInput(
                    previousOutpoint: UTXO.Outpoint(
                        transactionId: commitTxId,
                        index: commitContext.commitOutputIndex
                    ),
                    signatureScript: Data(),
                    sequence: 0,
                    sigOpCount: 1
                )
            ],
            outputs: outputs,
            lockTime: 0,
            subnetworkId: standardSubnetworkId,
            gas: 0,
            payload: Data()
        )

        return try signKNSRevealTransaction(
            unsignedTx,
            privateKey: ownerPrivateKey,
            utxoScriptPubKey: commitContext.commitScriptPubKey,
            redeemScript: commitContext.redeemScript,
            commitAmountSompi: commitContext.commitAmountSompi
        )
    }

    // MARK: - Private Methods

    private struct PaymentSelection {
        let utxos: [UTXO]
        let change: UInt64
        /// The selector's own decision: `change` is a change output, priced with the
        /// with-change fee. False means the remainder was folded into the (no-change) fee.
        let emitChange: Bool

        /// Whether the builder emits `change` as an output. Carried from the selector rather than
        /// re-derived: re-testing the folded remainder (larger than the with-change change by
        /// the fee difference) could pass the storage-mass test in a narrow band and emit a
        /// change output under a fee priced for no change - a node rejection (IOS-018).
        func keepsChange(withRecipientAmount recipientAmount: UInt64) -> Bool {
            emitChange
        }
    }

    private struct ContextualSelection {
        let utxos: [UTXO]
        let totalInput: UInt64
        let fee: UInt64
    }

    /// Select a minimal UTXO set for a payload self-send (the .kachat profile record).
    /// Prefers fewer inputs to avoid quickly consuming all confirmed UTXOs.
    private static func selectUtxosForContextualMessage(
        utxos: [UTXO],
        payload: Data,
        senderScriptPubKey: Data,
        feeOverride: UInt64? = nil
    ) throws -> ContextualSelection {
        let spendable = utxos.filter { !$0.isCoinbase }
        let pending = spendable
            .filter { $0.blockDaaScore == 0 }
            .sorted { $0.amount > $1.amount }

        guard !spendable.isEmpty else {
            throw KasiaError.networkError("Insufficient funds after fee")
        }

        let outputTemplate = KaspaRpcTransactionOutput(
            value: 0,
            scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey)
        )

        // A caller-set fee always wins over the computed estimate, regardless of input count.
        let feeFor: (Int) -> UInt64 = { inputCount in
            feeOverride ?? (estimateFee(payload: payload, inputCount: inputCount, outputs: [outputTemplate]) + 3)
        }

        // Prefer chaining on a single pending self-change UTXO when it can cover the fee and the
        // self-spend it leaves behind fits the storage-mass budget.
        let singleInputFee = feeFor(1)
        if let pendingSingle = pending.first(where: {
            $0.amount > singleInputFee
                && fitsStorageMass(inputAmounts: [$0.amount], outputAmounts: [$0.amount - singleInputFee])
        }) {
            return ContextualSelection(utxos: [pendingSingle], totalInput: pendingSingle.amount, fee: singleInputFee)
        }

        // Otherwise, use global largest-first order. This avoids combining many tiny pending UTXOs
        // before trying a larger confirmed one.
        let prioritized = spendable.sorted { lhs, rhs in
            if lhs.amount != rhs.amount {
                return lhs.amount > rhs.amount
            }
            let lhsPending = lhs.blockDaaScore == 0
            let rhsPending = rhs.blockDaaScore == 0
            if lhsPending != rhsPending {
                return lhsPending
            }
            return lhs.outpoint.transactionId > rhs.outpoint.transactionId
        }

        var selected: [UTXO] = []
        var total: UInt64 = 0

        for utxo in prioritized {
            selected.append(utxo)
            total = try addSompiChecked(total, utxo.amount, context: "contextual selection")

            let fee = feeFor(selected.count)
            guard total > fee else { continue }

            // A self-spend into one output, the cheapest shape KIP-9 has: what matters is the
            // storage mass of this exact transaction, not a flat floor on the output.
            let outputAmount = total - fee
            if fitsStorageMass(inputAmounts: selected.map(\.amount), outputAmounts: [outputAmount]) {
                return ContextualSelection(utxos: selected, totalInput: total, fee: fee)
            }
        }

        throw KasiaError.networkError("Insufficient funds after fee")
    }


    /// Select minimal UTXOs to cover payment and fee. `extraFeeSompi` is an optional
    /// priority tip added on top of the computed minimum-standard fee, for callers that let
    /// the user pay more during network congestion (e.g. the Withdraw Kaspa fee selector).
    private static func selectUtxosForPayment(
        utxos: [UTXO],
        amount: UInt64,
        payload: Data,
        recipientScriptPubKey: Data,
        senderScriptPubKey: Data,
        extraFeeSompi: UInt64 = 0,
        virtualDaaScore: UInt64? = nil,
        signatureScriptSize: Int = 66
    ) throws -> PaymentSelection {
        // Sort largest first to reduce input count (lower mass). Immature coinbase is excluded up
        // front (mature coinbase is kept only when a virtual DAA score is supplied).
        let sorted = spendableForBuild(utxos, virtualDaaScore: virtualDaaScore).sorted { $0.amount > $1.amount }
        var selected: [UTXO] = []
        var total: UInt64 = 0
        // Funds were enough but no shape fit without giving away real change - see below.
        var blockedByStorageMass = false

        for utxo in sorted {
            // Refuse to build an over-mass transaction: if we've hit the input cap and still
            // haven't covered the amount, more inputs would exceed Kaspa's mass limit and the node
            // would reject the tx. Fail with a clear, actionable message instead.
            if selected.count >= maxInputsPerTransaction {
                throw KasiaError.networkError("This send needs more than \(maxInputsPerTransaction) inputs. Compound (consolidate) this address's UTXOs first, then try again.")
            }
            selected.append(utxo)
            total = try addSompiChecked(total, utxo.amount, context: "payment selection")

            let recipientOutput = KaspaRpcTransactionOutput(
                value: amount,
                scriptPublicKey: KaspaScriptPublicKey(version: 0, script: recipientScriptPubKey)
            )

            // Estimate with change output (+ buffer to avoid under-fee rejection, + priority tip)
            let feeWithChange = estimateFee(
                payload: payload,
                inputCount: selected.count,
                outputs: [
                    recipientOutput,
                    KaspaRpcTransactionOutput(value: 0, scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey))
                ],
                signatureScriptSize: signatureScriptSize
            ) + 3 + extraFeeSompi

            if total <= amount {
                continue
            }

            // Keep the change whenever this transaction's own storage mass allows it (see
            // `storageMass`). The flat `> dustThreshold` rule here handed up to 0.2 KAS of a
            // user's change to the miners as fee whenever it fell under the floor - money gone,
            // not a rounding error - for change the network would have accepted. Too little left
            // to pay for a change output at all (a Max send) still goes on to the no-change try.
            if total - amount >= feeWithChange {
                let change = total - amount - feeWithChange
                if fitsStorageMass(inputAmounts: selected.map(\.amount), outputAmounts: [amount, change]) {
                    return PaymentSelection(utxos: selected, change: change, emitChange: true)
                }
            }

            // Try without change (treat dust as fee, + buffer, + priority tip) - only when the
            // leftover really is dust. A bigger leftover that will not fit means the send itself
            // is too small for this coin set: keep adding inputs (a smaller coin lowers the mass),
            // and refuse if none does, rather than paying the change away as fee.
            let feeNoChange = estimateFee(payload: payload, inputCount: selected.count, outputs: [recipientOutput],
                                          signatureScriptSize: signatureScriptSize) + 3 + extraFeeSompi
            if total > amount && total - amount >= feeNoChange {
                let change = total - amount - feeNoChange
                if change <= maxFoldedChangeSompi {
                    return PaymentSelection(utxos: selected, change: change, emitChange: false)
                }
                blockedByStorageMass = true
            }
        }

        if blockedByStorageMass {
            throw KasiaError.networkError(smallSendMassMessage)
        }
        throw KasiaError.networkError("Insufficient funds for payment")
    }

    /// Coin-control counterpart to `selectUtxosForPayment` - uses exactly the given `utxos` as
    /// the transaction's input set (no incremental growth/sorting) rather than greedily picking
    /// a subset, since the whole point of coin control is letting the caller fix which specific
    /// inputs a send spends. Same "with change, else without change, else fail" fee logic as the
    /// greedy selector, just evaluated once against the fixed set instead of per candidate added.
    private static func selectManualUtxosForPayment(
        utxos: [UTXO],
        amount: UInt64,
        payload: Data,
        recipientScriptPubKey: Data,
        senderScriptPubKey: Data,
        extraFeeSompi: UInt64 = 0,
        virtualDaaScore: UInt64? = nil,
        signatureScriptSize: Int = 66
    ) throws -> PaymentSelection {
        let usable = spendableForBuild(utxos, virtualDaaScore: virtualDaaScore)
        guard !usable.isEmpty else {
            throw KasiaError.networkError("Insufficient funds for payment")
        }
        // A fixed input set over the mass cap would be rejected by the node - refuse it up front.
        // Consolidation feeds this in chunks of maxInputsPerTransaction, so those always pass.
        guard usable.count <= maxInputsPerTransaction else {
            throw KasiaError.networkError("Too many inputs selected (\(usable.count)). Kaspa transactions are limited to about \(maxInputsPerTransaction) inputs - select fewer, or compound this address first.")
        }
        let total = try usable.reduce(UInt64(0)) { try addSompiChecked($0, $1.amount, context: "manual payment selection") }

        let recipientOutput = KaspaRpcTransactionOutput(
            value: amount,
            scriptPublicKey: KaspaScriptPublicKey(version: 0, script: recipientScriptPubKey)
        )

        let feeWithChange = estimateFee(
            payload: payload,
            inputCount: usable.count,
            outputs: [
                recipientOutput,
                KaspaRpcTransactionOutput(value: 0, scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey))
            ],
            signatureScriptSize: signatureScriptSize
        ) + 3 + extraFeeSompi

        if total > amount, total - amount >= feeWithChange {
            let change = total - amount - feeWithChange
            // Same rule as the greedy selector: change stays when the shape fits under KIP-9.
            if fitsStorageMass(inputAmounts: usable.map(\.amount), outputAmounts: [amount, change]) {
                return PaymentSelection(utxos: usable, change: change, emitChange: true)
            }
        }

        // Try without change (treat dust as fee, + buffer, + priority tip) - dust only, the same
        // rule as the greedy selector: never pay real change away to make a shape fit.
        let feeNoChange = estimateFee(payload: payload, inputCount: usable.count, outputs: [recipientOutput],
                                      signatureScriptSize: signatureScriptSize) + 3 + extraFeeSompi
        if total > amount, total - amount >= feeNoChange {
            let leftover = total - amount - feeNoChange
            guard leftover <= maxFoldedChangeSompi else {
                throw KasiaError.networkError(smallSendMassMessage)
            }
            return PaymentSelection(utxos: usable, change: leftover, emitChange: false)
        }

        throw KasiaError.networkError("Insufficient funds for payment")
    }

    /// Select UTXOs to cover required amount
    private static func selectUtxos(_ utxos: [UTXO], requiredAmount: UInt64) throws -> ([UTXO], UInt64) {
        // Every available UTXO as its own input (the external Kasia app's behaviour), largest
        // first and at most `maxInputsPerTransaction`: past ~89 inputs the node rejects the
        // transaction as over-mass with an opaque error (IOS-009).
        let utxos = Array(utxos
            .filter { !$0.isCoinbase }
            .sorted { $0.amount > $1.amount }
            .prefix(maxInputsPerTransaction))
        var selected: [UTXO] = []
        var totalAmount: UInt64 = 0

        for utxo in utxos {
            // Skip coinbase UTXOs that might not be mature
            if utxo.isCoinbase {
                continue
            }

            selected.append(utxo)
            totalAmount = try addSompiChecked(totalAmount, utxo.amount, context: "utxo selection")

            #if DEBUG
            AppLog.log("%@", "[TxBuilder] Selected UTXO: \(utxo.amount) sompi, total: \(totalAmount)")
            #endif
        }

        guard totalAmount >= requiredAmount else {
            throw KasiaError.networkError("Insufficient funds. Have \(totalAmount), need \(requiredAmount)")
        }

        #if DEBUG
        AppLog.log("%@", "[TxBuilder] Total selected: \(selected.count) UTXOs, total amount: \(totalAmount)")
        #endif

        return (selected, totalAmount)
    }

    /// A KIP-22 (quantum-safe) input's signature script: the usual 66 bytes plus the pushed
    /// 34-byte redeem script (`0x20 <key> OP_CHECKSIG`).
    static let kip22SignatureScriptSize = 66 + 35

    /// Calculate the Toccata minimum standard fee.
    /// Fee mass is max(compute mass, normalized transient mass), where post-Toccata
    /// transient mass normalizes to 2 grams per estimated transaction byte.
    private static func estimateFee(payload: Data, inputCount: Int, outputs: [KaspaRpcTransactionOutput]) -> UInt64 {
        estimateFee(payload: payload, inputCount: inputCount, outputs: outputs, signatureScriptSize: 66)
    }

    private static func estimateFee(
        payload: Data,
        inputCount: Int,
        outputs: [KaspaRpcTransactionOutput],
        signatureScriptSize: Int
    ) -> UInt64 {
        let dummyInput = KaspaRpcTransactionInput(
            previousOutpoint: UTXO.Outpoint(transactionId: String(repeating: "0", count: 64), index: 0),
            signatureScript: Data(repeating: 0, count: max(0, signatureScriptSize)),
            sequence: 0,
            sigOpCount: 1
        )
        let inputs = Array(repeating: dummyInput, count: inputCount)
        let computeMass = computeComputeMass(
            version: 0,
            inputs: inputs,
            outputs: outputs,
            payload: payload
        )
        let estimatedBytes = estimateTransactionByteCount(
            version: 0,
            inputs: inputs,
            outputs: outputs,
            payload: payload
        )
        return KaspaFeePolicy.minimumStandardFee(computeMass: computeMass, estimatedTransactionBytes: estimatedBytes)
    }

    private static func buildKNSRedeemScript(
        walletAddress: String,
        title: String,
        payloadJSON: Data
    ) throws -> Data {
        guard let pubKey = KaspaAddress.publicKey(from: walletAddress),
              pubKey.count == 32 else {
            throw KasiaError.invalidAddress
        }
        let titleData = Data(title.utf8)
        guard !titleData.isEmpty else {
            throw KasiaError.networkError("KNS inscription title is empty")
        }
        guard payloadJSON.count <= 520 else {
            throw KasiaError.networkError("KNS inscription payload exceeds 520-byte script element limit")
        }

        var script = Data()
        script.append(0x20) // push 32-byte x-only pubkey
        script.append(pubKey)
        script.append(0xAC) // OP_CHECKSIG
        script.append(0x00) // OP_FALSE
        script.append(0x63) // OP_IF
        script.append(try buildCanonicalPushData(titleData))
        script.append(0x00) // add_i64(0) -> OP_0
        script.append(try buildCanonicalPushData(payloadJSON))
        script.append(0x68) // OP_ENDIF

        return script
    }

    private static func makeKNSCommitAddress(redeemScript: Data, walletAddress: String) throws -> String {
        guard let source = KaspaAddress(address: walletAddress) else {
            throw KasiaError.invalidAddress
        }
        let scriptHash = Blake2b.hash(redeemScript, digestLength: 32)
        return KaspaAddress(hrp: source.hrp, type: .scriptHash, payload: scriptHash).address
    }

    private static func signKNSRevealTransaction(
        _ transaction: KaspaRpcTransaction,
        privateKey: Data,
        utxoScriptPubKey: Data,
        redeemScript: Data,
        commitAmountSompi: UInt64
    ) throws -> KaspaRpcTransaction {
        let schnorrPrivKey = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)

        let sighash = try computeSighash(
            transaction: transaction,
            inputIndex: 0,
            utxoScriptPubKey: utxoScriptPubKey,
            utxoAmount: commitAmountSompi
        )
        var sighashBytes = [UInt8](sighash)
        let signature = try schnorrPrivKey.signature(message: &sighashBytes, auxiliaryRand: nil)
        for index in sighashBytes.indices {
            sighashBytes[index] = 0
        }

        var sigScript = Data()
        sigScript.append(0x41) // push 65 bytes (64-byte sig + sighash type)
        sigScript.append(Data(signature.bytes))
        sigScript.append(0x01) // SIGHASH_ALL
        sigScript.append(try buildCanonicalPushData(redeemScript))

        let signedInput = KaspaRpcTransactionInput(
            previousOutpoint: transaction.inputs[0].previousOutpoint,
            signatureScript: sigScript,
            sequence: transaction.inputs[0].sequence,
            sigOpCount: transaction.inputs[0].sigOpCount
        )

        return KaspaRpcTransaction(
            version: transaction.version,
            inputs: [signedInput],
            outputs: transaction.outputs,
            lockTime: transaction.lockTime,
            subnetworkId: transaction.subnetworkId,
            gas: transaction.gas,
            payload: transaction.payload
        )
    }

    private static func canonicalPushDataSize(_ dataLength: Int) -> Int {
        if dataLength <= 0 {
            return 1
        }
        if dataLength <= 75 {
            return 1 + dataLength
        }
        if dataLength <= 0xff {
            return 2 + dataLength
        }
        if dataLength <= 0xffff {
            return 3 + dataLength
        }
        return 5 + dataLength
    }

    private static func buildCanonicalPushData(_ data: Data) throws -> Data {
        guard data.count <= 520 else {
            throw KasiaError.networkError("Script element exceeds 520-byte limit")
        }

        var encoded = Data()
        let length = data.count

        if length == 0 {
            encoded.append(0x00) // OP_0
            return encoded
        }

        if length <= 75 {
            encoded.append(UInt8(length))
            encoded.append(data)
            return encoded
        }

        if length <= 0xff {
            encoded.append(0x4c) // OP_PUSHDATA1
            encoded.append(UInt8(length))
            encoded.append(data)
            return encoded
        }

        if length <= 0xffff {
            encoded.append(0x4d) // OP_PUSHDATA2
            var le = UInt16(length).littleEndian
            encoded.append(Data(bytes: &le, count: 2))
            encoded.append(data)
            return encoded
        }

        encoded.append(0x4e) // OP_PUSHDATA4
        var le = UInt32(length).littleEndian
        encoded.append(Data(bytes: &le, count: 4))
        encoded.append(data)
        return encoded
    }

    /// Sign transaction inputs using Schnorr
    /// `redeemScript`: a KIP-22 (quantum-safe P2SH) sender's redeem script, pushed after each
    /// signature exactly as the KNS reveal and the .kachat covenants spend P2SH.
    internal static func signTransaction(
        _ transaction: KaspaRpcTransaction,
        privateKey: Data,
        utxos: [UTXO],
        redeemScript: Data? = nil
    ) throws -> KaspaRpcTransaction {
        let schnorrPrivKey = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
        var signedInputs: [KaspaRpcTransactionInput] = []

        for (index, input) in transaction.inputs.enumerated() {
            let utxo = utxos[index]
            let sighash = try computeSighash(
                transaction: transaction,
                inputIndex: index,
                utxoScriptPubKey: utxo.scriptPublicKey,
                utxoAmount: utxo.amount
            )

            var sighashBytes = [UInt8](sighash)
            let signature = try schnorrPrivKey.signature(message: &sighashBytes, auxiliaryRand: nil)
            // Zero sighash bytes after signing
            for i in sighashBytes.indices { sighashBytes[i] = 0 }
            let sigBytes = Data(signature.bytes)

            // Kaspa signature script: push 65 bytes, 64-byte Schnorr signature, SIGHASH_ALL
            var sigScript = Data()
            sigScript.append(0x41) // push 65 bytes
            sigScript.append(sigBytes)
            sigScript.append(0x01) // SIGHASH_ALL
            if let redeemScript {
                sigScript.append(try buildCanonicalPushData(redeemScript))
            }

            signedInputs.append(KaspaRpcTransactionInput(
                previousOutpoint: input.previousOutpoint,
                signatureScript: sigScript,
                sequence: input.sequence,
                sigOpCount: input.sigOpCount
            ))
        }

        return KaspaRpcTransaction(
            version: transaction.version,
            inputs: signedInputs,
            outputs: transaction.outputs,
            lockTime: transaction.lockTime,
            subnetworkId: transaction.subnetworkId,
            gas: transaction.gas,
            payload: transaction.payload
        )
    }

    /// An output's covenant binding (transaction version 1): which input authorizes it and the
    /// covenant it continues. Part of the v1 sighash; the app's own payments carry none.
    struct OutputCovenant {
        let authorizingInput: UInt16
        let covenantId: Data
    }

    /// Compute sighash for transaction input (Kaspa-specific)
    /// Uses Blake2b with "TransactionSigningHash" domain separation (as KEY, not personalization)
    ///
    /// Version 0 and version 1 (rusty-kaspa consensus/core/src/hashing/sighash.rs,
    /// `calc_schnorr_signature_hash`): from version 1 the sig-op counts are left out (both the
    /// hash of all of them and the input's own byte), and each output adds whether it carries a
    /// covenant, then its authorizing input (u16) and covenant id (32 bytes) when it does.
    /// `covenants` is per output (missing entries = none); only verification of received v1
    /// transactions passes it.
    internal static func computeSighash(
        transaction: KaspaRpcTransaction,
        inputIndex: Int,
        utxoScriptPubKey: Data,
        utxoAmount: UInt64,
        covenants: [OutputCovenant?] = []
    ) throws -> Data {
        let isV1 = transaction.version >= 1
        // Kaspa uses Blake2b-256 with KEY for domain separation (not personalization)
        var hasher = Blake2b(digestLength: 32, key: "TransactionSigningHash".data(using: .utf8))

        // Hash version (u16)
        var version = transaction.version.littleEndian
        hasher.update(Data(bytes: &version, count: 2))

        // Hash of all previous outputs (Blake2b of all outpoints)
        var prevOutputsData = Data()
        for input in transaction.inputs {
            let txId = hexToData(input.previousOutpoint.transactionId) ?? Data(repeating: 0, count: 32)
            prevOutputsData.append(txId)
            var idx = input.previousOutpoint.index.littleEndian
            prevOutputsData.append(Data(bytes: &idx, count: 4))
        }
        let prevOutputsHash = Blake2b.hash(prevOutputsData, key: "TransactionSigningHash")
        hasher.update(prevOutputsHash)

        // Hash of all sequences
        var seqData = Data()
        for input in transaction.inputs {
            var seq = input.sequence.littleEndian
            seqData.append(Data(bytes: &seq, count: 8))
        }
        let seqHash = Blake2b.hash(seqData, key: "TransactionSigningHash")
        hasher.update(seqHash)

        // Hash of all sig op counts (version 0 only)
        if !isV1 {
            var sigOpData = Data()
            for input in transaction.inputs {
                sigOpData.append(input.sigOpCount)
            }
            let sigOpHash = Blake2b.hash(sigOpData, key: "TransactionSigningHash")
            hasher.update(sigOpHash)
        }

        // Current input's outpoint
        let input = transaction.inputs[inputIndex]
        let txId = hexToData(input.previousOutpoint.transactionId) ?? Data(repeating: 0, count: 32)
        hasher.update(txId)
        var idx = input.previousOutpoint.index.littleEndian
        hasher.update(Data(bytes: &idx, count: 4))

        // UTXO script public key (with version prefix)
        // Use version 0 for sighash
        var scriptVer = UInt16(0).littleEndian
        hasher.update(Data(bytes: &scriptVer, count: 2))

        // Use full UTXO scriptPublicKey for sighash (Kaspa requires the complete script)
        let scriptBytes = utxoScriptPubKey
        // Script length (Kaspa sighash uses u64 length prefix)
        var scriptLen = UInt64(scriptBytes.count).littleEndian
        hasher.update(Data(bytes: &scriptLen, count: 8))
        hasher.update(scriptBytes)

        // UTXO amount
        var amount = utxoAmount.littleEndian
        hasher.update(Data(bytes: &amount, count: 8))

        // Input sequence
        var seq = input.sequence.littleEndian
        hasher.update(Data(bytes: &seq, count: 8))

        // Sig op count (version 0 only)
        if !isV1 {
            hasher.update(Data([input.sigOpCount]))
        }

        // Hash of all outputs
        var outputsData = Data()
        for (outputIndex, output) in transaction.outputs.enumerated() {
            var value = output.value.littleEndian
            outputsData.append(Data(bytes: &value, count: 8))
            var scriptVer = output.scriptPublicKey.version.littleEndian
            outputsData.append(Data(bytes: &scriptVer, count: 2))
            var scriptLen = UInt64(output.scriptPublicKey.script.count).littleEndian
            outputsData.append(Data(bytes: &scriptLen, count: 8))
            outputsData.append(output.scriptPublicKey.script)
            if isV1 {
                let covenant = outputIndex < covenants.count ? covenants[outputIndex] : nil
                if let covenant {
                    outputsData.append(1)
                    var authorizing = covenant.authorizingInput.littleEndian
                    outputsData.append(Data(bytes: &authorizing, count: 2))
                    outputsData.append(covenant.covenantId)
                } else {
                    outputsData.append(0)
                }
            }
        }
        let outputsHash = Blake2b.hash(outputsData, key: "TransactionSigningHash")
        hasher.update(outputsHash)

        // Lock time
        var lockTime = transaction.lockTime.littleEndian
        hasher.update(Data(bytes: &lockTime, count: 8))

        // Subnetwork ID
        hasher.update(transaction.subnetworkId)

        // Gas (always included per rusty-kaspa/consensus/core/src/hashing/sighash.rs:261)
        var gas = transaction.gas.littleEndian
        hasher.update(Data(bytes: &gas, count: 8))

        // Payload hash (rusty-kaspa/consensus/core/src/hashing/sighash.rs:184-195)
        // If native subnetwork AND payload is empty, use ZERO_HASH
        // Otherwise, hash the payload with write_var_bytes format (u64 length + bytes)
        let isNativeSubnetwork = transaction.subnetworkId.allSatisfy { $0 == 0 }
        let payloadHash: Data
        if isNativeSubnetwork && transaction.payload.isEmpty {
            payloadHash = Data(repeating: 0, count: 32)  // ZERO_HASH
        } else {
            // Hash payload with length prefix (write_var_bytes format uses u64 length)
            var payloadToHash = Data()
            var payloadLen = UInt64(transaction.payload.count).littleEndian
            payloadToHash.append(Data(bytes: &payloadLen, count: 8))
            payloadToHash.append(transaction.payload)
            payloadHash = Blake2b.hash(payloadToHash, key: "TransactionSigningHash")
        }
        hasher.update(payloadHash)

        // Sighash type (SIGHASH_ALL = 1)
        hasher.update(Data([0x01]))

        return hasher.finalize()
    }

    private static func hexToData(_ hex: String) -> Data? {
        var data = Data()
        var temp = ""
        for char in hex {
            temp += String(char)
            if temp.count == 2 {
                if let byte = UInt8(temp, radix: 16) {
                    data.append(byte)
                } else {
                    return nil
                }
                temp = ""
            }
        }
        return data
    }

    /// Storage mass parameter: C = SOMPI_PER_KAS * 10_000 = 1 trillion (KIP-0009)
    private static let storageMassParameter: UInt64 = 100_000_000 * 10_000

    /// The standard transaction mass budget. Consensus rejects a standard transaction whose
    /// storage mass exceeds this, independently of its compute mass.
    static let maxStandardMass: UInt64 = 100_000

    /// KIP-9 storage mass for a transaction shape, in the integer math of rusty-kaspa's
    /// `calc_storage_mass` (mirrored from KasSigner's `storage_mass_estimate`, which is checked
    /// against consensus). Every UTXO here is a standard P2PK entry, so plurality is 1 throughout.
    ///
    ///   harmonic term per element:  C / amount
    ///   relaxed path (one output, or one input, or exactly two of each):
    ///       max(0, harmonic_outs - harmonic_ins)
    ///   otherwise:
    ///       max(0, harmonic_outs - |I| * (C / mean_in))
    ///
    /// This is what decides whether a small output is acceptable - not a flat floor. Storage
    /// mass charges the INCREASE in the UTXO set's harmonic cost, so one 0.2 KAS input spent
    /// into one 0.198 KAS output costs about 500 grams of a 100,000 budget, while the same
    /// 0.198 output carved out of a large input costs 50,000. The old rule, a flat 0.2 KAS
    /// minimum per output, was right for the second case and wrong for the first - and the
    /// first is exactly the shape of a new account whose only coin is a small 0.2 KAS deposit.
    static func storageMass(inputAmounts: [UInt64], outputAmounts: [UInt64]) -> UInt64 {
        let c = storageMassParameter
        func harmonic(_ amounts: [UInt64]) -> UInt64 {
            amounts.reduce(UInt64(0)) { partial, amount in
                partial.addingReportingOverflow(c / max(amount, 1)).partialValue
            }
        }
        let harmonicOuts = harmonic(outputAmounts)
        let relaxed = outputAmounts.count == 1 || inputAmounts.count == 1
            || (outputAmounts.count == 2 && inputAmounts.count == 2)
        if relaxed {
            let harmonicIns = harmonic(inputAmounts)
            return harmonicOuts > harmonicIns ? harmonicOuts - harmonicIns : 0
        }
        let sumIns = inputAmounts.reduce(UInt64(0)) { $0.addingReportingOverflow($1).partialValue }
        let meanIns = max(sumIns / UInt64(max(inputAmounts.count, 1)), 1)
        let arithmeticIns = UInt64(inputAmounts.count).multipliedReportingOverflow(by: c / meanIns).partialValue
        return harmonicOuts > arithmeticIns ? harmonicOuts - arithmeticIns : 0
    }

    /// Whether a transaction spending `inputAmounts` into `outputAmounts` stays within the
    /// standard storage-mass budget. Every output must also be non-zero; a zero-value output is
    /// never worth creating whatever the mass arithmetic says.
    static func fitsStorageMass(inputAmounts: [UInt64], outputAmounts: [UInt64]) -> Bool {
        guard outputAmounts.allSatisfy({ $0 > 0 }) else { return false }
        return storageMass(inputAmounts: inputAmounts, outputAmounts: outputAmounts) <= maxStandardMass
    }

    /// Compute non-contextual compute mass per consensus MassCalculator::calc_non_contextual_masses.
    private static func computeComputeMass(
        version: UInt16,
        inputs: [KaspaRpcTransactionInput],
        outputs: [KaspaRpcTransactionOutput],
        payload: Data
    ) -> UInt64 {
        // Consensus parameters (shared across nets)
        let massPerTxByte: UInt64 = 1
        let massPerScriptPubKeyByte: UInt64 = 10
        let massPerSigOp: UInt64 = 1000

        let estimatedBytes = estimateTransactionByteCount(
            version: version,
            inputs: inputs,
            outputs: outputs,
            payload: payload
        )

        let txSizeMass = estimatedBytes * massPerTxByte
        let spkMass = outputs.reduce(0) { $0 + (2 + UInt64($1.scriptPublicKey.script.count)) * massPerScriptPubKeyByte }
        let sigOpMass = inputs.reduce(0) { $0 + UInt64($1.sigOpCount) * massPerSigOp }

        return txSizeMass + spkMass + sigOpMass
    }

    private static func estimateTransactionByteCount(
        version: UInt16,
        inputs: [KaspaRpcTransactionInput],
        outputs: [KaspaRpcTransactionOutput],
        payload: Data
    ) -> UInt64 {
        let inputBytes = inputs.reduce(UInt64(0)) { total, input in
            var size: UInt64 = 32 + 4 // previous outpoint
            size += 8 + UInt64(input.signatureScript.count)
            size += 8 // sequence
            if version >= 1 {
                size += 2 // compute_budget
            }
            return total + size
        }

        let outputBytes = outputs.reduce(UInt64(0)) { total, output in
            total + 8 + 2 + 8 + UInt64(output.scriptPublicKey.script.count)
        }

        return 2 // version
            + 8 + inputBytes
            + 8 + outputBytes
            + 8 // lock time
            + 20 // subnetwork id
            + 8 // gas
            + 32 // payload hash
            + 8 + UInt64(payload.count)
    }

    /// The transaction's id as the chain computes it (rusty-kaspa `consensus/core/src/hashing/tx.rs`,
    /// `id_v0`): blake2b-256 keyed with `"TransactionID"` over the consensus encoding with the
    /// signature scripts excluded (an empty var-bytes in each one's place, no sig-op byte) and
    /// no mass commitment, payload included; all integers little-endian, `var_bytes` = u64
    /// length + bytes. The id is the digest's bytes in order - not reversed. Verified against
    /// a real KaChat self-send on chain (`f28587d7…`) and checked on every submit (see
    /// `KaPostsAPIClient.submitPayloadTx`). Every transaction the app builds is version 0.
    static func computeTransactionId(_ tx: KaspaRpcTransaction) -> String {
        var hasher = Blake2b(digestLength: 32, key: "TransactionID".data(using: .utf8))
        func le<T: FixedWidthInteger>(_ value: T) -> Data {
            var v = value.littleEndian
            return Data(bytes: &v, count: MemoryLayout<T>.size)
        }
        func varBytes(_ bytes: Data) -> Data { le(UInt64(bytes.count)) + bytes }

        hasher.update(le(tx.version))
        hasher.update(le(UInt64(tx.inputs.count)))
        for input in tx.inputs {
            var txIdBytes = Data(hexString: input.previousOutpoint.transactionId) ?? Data(repeating: 0, count: 32)
            if txIdBytes.count < 32 { txIdBytes = Data(repeating: 0, count: 32 - txIdBytes.count) + txIdBytes }
            hasher.update(Data(txIdBytes.prefix(32)))
            hasher.update(le(input.previousOutpoint.index))
            hasher.update(varBytes(Data()))       // signature script excluded from the id
            hasher.update(le(input.sequence))
        }
        hasher.update(le(UInt64(tx.outputs.count)))
        for output in tx.outputs {
            hasher.update(le(output.value))
            hasher.update(le(output.scriptPublicKey.version))
            hasher.update(varBytes(output.scriptPublicKey.script))
            if tx.version >= 1 {
                hasher.update(Data([0]))          // no covenant
            }
        }
        hasher.update(le(tx.lockTime))
        var subnetwork = tx.subnetworkId
        if subnetwork.count < 20 { subnetwork.append(Data(repeating: 0, count: 20 - subnetwork.count)) }
        hasher.update(Data(subnetwork.prefix(20)))
        hasher.update(le(tx.gas))
        hasher.update(varBytes(tx.payload))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func hexString(from string: String) -> String {
        return Data(string.utf8).hexString
    }
}

/// What a send costs. Change too small to keep goes to the fee (`selectUtxosForPayment`), which the
/// wallet loses like any other fee, so it counts in what the Review shows. It isn't part of the
/// base the speed tiers multiply, and a tier's extra comes out of it before anything more is spent.
struct SendFeeEstimate: Equatable {
    let networkFee: UInt64
    let foldedChange: UInt64

    func total(extra: UInt64) -> UInt64 {
        networkFee + max(extra, foldedChange)
    }
}
