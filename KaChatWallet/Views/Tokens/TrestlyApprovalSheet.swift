import SwiftUI

/// A trade Trestly's site asked for, as Trestly's own code prepared it (`TrestlyProvider.trade`):
/// the numbers come from its `prepare` (amounts as decimal strings), and `answer` resumes the provider.
@MainActor
final class TrestlyApproval: Identifiable {
    let id = UUID()
    let method: String
    let prepared: [String: Any]
    /// The quote the user approved before the pool moved (a requote), or nil.
    let seen: [String: Any]?
    /// The connected address's name.
    let from: String
    var answer: ((Bool) -> Void)?

    init(method: String, prepared: [String: Any], seen: [String: Any]?, from: String) {
        self.method = method
        self.prepared = prepared
        self.seen = seen
        self.from = from
    }

    /// Answers once; later calls do nothing.
    func respond(_ approved: Bool) {
        let a = answer
        answer = nil
        a?(approved)
    }

    func number(_ key: String) -> UInt64? { Self.number(prepared[key]) }
    func flag(_ key: String) -> Bool { prepared[key] as? Bool == true }

    static func number(_ v: Any?) -> UInt64? {
        if let s = v as? String { return UInt64(s) }
        if let n = v as? NSNumber { return n.uint64Value }
        return nil
    }
}

/// KaPay's approval for a trade on Trestly's site: what goes in and comes out, the minimum the site
/// set, the network fee, and Trestly's warnings. Nothing is signed until Approve; closing declines.
struct TrestlyApprovalSheet: View {
    let request: TrestlyApproval
    let onAnswer: (Bool) -> Void
    /// Approve wakes a moment after the sheet appears, so a tap meant for the page behind can't
    /// land on it.
    @State private var armed = false

    private func kas(_ sompi: UInt64?) -> String {
        guard let sompi else { return "--" }
        return KaspaUnit.amount(sompi)
    }
    private func kusdt(_ units: UInt64?) -> String {
        guard let units else { return "--" }
        return TokenAmount.amount(units, token: .kusdt)
    }
    /// A swap's two sides: KAS in and kUSDT out for a buy, the other way round for a sell.
    private func paid(_ v: UInt64?) -> String { isBuy ? kas(v) : kusdt(v) }
    private func received(_ v: UInt64?) -> String { isBuy ? kusdt(v) : kas(v) }
    private var isBuy: Bool { request.prepared["side"] as? String == "buy" }

