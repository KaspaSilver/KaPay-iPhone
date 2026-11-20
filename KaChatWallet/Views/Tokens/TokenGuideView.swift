import SwiftUI

/// Settings > Help > kUSDT Guide: what kUSDT is and how KaPay handles it, a card per topic in the
/// style of the .kachat help (`KachatHelpView`). The texts it shares with the "Bridged by Trestly"
/// sheet (`TokenAboutCard`) are the same strings.
struct TokenGuideView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    TokenIcon(token: .kusdt, size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "kUSDT")
                            .font(.title2.weight(.bold))
                        Text("A dollar stablecoin on Kaspa")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)

                card(icon: "dollarsign.circle", title: "What It Is",
                     detail: "kUSDT is USDT from Ethereum and BNB Chain, held 1:1 in Trestly's vault and issued as a token on Kaspa. It isn't issued by Tether, and only Trestly can turn it back into USDT.")
                card(icon: "wallet.pass", title: "Where It Lives",
                     detail: "Your Chatting Address and your regular addresses can hold kUSDT. Quantum-resistant addresses can't. Receive gives you a fresh regular address, so a payment isn't tied to your .kachat name.")
                card(icon: "circle.hexagongrid", title: "1.5 KAS in Every Coin",
                     detail: "Every kUSDT coin holds 1.5 KAS. It goes along with the kUSDT when you send it.")
                card(icon: "arrow.up.circle", title: "Sending kUSDT",
                     detail: "A send takes a little KAS from the same address for the network fee, plus 1.5 KAS for your change coin when you keep some kUSDT. If the address is short, Fund This Address tops it up from another of your addresses.")
                card(icon: "arrow.triangle.merge", title: "Combine Coins",
                     detail: "Each payment you receive is its own coin with its own 1.5 KAS. Combine Coins, in an address's menu, merges them into one and gives the extra KAS back.")
                card(icon: "arrow.triangle.2.circlepath", title: "Swapping",
                     detail: "To swap KAS and kUSDT, or add to the pool, tap Swap Stablecoins on the Wallet tab and choose kUSDT. Trestly's own site opens inside KaPay, connected to the address you pick.")
                card(icon: "apps.iphone", title: "Your Other Apps",
                     detail: "KaChat and KaPost use the same words, so they show the same kUSDT and can send it. Swapping happens here in KaPay.")
                card(icon: "clock", title: "History",
                     detail: "kUSDT history is kept on this phone: sends, combines and payments received from now on. What happened before, or in another app, isn't shown.")
                card(icon: "exclamationmark.triangle", title: "The Risks",
                     detail: "Not independently audited yet. Hold only what you can afford to lose.", tint: .orange)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("kUSDT Guide")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func card(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey, tint: Color = .accentColor) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}
