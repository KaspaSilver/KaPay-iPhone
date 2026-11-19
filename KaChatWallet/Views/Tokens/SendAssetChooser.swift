import SwiftUI

/// The Wallet tab's Send (owner's design, 2026-11-19): "What are you sending?" first, Kaspa or a
/// token (kUSDT), each with its balance; a tap goes on to that one's steps in the same sheet
/// (`WithdrawKaspaView` or `TokenSendView`).
struct SendAssetChooser: View {
    @EnvironmentObject private var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var hotWallet = HotWalletBalance.shared
    @ObservedObject private var tokens = TokenWallet.shared

    private enum Choice: Equatable {
        case kaspa
        case token(WalletToken)
    }

    @State private var choice: Choice?

    var body: some View {
        ZStack {
            switch choice {
            case .none:
                chooser.transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)))
            case .kaspa:
                if let wallet = walletManager.currentWallet {
                    WithdrawKaspaView(fromAddress: wallet.publicAddress, availableBalanceSompi: wallet.balanceSompi)
                        .transition(.move(edge: .trailing))
                }
            case .token(let token):
                TokenSendView(token: token)
                    .transition(.move(edge: .trailing))
            }
        }
    }

    private var chooser: some View {
        VStack(spacing: 0) {
            SendStepHeader(titleText: Text("Send"))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SendStepQuestion(text: "What are you sending?")
                    option(
                        icon: AnyView(
                            Image("KaspaLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 44, height: 44)
                                .clipShape(Circle())
                        ),
                        title: "Kaspa",
                        subtitle: KaspaUnit.symbol,
                        amount: kaspaTotal.map(KaspaUnit.amount)
                    ) { pick(.kaspa) }
                    ForEach(tokens.tokens) { token in
                        option(
                            icon: AnyView(TokenIcon(token: token, size: 44)),
                            title: LocalizedStringKey(token.symbol),
                            subtitle: AppLocalization.string("Bridged USDT"),
                            amount: tokens.balance(of: token).map { TokenAmount.amount($0, token: token) },
                            badge: TokenWallet.isSampleData
                        ) { pick(.token(token)) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .background(Color(.systemBackground))
        .task { await tokens.refreshIfStale() }
        .safeAreaInset(edge: .bottom) {
            Button { dismiss() } label: {
                Text("Cancel")
                    .font(.headline)
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    /// Every hot address together, as the balance card shows it; nil until both parts are known.
    private var kaspaTotal: UInt64? {
        guard let wallet = walletManager.currentWallet, let chatting = wallet.balanceSompi,
              let spending = hotWallet.spendingSompi(for: wallet) else { return nil }
        return chatting + spending
    }

    private func pick(_ next: Choice) {
        Haptics.impact(.light)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { choice = next }
    }

    private func option(icon: AnyView, title: LocalizedStringKey, subtitle: String, amount: String?,
                        badge: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.headline)
                            .foregroundColor(.primary)
                        if badge { TokenSampleBadge() }
                    }
                    Text(verbatim: subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
                Text(verbatim: amount ?? "--")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(sendKaspaGlass(cornerRadius: 20))
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }
}
