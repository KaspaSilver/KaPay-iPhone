import SwiftUI

// MARK: - The Wallet tab's balance card

/// A token's page of the Wallet tab's balance card (swiped to from Total Balance): the same card,
/// in the token's green, with its balance, dollar value, where it's held and the KAS held with it.
/// Tapping it opens the token's screen.
struct TokenBalanceCard: View {
    let token: WalletToken
    @ObservedObject private var tokens = TokenWallet.shared

    var body: some View {
        let units = tokens.balance(of: token)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    TokenIcon(token: token, size: 22)
                    Text(verbatim: String(format: AppLocalization.string("%@ Balance"), token.symbol))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    TapToManageLabel()
                }
                Text(verbatim: units.map { TokenAmount.amount($0, token: token) } ?? "--")
                    .font(.largeTitle.weight(.bold))
                    .foregroundColor(.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                HStack(spacing: 8) {
                    if let units, let dollars = TokenAmount.dollars(units, token: token) {
                        Text(verbatim: dollars)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    TokenSampleBadge()
                }
            }

            Divider()

            HStack(alignment: .top, spacing: 16) {
                part(title: "Held On", value: tokens.heldOnText(token))
                part(title: "KAS Held With It", value: KaspaUnit.amount(tokens.kasHeld(by: token)))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(
                    colors: [TokenIcon.green.opacity(0.32), TokenIcon.green.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(TokenIcon.green.opacity(0.35), lineWidth: 0.8)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .task { await tokens.refreshIfStale() }
    }

    private func part(title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(verbatim: value)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Tap to Manage ›" in a balance card's top corner: the card opens its screen (Manage Addresses,
/// or the token's).
struct TapToManageLabel: View {
    var body: some View {
        HStack(spacing: 3) {
            Text("Tap to Manage")
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
        }
        .font(.caption.weight(.semibold))
        .foregroundColor(.accentColor)
        .lineLimit(1)
        .layoutPriority(1)
    }
}

/// The Wallet tab's balance cards side by side, one showing: a swipe drags them with the finger
/// and lets go onto the next or the previous one, and every change of page (a swipe, a flick, a
/// dot) slides with the same spring. Its own drag rather than a paged `TabView`, which only slid
/// when the change came inside an animation and fought the tab's scroll view for the swipe.
struct SlidingCardPager: View {
    let pages: [AnyView]
    @Binding var page: Int
    @State private var drag: CGFloat = 0

    static let slide = Animation.spring(response: 0.38, dampingFraction: 0.86)

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            HStack(spacing: 0) {
                ForEach(pages.indices, id: \.self) { index in
                    pages[index]
                        .frame(width: width, alignment: .top)
                }
            }
            .frame(width: width, alignment: .leading)
            .offset(x: -CGFloat(page) * width + drag)
            .animation(Self.slide, value: page)
            .contentShape(Rectangle())
            // simultaneous, so the tab still scrolls up and down from the card
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        let dx = value.translation.width
                        // past the first or the last card it gives, but only a little
                        let atEdge = (page == 0 && dx > 0) || (page == pages.count - 1 && dx < 0)
                        drag = atEdge ? dx / 3 : dx
                    }
                    .onEnded { value in
                        let predicted = value.predictedEndTranslation.width
                        var next = page
                        if drag < -width * 0.25 || predicted < -width * 0.5 { next = min(page + 1, pages.count - 1) }
                        if drag > width * 0.25 || predicted > width * 0.5 { next = max(page - 1, 0) }
                        if next != page { Haptics.impact(.light) }
                        withAnimation(Self.slide) {
                            page = next
                            drag = 0
                        }
                    }
            )
        }
        .clipped()
    }
}

/// The pills under the Wallet tab's balance card, one per card ("Kaspa", "kUSDT"): the card
/// showing is filled, and a tap slides to that card (owner's design, 2026-11-19, in place of dots).
struct BalancePagePills: View {
    /// Each card's name, already localized.
    let titles: [String]
    @Binding var selected: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(titles.indices, id: \.self) { index in
                let isSelected = index == selected
                Button {
                    guard !isSelected else { return }
                    Haptics.impact(.light)
                    withAnimation(SlidingCardPager.slide) { selected = index }
                } label: {
                    Text(verbatim: titles[index])
                        .font(.caption.weight(.semibold))
                        .foregroundColor(isSelected ? .black : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial))
                        )
                        .overlay(Capsule().stroke(Color.accentColor.opacity(isSelected ? 0 : 0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.2), value: selected)
    }
}

// MARK: - Activity

/// One line of a token's history, drawn like a transaction on a Kaspa address's page (Manage
/// Addresses): the circled arrow, Received or Sent in its colour, the transaction id, the date
/// and time; on the right the signed amount, the fee when this phone paid it, and the explorer
/// mark. A tap opens the transaction in the explorer.
struct TokenActivityRow: View {
    let token: WalletToken
    let row: TokenActivity
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    var body: some View {
        Button {
            guard let txid = row.txid,
                  let url = settingsViewModel.settings.kaspaExplorer.txURL(for: txid) else { return }
            Haptics.impact(.light)
            UIApplication.shared.open(url)
        } label: {
            content
        }
        .buttonStyle(.plain)
    }

