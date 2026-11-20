import Foundation

// MARK: - Kaspa REST API transaction models

struct KaspaFullTransactionResponse: Codable {
    let transactionId: String
    let inputs: [KaspaFullTxInput]?
    let outputs: [KaspaFullTxOutput]
    let subnetworkId: String?
    let payload: String?
    let blockTime: UInt64?
    let blockHash: [String]?
    let isAccepted: Bool?
    let acceptingBlockHash: String?
    let acceptingBlockBlueScore: UInt64?
    let acceptingBlockTime: UInt64?
    let mass: String?  // API returns as String
    let hash: String?
    let version: UInt16?
    let lockTime: FlexibleUInt64?
    let gas: FlexibleUInt64?

    enum CodingKeys: String, CodingKey {
        case transactionId = "transaction_id"
        case inputs
        case outputs
        case subnetworkId = "subnetwork_id"
        case payload
        case blockTime = "block_time"
        case blockHash = "block_hash"
        case isAccepted = "is_accepted"
        case acceptingBlockHash = "accepting_block_hash"
        case acceptingBlockBlueScore = "accepting_block_blue_score"
        case acceptingBlockTime = "accepting_block_time"
        case mass
        case hash
        case version
        case lockTime = "lock_time"
        case gas
    }
}

extension KaspaFullTransactionResponse {
    nonisolated static let coinbaseSubnetworkId = "0100000000000000000000000000000000000000"

    /// A block reward: the coinbase subnetwork, and no inputs.
    var isCoinbase: Bool {
        if let subnetwork = subnetworkId?.lowercased(), !subnetwork.isEmpty {
            return subnetwork == Self.coinbaseSubnetworkId
        }
        return (inputs ?? []).isEmpty
    }

    /// Whether an address's history lists it. A block reward counts only once the chain accepted
    /// it: every block carries a coinbase paying its miner, but only those the selected chain
    /// accepts are ever applied - the rest never paid anything (a live mining address, checked
    /// 2026-10-20: 149 of its last 200 coinbases were not accepted). Everything else is listed
    /// as before: a payment just sent is briefly unaccepted too, and must still show.
    var belongsInHistory: Bool {
        !isCoinbase || isAccepted == true
    }
}

struct KaspaFullTxInput: Codable {
    // Flat structure - API returns fields directly, not nested
    let transactionId: String?
    let index: Int?
    let previousOutpointHash: String?
    let previousOutpointIndex: String?  // String in API
    let previousOutpointAddress: String? // Resolved address when using resolve_previous_outpoints
    let previousOutpointAmount: UInt64?
    let signatureScript: String?
    let sequence: FlexibleUInt64?
    let sigOpCount: FlexibleUInt8?

    enum CodingKeys: String, CodingKey {
        case transactionId = "transaction_id"
        case index
        case previousOutpointHash = "previous_outpoint_hash"
        case previousOutpointIndex = "previous_outpoint_index"
        case previousOutpointAddress = "previous_outpoint_address"
        case previousOutpointAmount = "previous_outpoint_amount"
        case signatureScript = "signature_script"
        case sequence
        case sigOpCount = "sig_op_count"
    }
}

/// Flexible decoder that handles both numeric and string representations of UInt64
struct FlexibleUInt64: Codable {
    let value: UInt64

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(UInt64.self) {
            value = intVal
        } else if let strVal = try? container.decode(String.self), let parsed = UInt64(strVal) {
            value = parsed
        } else {
            value = 0
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Flexible decoder that handles both numeric and string representations of UInt8
struct FlexibleUInt8: Codable {
    let value: UInt8

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(UInt8.self) {
            value = intVal
        } else if let strVal = try? container.decode(String.self), let parsed = UInt8(strVal) {
            value = parsed
        } else {
            value = 1
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

struct KaspaFullTxOutput: Codable {
    let transactionId: String?
    let index: Int?
    let amount: UInt64
    let scriptPublicKey: String?  // Simple hex string, not an object
    let scriptPublicKeyAddress: String?
    let scriptPublicKeyType: String?
    /// Version 1 transactions: the output's covenant binding (both nil without one). Part of
    /// the v1 signature hash.
    var covenantAuthorizingInput: UInt16? = nil
    var covenantId: String? = nil

    enum CodingKeys: String, CodingKey {
        case transactionId = "transaction_id"
        case index
        case amount
        case scriptPublicKey = "script_public_key"
        case scriptPublicKeyAddress = "script_public_key_address"
        case scriptPublicKeyType = "script_public_key_type"
        case covenantAuthorizingInput = "covenant_authorizing_input"
        case covenantId = "covenant_id"
    }
}

extension KaspaFullTransactionResponse {
    /// Direction + KAS amount relevant to `address`, for plain per-address transaction history
    /// lists (not chat/contact resolution — no sender/receiver naming). Uses the same
    /// input/output heuristics as WalletService's payment detection (see CLAUDE.md "Payment
    /// detection logic"): outgoing if `address` appears among the inputs (it signed the tx),
    /// incoming if it only appears among the outputs. Amount is the total sent to `address` for
    /// incoming, or the smallest non-`address` output for outgoing (the non-change output is
    /// usually the actual payment; change back to the sender is usually larger). Returns nil for
    /// a transaction with no clear relevance to `address` at all (shouldn't normally occur for a
    /// transaction that was fetched for this exact address in the first place).
    /// The transaction's fee: inputs minus outputs. Known only when the API resolved every
    /// input's amount (`resolve_previous_outpoints=light`, which the history fetches ask for);
    /// nil for a coinbase or when an input amount is missing.
    var feeSompi: UInt64? {
        guard let inputs, !inputs.isEmpty else { return nil }
        var totalIn: UInt64 = 0
        for input in inputs {
            guard let amount = input.previousOutpointAmount else { return nil }
            totalIn += amount
        }
        let totalOut = outputs.reduce(UInt64(0)) { $0 + $1.amount }
        return totalIn >= totalOut ? totalIn - totalOut : nil
    }

    /// "Fee 0.0001 KAS" for a history row, or nil when the fee cannot be known.
    func feeText() -> String? {
        guard let fee = feeSompi else { return nil }
        let kas = Double(fee) / 100_000_000.0
        let text = kas >= 0.001 ? String(format: "%.4f", kas) : String(format: "%.8f", kas)
        // "Fee %@" in the chosen language, as kUSDT's history rows say it
        return String(format: AppLocalization.string("Fee %@"), "\(text) \(KaspaUnit.symbol)")
    }

    func direction(for address: String) -> (isOutgoing: Bool, amountSompi: UInt64)? {
        let weAreSender = (inputs ?? []).contains { $0.previousOutpointAddress == address }

        var totalToUs: UInt64 = 0
        var totalToOthers: UInt64 = 0
        var recipientAmount: UInt64 = 0
        var haveRecipient = false

        for output in outputs {
            guard let addr = output.scriptPublicKeyAddress, !addr.isEmpty else { continue }
            if addr == address {
                totalToUs += output.amount
            } else {
                totalToOthers += output.amount
                if !haveRecipient || output.amount < recipientAmount {
                    recipientAmount = output.amount
                    haveRecipient = true
                }
            }
        }

        if weAreSender && totalToOthers > 0 {
            return (isOutgoing: true, amountSompi: haveRecipient ? recipientAmount : totalToOthers)
        } else if !weAreSender && totalToUs > 0 {
            return (isOutgoing: false, amountSompi: totalToUs)
        }
        return nil
    }
}

