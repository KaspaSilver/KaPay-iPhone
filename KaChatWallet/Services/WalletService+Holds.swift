import Foundation

/// Coin holds read as sets, for kUSDT (`TokenWallet.apply`, `KusdtTransfer.prepare`): token coins
/// are held by `submitRpcTransaction` like any other input, but they aren't `UTXO`s, so the
/// filters in WalletService+Sending don't fit them.
extension WalletService {
    /// Every "txid:index" a send from this app is holding right now.
    func heldOutpointKeys() -> Set<String> {
        let now = Date()
        return Set(reservedOutpoints.filter { $0.value > now }.keys)
    }

    /// Every "txid:index" a "Not confirmed" send spent: the next automatic send from those coins
    /// must spend one of them too, so the two conflict and at most one can land.
    func unknownOutcomeKeys() -> Set<String> {
        let now = Date()
        return Set(unknownOutcomeOutpoints.filter { $0.value > now }.keys)
    }
}
