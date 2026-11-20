import Foundation

// MARK: - Transactions and address history from the Kaspa REST API

extension WalletService {
    func kaspaRestURL(path: String, queryItems: [URLQueryItem] = []) -> URL? {
        let settings = currentSettings
        guard var components = URLComponents(string: settings.kaspaRestAPIURL) else { return nil }
        components.path += path
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return components.url
    }

    /// A GET for one of the REST endpoints with a real timeout. `URLSession.shared.data(from:)`
    /// takes the session default of 60s per request, so a stalled indexer or explorer held a
    /// sync phase (and the flags it holds - see `retryUntilSuccess`) for a full minute per
    /// attempt. 20s matches the other REST clients in the app.
    nonisolated static func timedRequest(_ url: URL, timeout: TimeInterval = 20) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        return request
    }

    /// JSON decode off the main actor. WalletService is `@MainActor`, so a plain
    /// `JSONDecoder().decode` inside it runs on the main thread - fine for one transaction, a
    /// visible hitch for a 200-item history page.
    nonisolated static func decodeOffMain<T: Decodable>(_ type: T.Type, from data: Data) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode(T.self, from: data)
        }.value
    }

    /// Whether a history fetch actually finished, alongside what it got.
    ///
    /// `complete == false` means a page failed after its retries - the list is a partial answer,
    /// not the address's real history. Callers that render a list need this: without it a
    /// rate-limited or timed-out request is indistinguishable from an address with no
    /// transactions, and "No transactions yet." is a confident lie about someone's money.
    struct HistoryFetchResult {
        let transactions: [KaspaFullTransactionResponse]
        let complete: Bool
    }

    /// Retry the SAME page on a growing pause before giving up on it. api.kaspa.org is a shared
    /// public endpoint that rate-limits, and a single 429 used to end the whole fetch.
    private static let historyPageRetryDelaysSeconds: [Double] = [0, 0.6, 2, 5]

    /// Whether a quantum-safe (KIP-22) address has ever SPENT - the one event that puts its key
    /// on chain (receiving reveals nothing). true is marked locally and permanent; false means
    /// no spend in its history; nil when the history can't be read right now. Quantum addresses
    /// are young, so one page covers them.
    func quantumAddressSpentState(_ address: String) async -> Bool? {
        if WalletManager.shared.isQuantumAddressSpentLocally(address) { return true }
        // the account whose address this is; the pages below can span an account switch
        let owner = WalletManager.shared.currentWallet?.publicAddress
        // The whole history, a page at a time: a spend buried under later activity still
        // revealed the key (IOS-105). A found spend is marked for good, so the walk runs once per
        // address; a page that can't be read leaves the answer unknown, never "not spent".
        let lowered = address.lowercased()
        let pageSize = 200
        var offset = 0
        while offset < 50 * pageSize {
            guard let url = kaspaRestURL(
                path: "/addresses/\(address)/full-transactions",
                queryItems: [
                    URLQueryItem(name: "limit", value: "\(pageSize)"),
                    URLQueryItem(name: "offset", value: "\(offset)"),
                    URLQueryItem(name: "resolve_previous_outpoints", value: "light")
                ]
            ), let (data, response) = try? await URLSession.shared.data(for: Self.timedRequest(url)),
               let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let transactions = try? await Self.decodeOffMain([KaspaFullTransactionResponse].self, from: data) else {
                return nil
            }
            let spent = transactions.contains { tx in
                (tx.inputs ?? []).contains { $0.previousOutpointAddress?.lowercased() == lowered }
            }
            if spent {
                WalletManager.shared.markQuantumAddressSpent(address, owner: owner)
                return true
            }
            if transactions.count < pageSize { return false }
            offset += pageSize
        }
        // deeper than the walk goes: say so rather than claim the key is hidden
        return nil
    }

    /// One transaction from the Kaspa REST API by id; nil when it can't be read.
    func fetchFullTransaction(txId: String, resolvePrevious: Bool = true) async -> KaspaFullTransactionResponse? {
        let query = resolvePrevious ? [URLQueryItem(name: "resolve_previous_outpoints", value: "light")] : []
        guard let url = kaspaRestURL(path: "/transactions/\(txId)", queryItems: query),
              let (data, response) = try? await URLSession.shared.data(for: Self.timedRequest(url)),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        return try? JSONDecoder().decode(KaspaFullTransactionResponse.self, from: data)
    }

    func fetchFullTransactionsPaginated(
        for address: String,
        stopAtBlockTime: UInt64 = 0,
        pageSize: Int = 50,
        maxTransactions: Int = 10000
    ) async -> [KaspaFullTransactionResponse] {
        await fetchFullTransactionsResult(
            for: address,
            stopAtBlockTime: stopAtBlockTime,
            pageSize: pageSize,
            maxTransactions: maxTransactions
        ).transactions
    }

    func fetchFullTransactionsResult(
        for address: String,
        stopAtBlockTime: UInt64 = 0,
        pageSize: Int = 50,
        maxTransactions: Int = 10000
    ) async -> HistoryFetchResult {
        var allTransactions: [KaspaFullTransactionResponse] = []
        var offset = 0
        var pageCount = 0

        while allTransactions.count < maxTransactions {
            guard let url = kaspaRestURL(
                path: "/addresses/\(address)/full-transactions",
                queryItems: [
                    URLQueryItem(name: "limit", value: "\(pageSize)"),
                    URLQueryItem(name: "offset", value: "\(offset)"),
                    URLQueryItem(name: "resolve_previous_outpoints", value: "light")
                ]
            ) else {
                AppLog.log("[WalletService] Invalid URL for fetching transactions")
                break
            }

            if pageCount == 0 {
                AppLog.log("[WalletService] Kaspa API URL: %@", url.absoluteString)
            }

            // This page, retried on a backoff. Nil means every attempt failed, which is a
            // genuinely incomplete fetch rather than the end of the list.
            var pageTransactions: [KaspaFullTransactionResponse]?
            let pageRequest = Self.timedRequest(url)
            for (attempt, delay) in Self.historyPageRetryDelaysSeconds.enumerated() {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                if Task.isCancelled { return HistoryFetchResult(transactions: allTransactions, complete: false) }
                do {
                    let (data, response) = try await URLSession.shared.data(for: pageRequest)
                    guard let httpResponse = response as? HTTPURLResponse else { continue }
                    guard (200...299).contains(httpResponse.statusCode) else {
                        // 4xx other than 429 will not improve by asking again.
                        let worthRetrying = httpResponse.statusCode == 429 || httpResponse.statusCode >= 500
                        AppLog.log("[WalletService] History page %d: HTTP %d%@",
                                   pageCount, httpResponse.statusCode, worthRetrying ? " (retrying)" : "")
                        if !worthRetrying { break }
                        continue
                    }
                    // Up to 200 full transactions per page - decoded off the main actor.
                    pageTransactions = try await Self.decodeOffMain([KaspaFullTransactionResponse].self, from: data)
                    break
                } catch {
                    AppLog.log("[WalletService] History page %d attempt %d failed: %@",
                               pageCount, attempt + 1, error.localizedDescription)
                }
            }

            guard let transactions = pageTransactions else {
                // Out of retries. Hand back what we have, marked incomplete, so the caller can
                // say so rather than presenting a short list as the whole story.
                return HistoryFetchResult(transactions: allTransactions, complete: false)
            }

            if transactions.isEmpty {
                break
            }

            allTransactions.append(contentsOf: transactions)

            // Check if we've reached transactions older than our stop time
            if stopAtBlockTime > 0 {
                // Find the oldest transaction in this batch
                let oldestBlockTime = transactions.compactMap { $0.blockTime }.min() ?? 0
                if oldestBlockTime > 0 && oldestBlockTime <= stopAtBlockTime {
                    AppLog.log("[WalletService] Pagination: reached transactions older than stopAtBlockTime, stopping")
                    break
                }
            }

            // If we got fewer than pageSize, we've reached the end
            if transactions.count < pageSize {
                break
            }

            // Continue to next page
            offset += pageSize
            pageCount += 1

            if pageCount > 0 {
                AppLog.log("[WalletService] Pagination: fetched page %d, total transactions: %d, offset: %d",
                      pageCount + 1, allTransactions.count, offset)
            }

        }

        if allTransactions.count >= maxTransactions {
            AppLog.log("[WalletService] Pagination: reached max transactions limit (%d)", maxTransactions)
        }

        return HistoryFetchResult(transactions: allTransactions, complete: true)
    }

    /// A pay-to-script-hash address (`kaspa:p...` / `kaspatest:p...`): a contract.
    nonisolated static func isScriptAddress(_ address: String?) -> Bool {
        guard let address, !address.isEmpty, let parsed = KaspaAddress(address: address.lowercased()) else { return false }
        return parsed.type == .scriptHash
    }

    func fetchKaspaFullTransaction(
        txId: String,
        retries: Int,
        delayNs: UInt64
    ) async -> KaspaFullTransactionResponse? {
        guard let url = kaspaRestURL(
            path: "/transactions/\(txId)",
            queryItems: [URLQueryItem(name: "resolve_previous_outpoints", value: "light")]
        ) else { return nil }
        AppLog.log("[WalletService] Kaspa REST full tx request: %@", String(txId.prefix(12)))

        let request = Self.timedRequest(url)
        for attempt in 1...max(1, retries) {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    try? await Task.sleep(nanoseconds: delayNs)
                    continue
                }
                let fullTx = try JSONDecoder().decode(KaspaFullTransactionResponse.self, from: data)
                AppLog.log("[WalletService] Kaspa REST full tx resolved for %@ on attempt %d",
                      String(txId.prefix(12)), attempt)
                return fullTx
            } catch {
                try? await Task.sleep(nanoseconds: delayNs)
            }
        }

        return nil
    }
}
