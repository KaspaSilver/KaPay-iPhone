import Foundation
import SwiftUI

/// Bridges a single Kaspa-amount text field to an optional live fiat mirror. Every method here
/// returns the canonical KAS string the caller should assign to its own existing "amount in KAS"
/// `@State` var (and downstream send/Max logic) - regardless of which unit the user is actually
/// typing in (`isFiatMode`), this object owns only the field's own display text and mode.
///
/// `priceInCurrency` (1 KAS's price in the wallet's selected fiat currency - see
/// `PortfolioViewModel.currentPriceUsd`) and `currency` are passed into each call fresh rather
/// than captured once, since both can change live while this field is on screen (a price refresh
/// landing async, a currency switched in Settings). Mirrors the Android `KaspaFiatAmountState`.
@MainActor
final class KaspaFiatAmountState: ObservableObject {
    @Published private(set) var isFiatMode = false
    @Published private(set) var displayText = ""
    /// The canonical KAS string last handed to the caller. A unit switch only changes what's
    /// shown, never the amount: converting back from the 2-decimal currency figure used to put a
    /// different KAS number on screen than the one the caller still held and would send.
    private var kasText = ""

    private func kasFromDisplay(priceInCurrency: Double?) -> Double? {
        guard let entered = Double(displayText) else { return nil }
        guard isFiatMode else { return entered }
        guard let price = priceInCurrency, price > 0 else { return nil }
        return entered / price
    }

    /// Call on the field's own `onChange`/binding-set. Returns the resulting canonical KAS string.
    @discardableResult
    func onDisplayTextChange(_ text: String, priceInCurrency: Double?) -> String {
        displayText = text
        guard isFiatMode else {
            kasText = text
            return text
        }
        kasText = kasFromDisplay(priceInCurrency: priceInCurrency).map { formatKasAmountPlain($0) } ?? ""
        return kasText
    }

    /// Caller's own Max button already knows the current max sendable KAS (fee-aware, etc.) -
    /// this just also reflects it into whichever unit is currently being displayed. Returns the
    /// canonical KAS string.
    @discardableResult
    func setMaxKas(_ maxKas: Double, priceInCurrency: Double?) -> String {
        if isFiatMode, let priceInCurrency, priceInCurrency > 0 {
            displayText = String(format: "%.2f", maxKas * priceInCurrency)
        } else {
            displayText = formatKasAmountPlain(maxKas)
        }
        kasText = formatKasAmountPlain(maxKas)
        return kasText
    }

    /// Flips units, carrying today's typed number over converted into the other one rather than
    /// clearing the field. No-ops if there's no live price yet to convert with. Back in KAS it
    /// shows the exact amount the caller holds (`kasText`), not one worked back from the rounded
    /// currency figure.
    func toggleMode(priceInCurrency: Double?) {
        guard let priceInCurrency, priceInCurrency > 0 else { return }
        let kas = Double(kasText) ?? kasFromDisplay(priceInCurrency: priceInCurrency)
        isFiatMode.toggle()
        guard let kas else {
            displayText = ""
            return
        }
        if isFiatMode {
            displayText = String(format: "%.2f", kas * priceInCurrency)
        } else {
            displayText = kasText.isEmpty ? formatKasAmountPlain(kas) : kasText
        }
    }

    /// Live value of whichever unit ISN'T currently being typed, for the small label shown next
    /// to Max - nil while nothing's entered yet, or (KAS-typing mode only) while there's no live
    /// price to convert with.
    func conversionLabelText(priceInCurrency: Double?, currency: AppCurrency) -> String? {
        guard let kas = kasFromDisplay(priceInCurrency: priceInCurrency) else { return nil }
        if isFiatMode {
            // the KAS that will be sent, exactly
            return "\(kasText.isEmpty ? formatKasAmountPlain(kas) : kasText) \(KaspaUnit.symbol)"
        }
        guard let priceInCurrency, priceInCurrency > 0 else { return nil }
        return formatFiatAmount(kas * priceInCurrency, currency: currency)
    }

    /// Unlike Android's equivalent (whose per-screen `remember` state gets torn down for free
    /// whenever its conditionally-composed dialog/payment-mode row is dismissed), this object is
    /// a single `@StateObject` living with the whole `ChatDetailView`/dialog for as long as it's
    /// on screen - callers must call this explicitly wherever they already reset their own
    /// canonical KAS `@State` var (leaving payment mode, a successful send, a dialog dismissing).
    func reset() {
        isFiatMode = false
        displayText = ""
        kasText = ""
    }
}
