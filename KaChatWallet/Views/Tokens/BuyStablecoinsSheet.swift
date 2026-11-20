import SwiftUI

/// The Wallet tab's Swap Stablecoins (owner's design, 2026-11-20): "Which stablecoin?" first, one row
/// per stablecoin KaPay holds (kUSDT today; more as KaPay adds them), then that coin's own place to
/// buy it. kUSDT goes straight on to Trestly: the address it should use, then Trestly's site inside
/// KaPay (`TrestlyConnectSheet`, `TrestlyBrowserView`), in the same sheet. This is the one way into
/// Trestly: Manage kUSDT's Address Actions no longer has Open Trestly.
struct BuyStablecoinsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tokens = TokenWallet.shared
    @State private var picked: WalletToken?

    var body: some View {
        ZStack {
            if let picked {
                TrestlyConnectSheet(token: picked)
                    .transition(.move(edge: .trailing))
            } else {
                chooser
                    .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)))
            }
        }
    }

    private var chooser: some View {
        VStack(spacing: 0) {
            SendStepHeader(titleText: Text("Swap Stablecoins"))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SendStepQuestion(text: "Which stablecoin?")
                    ForEach(tokens.tokens) { token in
                        row(token)
                    }
                    Text("More stablecoins will show here as KaPay adds them.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .background(Color(.systemBackground))
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

    private func row(_ token: WalletToken) -> some View {
        Button {
            Haptics.impact(.light)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { picked = token }
        } label: {
            HStack(spacing: 14) {
                TokenIcon(token: token, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: token.symbol)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("On Trestly, inside KaPay")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
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