    private var content: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(tint)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(tint)
                    if row.pending {
                        Text("Pending")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.orange)
                    }
                }
                Text(verbatim: row.txid ?? row.counterparty)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: sign + TokenAmount.amount(row.units, token: token))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(tint)
                    .monospacedDigit()
                if let fee = row.fee {
                    Text(verbatim: String(format: AppLocalization.string("Fee %@"), Self.feeText(fee)))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if row.txid != nil {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// As Kaspa's rows write a fee: four decimals, eight under 0.001 KAS.
    static func feeText(_ sompi: UInt64) -> String {
        let kas = Double(sompi) / 100_000_000.0
        return (kas >= 0.001 ? String(format: "%.4f", kas) : String(format: "%.8f", kas)) + " " + KaspaUnit.symbol
    }

    /// A swap is in when it bought kUSDT, out when it sold it.
    private var isIn: Bool {
        row.kind == .received || row.kind == .bridged || (row.kind == .swapped && row.outgoing != true)
    }

    /// A combine moves nothing in or out: no sign.
    private var sign: String { row.kind == .combined ? "" : (isIn ? "+" : "-") }

    private var tint: Color {
        switch row.kind {
        case .received, .bridged: return .green
        case .swapped: return isIn ? .green : .red
        case .sent: return .red
        case .combined: return .accentColor
        }
    }

    private var icon: String {
        switch row.kind {
        case .received, .bridged: return "arrow.down.circle.fill"
        case .sent: return "arrow.up.circle.fill"
        case .swapped: return "arrow.triangle.2.circlepath.circle.fill"
        case .combined: return "arrow.triangle.merge"
        }
    }

    private var title: LocalizedStringKey {
        switch row.kind {
        case .received: return "Received"
        case .sent: return "Sent"
        case .swapped: return "Swapped"
        case .bridged: return "Bridged In"
        case .combined: return "Combined Coins"
        }
    }
}

// MARK: - Receive

/// Receive a token, on the shared receive screen (`AddressReceiveView`). Fresh Address first
/// (owner's call, 2026-11-19: privacy from the start): a brand-new regular address of yours, so
/// the payment can't be tied to your name; or the Chatting Address, which shows your .kachat name
/// and profile. From an address's own page (`fixedHolding`) it shows that address only. A fresh
/// address goes on Manage Addresses' list once it's copied or shared.
struct TokenReceiveSheet: View {
    let token: WalletToken
    let chattingAddress: String
    /// Receive on this address only (its own page's Receive): no Fresh / Chatting choice.
    var fixedHolding: TokenHolding? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var useFresh = true
    @State private var fresh: (index: Int, address: String)?

    private var shownAddress: String {
        if let fixedHolding { return fixedHolding.address }
        return useFresh ? (fresh?.address ?? "") : chattingAddress
    }

    private var privacyNote: ReceiveNote {
        if let fixedHolding { return fixedHolding.isChatting ? ReceiveNotes.chattingAddress : ReceiveNotes.spendingAddress }
        return useFresh ? ReceiveNotes.freshAddress : ReceiveNotes.chattingAddress
    }

    var body: some View {
        NavigationStack {
            AddressReceiveView(
                title: String(format: AppLocalization.string("Receive %@"), token.symbol),
                address: shownAddress,
                addressLabel: fixedHolding?.label,
                privacyNote: privacyNote,
                notes: [
                    ReceiveNote(kind: .allowed, text: String(format: AppLocalization.string("Only %@ on Kaspa, or KAS, can be sent here."), token.symbol)),
                    ReceiveNote(kind: .warning, text: AppLocalization.string("Don't send USDT from Ethereum, BNB Chain or an exchange to this address: it would be lost. Bridge it to Kaspa on Trestly first.")),
                ],
                onHandedOut: revealIfFresh,
                icon: { TokenIcon(token: token, size: 34) },
                choices: {
                    if fixedHolding == nil {
                        HStack(spacing: 10) {
                            SelectablePill(title: "Fresh Address", selected: useFresh) { useFresh = true }
                            SelectablePill(title: "Chatting Address", selected: !useFresh) { useFresh = false }
                        }
                    }
                }
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            if fresh == nil, fixedHolding == nil { fresh = TokenWallet.shared.freshReceiveAddress() }
        }
    }

    /// A fresh address handed out goes on the list (and is watched) from now on.
    private func revealIfFresh() {
        guard fixedHolding == nil, useFresh, let fresh else { return }
        Task { await TokenWallet.shared.revealFreshReceiveAddress(fresh.index) }
    }
}
