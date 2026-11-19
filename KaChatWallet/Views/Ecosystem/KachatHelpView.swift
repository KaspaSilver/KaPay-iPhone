import SwiftUI

/// The .kachat tab's "?" (owner's design, 2026-11-19): a full screen with two cards, How It Works
/// and Pricing, each opening its own page. Prices, the bond and the paid-period limits come from
/// the registry's params (`KachatLive.params`), so testnet shows its own; before the manifest has
/// loaded, mainnet's pinned tables stand in.
struct KachatHelpView: View {
    /// Names are live on this network (`KachatHubModel.isLive`).
    let isLive: Bool
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    NavigationLink {
                        KachatHowItWorksPage(isLive: isLive)
                    } label: {
                        KachatHelpCard(icon: "lightbulb",
                                       title: "How It Works",
                                       detail: "Claim, list, buy and make offers: what each one does.")
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        KachatPricingPage()
                    } label: {
                        KachatHelpCard(icon: "tag",
                                       title: "Pricing",
                                       detail: "What a name costs, and where the KAS goes.")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("About .kachat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
    }
}

/// One of the help screen's two cards: an accent icon, a title and one line, with a chevron.
private struct KachatHelpCard: View {
    let icon: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .foregroundColor(.accentColor)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundColor(.primary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - How It Works

private struct KachatHowItWorksPage: View {
    let isLive: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                step(icon: "at.badge.plus", title: "Claim",
                     detail: "Pick a free name and register it on Kaspa. It's yours: your name, your profile, your link.")
                step(icon: "arrow.clockwise", title: "Renew",
                     detail: "Renew before it expires to keep it. An expired name waits for its owner to renew it for a while before anyone else can claim it.")
                step(icon: "tag", title: "List",
                     detail: "Set a price. The name waits in an on-chain covenant, not with KaChat or anyone else, until someone buys it or you take it back.")
                step(icon: "cart", title: "Buy",
                     detail: "Pay the listed price. The payment reaches the seller and the name reaches you in the same transaction - both happen, or neither does.")
                step(icon: "hand.raised", title: "Offer",
                     detail: LocalizedStringKey(KaspaUnit.label(AppLocalization.string("Name your own price. Your KAS waits on chain until the seller accepts, you withdraw the offer, or it expires."))))
                step(icon: "checkmark.shield", title: "Trustless",
                     detail: "No middleman and no escrow account: Kaspa's own rules enforce every sale.")

                Group {
                    if isLive, KachatNamesService.networkName == "mainnet" {
                        Text("Live on Mainnet: names, prices and payments here are real KAS.")
                    } else if isLive {
                        Text("Live on Testnet: names, prices and payments here use TKAS on testnet-10. Mainnet names are live on Mainnet.")
                    } else {
                        Text("Nothing here is live yet.")
                    }
                }
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("How It Works")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
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

// MARK: - Pricing

private struct KachatPricingPage: View {
    @ObservedObject private var service = KachatNamesService.shared

    private var network: String { KachatNamesService.networkName }
    private var params: KachatNames.Params? { service.manifest?.params }

    private var registerPrices: [UInt64] {
        params?.registerPrices ?? KachatNames.Manifest.pinnedRegisterPrices[network] ?? KachatNames.Manifest.pinnedRegisterPrices["mainnet"] ?? []
    }

    private var renewPrices: [UInt64] {
        params?.renewPrices ?? KachatNames.Manifest.pinnedRenewPrices[network] ?? KachatNames.Manifest.pinnedRenewPrices["mainnet"] ?? []
    }

    /// The bond plus the registry deposit: locked with the name, returned on release (1 + 1 KAS
    /// on mainnet).
    private var lockedSompi: UInt64 { (params?.bond ?? 100_000_000) + (params?.gapValue ?? 100_000_000) }

    private var maxPeriods: Int64 { params?.maxYears ?? 2 }

    private static let lengthTitles: [LocalizedStringKey] = [
        "1 character", "2 characters", "3 characters", "4 characters", "5 or more characters"
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                priceTable

                info(icon: "leaf", title: "Where the price goes",
                     text: AppLocalization.string("The price goes to the miners - KaChat takes nothing."))
                info(icon: "lock", title: "Locked, not spent",
                     text: String(format: AppLocalization.string("%@ stays locked with your name while you hold it (bond + registry deposit). You get it back when you release the name."),
                                  KaspaUnit.amount(lockedSompi)))
                info(icon: "calendar", title: "Paying ahead",
                     text: String(format: AppLocalization.string("You can pay for up to %@ at a time."), KachatLive.periods(maxPeriods)))
                info(icon: "cart", title: "Buying and selling",
                     text: AppLocalization.string("The seller gets the full listed price: there's no marketplace fee."))
                info(icon: "network", title: "Network fee",
                     text: AppLocalization.string("Every claim, renewal, sale and offer also pays a small Kaspa network fee, shown before you confirm."))
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Pricing")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var priceTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Name length")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Claim")
                    .frame(width: 92, alignment: .trailing)
                Text("Renew")
                    .frame(width: 92, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            ForEach(0..<min(Self.lengthTitles.count, registerPrices.count, renewPrices.count), id: \.self) { tier in
                Divider().padding(.leading, 16)
                HStack {
                    Text(Self.lengthTitles[tier])
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: KaspaUnit.amount(registerPrices[tier]))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: 92, alignment: .trailing)
                    Text(verbatim: KaspaUnit.amount(renewPrices[tier]))
                        .font(.subheadline)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: 92, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            Divider().padding(.leading, 16)
            Text(verbatim: String(format: AppLocalization.string("Claim pays for the first %@. Renew pays for each one after that."),
                                  KachatLive.periods(1)))
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func info(icon: String, title: LocalizedStringKey, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(verbatim: text)
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
