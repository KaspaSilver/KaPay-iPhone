import SwiftUI

/// Combine Coins, from an address's ⋮ (Manage kUSDT) or its page's options: the address's kUSDT
/// coins (up to 3 at a time) become one, sent to itself. Every coin holds 1.5 KAS, so each coin
/// merged away gives 1.5 KAS back to the address as plain KAS, less the network fee, which that
/// KAS pays (`KusdtTransfer.prepareCombine`). The review builds when it opens (exact fee and what
/// comes back), then swipe up.
struct TokenCombineView: View {
    let token: WalletToken
    let holding: TokenHolding
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tokens = TokenWallet.shared

    @State private var prepared: KusdtTransfer.Prepared?
    @State private var isPreparing = false
    @State private var prepareError: String?
    @State private var isSending = false
    @State private var failureMessage: String?
    @State private var sent: SentTransaction?
    /// The last submit's answer was lost: Try Again resends the same signed transaction.
    @State private var outcomeUnknown = false

    private var coinCount: Int { tokens.coins(of: holding).count }
    /// How many this round combines (3 at most per transaction).
    private var merging: Int { prepared?.spentCoins.count ?? min(coinCount, KusdtTransfer.maxTokenInputs) }

    var body: some View {
        SwipeUpToSendScrollView(
            screenTitle: "",
            onCancel: { dismiss() },
            titleText: Text("Combine Coins"),
            title: "Swipe up to Combine",
            isBusy: isSending,
            isEnabled: prepared != nil && !isPreparing,
            amountSompi: nil,
            recipient: nil,
            sent: sent,
            failureMessage: failureMessage,
            labels: .transaction(done: "Coins Combined"),
            onDone: { dismiss() },
            action: send
        ) {
            VStack(spacing: 18) {
                VStack(spacing: 6) {
                    TokenIcon(token: token, size: 44)
                    Text(verbatim: holding.label)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(verbatim: String(format: AppLocalization.string("%d coins into 1"), merging))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

                Text(verbatim: String(format: AppLocalization.string("Every %@ coin holds %@. Combining them into one coin gives the extra KAS back to this address as regular KAS, less the network fee. Your %@ stays the same."),
                                      token.symbol, KaspaUnit.amount(token.kasPerCoinSompi), token.symbol))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 14) {
                    line("Combined", TokenAmount.amount(prepared?.amount ?? 0, token: token), placeholder: prepared == nil)
                    line("KAS Held With It", "\(KaspaUnit.amount(UInt64(merging) * token.kasPerCoinSompi)) → \(KaspaUnit.amount(token.kasPerCoinSompi))")
                    Divider()
                    line("Network Fee", prepared.map { KaspaUnit.amount($0.fee) } ?? (isPreparing ? "…" : "--"))
                    line("Back to This Address", prepared.map { KaspaUnit.amount($0.kasBack) } ?? (isPreparing ? "…" : "--"), bold: true)
                }
                .padding(16)
                .background(sendKaspaGlass(cornerRadius: 18))

                if coinCount > KusdtTransfer.maxTokenInputs {
                    Label(String(format: AppLocalization.string("Up to %d coins combine at a time. Combine again for the rest."), KusdtTransfer.maxTokenInputs),
                          systemImage: "info.circle.fill")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if isPreparing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Building the transaction…")
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)
                } else if let prepareError {
                    VStack(spacing: 10) {
                        Label(prepareError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try Again") { Task { await prepare() } }
                            .font(.footnote.weight(.semibold))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .task { if prepared == nil, sent == nil { await prepare() } }
    }

    private func line(_ title: LocalizedStringKey, _ value: String, bold: Bool = false, placeholder: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(verbatim: placeholder ? "--" : value)
                .font(bold ? .subheadline.weight(.bold) : .subheadline.weight(.semibold))
                .monospacedDigit()
        }
    }

    private func prepare() async {
        guard !isPreparing else { return }
        isPreparing = true
        prepareError = nil
        defer { isPreparing = false }
        do {
            prepared = try await KusdtTransfer.prepareCombine(holding: holding, coins: tokens.coins(of: holding))
        } catch {
            prepared = nil
            prepareError = error.localizedDescription
        }
    }

    private func send() {
        guard !isSending else { return }
        failureMessage = nil
        isSending = true
        Task { @MainActor in
            defer { isSending = false }
            if !outcomeUnknown, let built = prepared, Date().timeIntervalSince(built.preparedAt) > 120 {
                await prepare()
            }
            guard let prepared else {
                failureMessage = prepareError ?? AppLocalization.string("The transaction couldn't be built. Nothing was sent.")
                return
            }
            do {
                let txid = try await KusdtTransfer.send(prepared)
                outcomeUnknown = false
                Haptics.success()
                sent = SentTransaction(txId: txid, amountSompi: nil, recipient: nil)
            } catch is SendOutcomeUnknownError {
                outcomeUnknown = true
                TokenWallet.shared.noteSent(prepared)
                failureMessage = AppLocalization.string("Not confirmed: the network didn't answer. It may still go through. Try Again resends the same transaction, so it can't be paid twice.")
            } catch {
                failureMessage = error.localizedDescription
            }
        }
    }
}
