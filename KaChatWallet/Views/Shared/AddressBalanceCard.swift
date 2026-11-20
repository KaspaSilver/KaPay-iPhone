import SwiftUI

/// The balance at the top of an address's own page (Chatting Address, a Manage Addresses address,
/// a kUSDT address): the address's name, its balance large, and a line under it. The same card
/// KaPlay's Wallet tab shows its chatting balance in.
struct AddressBalanceCard<Footer: View>: View {
    let label: String
    let amount: String
    /// Under the amount: worth in your currency, or what a kUSDT address holds with it.
    let detail: String?
    @ViewBuilder var footer: () -> Footer

    init(label: String, amount: String, detail: String?, @ViewBuilder footer: @escaping () -> Footer) {
        self.label = label
        self.amount = amount
        self.detail = detail
        self.footer = footer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(verbatim: amount)
                .font(.largeTitle.weight(.bold))
                .foregroundColor(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let detail {
                Text(verbatim: detail)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            footer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.accentColor.opacity(0.32), Color.accentColor.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.35), lineWidth: 0.8)
                )
        )
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

extension AddressBalanceCard where Footer == EmptyView {
    init(label: String, amount: String, detail: String?) {
        self.init(label: label, amount: amount, detail: detail) { EmptyView() }
    }
}

/// A Kaspa address's card, with its worth in your currency on mainnet (testnet coins aren't
/// worth anything). Its own view so price updates redraw only the card.
struct KaspaAddressBalanceCard: View {
    let label: String
    let sompi: UInt64
    @ObservedObject private var portfolio = PortfolioViewModel.shared

    var body: some View {
        AddressBalanceCard(label: label, amount: "\(KaspaUnit.groupedExact(sompi)) \(KaspaUnit.symbol)", detail: fiatText)
            .onAppear { portfolio.refreshSpotPriceIfStale() }
    }

    private var fiatText: String? {
        guard AppSettings.load().networkType == .mainnet,
              let price = portfolio.currentPriceUsd, price > 0 else { return nil }
        return formatFiatAmount(Double(sompi) / 100_000_000.0 * price, currency: portfolio.currentCurrency)
    }
}