    private var title: LocalizedStringKey {
        switch request.method {
        case "kusdt_addLiquidity": return "Add to the Pool"
        case "kusdt_removeLiquidity": return "Remove from the Pool"
        default: return isBuy ? "Buy kUSDT" : "Sell kUSDT"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        TokenIcon(token: .kusdt, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Trestly asks KaPay to")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(title)
                                .font(.title3.weight(.bold))
                        }
                    }

                    if request.seen != nil {
                        Label("The pool moved, and it now gives less than you approved. Nothing was sent. Check the new numbers.", systemImage: "arrow.triangle.2.circlepath")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        rows
                        Divider()
                        line("From", Text(verbatim: request.from))
                        line("Network Fee", Text(verbatim: String(format: AppLocalization.string("about %@"), kas(request.number("feeAbout")))))
                    }
                    .padding(16)
                    .background(sendKaspaGlass(cornerRadius: 18))

                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(note)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            .task {
                try? await Task.sleep(nanoseconds: 800_000_000)
                armed = true
            }
            .navigationTitle("Approve")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Decline") { onAnswer(false) }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    Haptics.impact(.medium)
                    onAnswer(true)
                } label: {
                    Text("Approve")
                        .font(.headline)
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Capsule().fill(Color.accentColor.opacity(request.flag("blocked") || !armed ? 0.4 : 1)))
                }
                .buttonStyle(.plain)
                .disabled(request.flag("blocked") || !armed)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
    }

    @ViewBuilder
    private var rows: some View {
        switch request.method {
        case "kusdt_addLiquidity":
            line("You Add", Text(verbatim: "\(kas(request.number("kasIn"))) + \(kusdt(request.number("tokensIn")))"), bold: true)
            if request.number("kasIn") != request.number("askedKasIn") || request.number("tokensIn") != request.number("askedTokensIn") {
                line("The Site Asked", Text(verbatim: "\(kas(request.number("askedKasIn"))) + \(kusdt(request.number("askedTokensIn")))"))
            }
            line("Pool Shares", Text(verbatim: request.number("quote").map(String.init) ?? "--"))
            if let before = TrestlyApproval.number(request.seen?["quote"]) {
                line("You Saw", Text(verbatim: String(before)))
            }
            line("Kept in the Position", Text(verbatim: kas(request.number("positionValue"))))
        case "kusdt_removeLiquidity":
            line("Pool Shares", Text(verbatim: request.number("shares").map(String.init) ?? "--"))
            line("You Receive About", Text(verbatim: "\(kas(request.number("kasOut"))) + \(kusdt(request.number("tokensOut")))"), bold: true)
            if let seen = request.seen {
                line("You Saw", Text(verbatim: "\(kas(TrestlyApproval.number(seen["kasOut"]))) + \(kusdt(TrestlyApproval.number(seen["tokensOut"])))"))
            }
        default:
            line("You Pay", Text(verbatim: paid(request.number("amountIn"))))
            line("You Receive", Text(verbatim: received(request.number("quote"))), bold: true)
            if let before = TrestlyApproval.number(request.seen?["quote"]) {
                line("You Saw", Text(verbatim: received(before)))
            }
            line("Minimum the Site Set", Text(verbatim: received(request.number("minOut"))))
            if isBuy {
                line("Kept in Your Token", Text(verbatim: kas(request.number("tokenValue"))))
            }
        }
    }

    private var warnings: [String] {
        var list: [String] = []
        if request.flag("paused") {
            list.append(AppLocalization.string("The pool is paused: swaps and new liquidity are stopped for now. Removing liquidity stays open."))
        }
        if let text = request.prepared["breaker"] as? String,
           let b = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            let fit = TrestlyApproval.number(b["fit"]) ?? 0
            list.append(String(format: AppLocalization.string("The pool's circuit breaker lets sells take out at most %@ more right now, so this sell would be refused."),
                               kas(TrestlyApproval.number(b["maxKasOut"]))))
            list.append(fit > 0
                        ? String(format: AppLocalization.string("The most that fits now is %@."), kusdt(fit))
                        : AppLocalization.string("No sell fits until the limit refills."))
        }
        if request.flag("belowMinimum") {
            list.append(AppLocalization.string("The pool pays less than the site's minimum right now, so this would be refused."))
        }
        if request.flag("offRatio") {
            list.append(AppLocalization.string("These amounts are too far off the pool's ratio: what's above it would go to the pool for nothing."))
        }
        if request.flag("unread") {
            list.append(AppLocalization.string("This position couldn't be checked on the Kaspa node. If it isn't there as recorded, the node refuses the removal and nothing is sent."))
        }
        if request.flag("feeShare") {
            list.append(AppLocalization.string("The network fee is more than a tenth of what this moves."))
        }
        return list
    }

    private var note: String {
        request.method == "kusdt_swap"
            ? AppLocalization.string("Built and checked by Trestly's own code inside KaPay. If the pool moves first, it quotes again: it goes ahead only at this quote or better, asks you again for less, and never goes below the site's minimum.")
            : AppLocalization.string("Built and checked by Trestly's own code inside KaPay. If the pool moves first and gives less, KaPay asks you again; it never takes below 99% of this quote.")
    }

    private func line(_ title: LocalizedStringKey, _ value: Text, bold: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer(minLength: 12)
            value
                .font(bold ? .subheadline.weight(.bold) : .subheadline.weight(.semibold))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
    }
}
