import SwiftUI

// MARK: - Making one

/// Request Payment, from the Wallet tab's up/down-arrow sheet: an amount, an optional memo and
/// where it's paid - a brand-new address, or one you pick - handed out as a link (Copy or Share).
/// Opening it in KaPay or KaChat gives Send Kaspa with all of it filled in. Signed by the
/// chatting address, so whoever pays sees who asked.
struct CreatePaymentRequestView: View {
    enum Destination: Hashable {
        /// A brand-new address, never revealed, used or handed out.
        case fresh
        /// One of your addresses, picked from the list: the chatting address or a spending one.
        case chosen
    }

    @EnvironmentObject private var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var fiatAmountState = KaspaFiatAmountState()

    @State private var destination: Destination = .fresh
    /// The brand-new address reserved for this request (`reserveFreshSpendingAddresses`) - only
    /// when it's copied or shared, so opening the screen and cancelling uses none up. Once per
    /// screen: Copy and Share both reuse it, so no two requests share an address.
    @State private var freshAddress: String?
    /// The next brand-new address, shown before it's reserved.
    @State private var nextFreshAddress: String?
    @State private var chosenAddress: String?
    @State private var amountInput = ""
    @State private var memo = ""
    @State private var copied = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var shareItem: ShareURL?

    private struct ShareURL: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private var chattingAddress: String? { walletManager.currentWallet?.publicAddress }

    private var amountSompi: UInt64? {
        guard let sompi = KaspaUnit.sompi(fromUserText: amountInput), sompi > 0 else { return nil }
        return sompi
    }

    /// Ready to hand out: an amount, and an address (or a fresh one to be made).
    private var canMake: Bool {
        amountSompi != nil && (destination == .fresh || chosenAddress != nil)
    }

    /// Like a send, in steps: where to be paid, how much (on the app's keypad), then the review
    /// with the memo, Copy and Share.
    private enum Step: Int { case destination, amount, review }
    @State private var step: Step = .destination
    @State private var stepForward = true

    /// The address the request pays: the fresh one (reserved, else the one it will be), or the pick.
    private var payeeAddress: String? {
        switch destination {
        case .fresh: return freshAddress ?? nextFreshAddress
        case .chosen: return chosenAddress
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                switch step {
                case .destination: destinationStep.transition(stepTransition)
                case .amount: amountStep.transition(stepTransition)
                case .review: reviewStep.transition(stepTransition)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: amountInput) { _ in copied = false }
            .onChange(of: memo) { _ in copied = false }
            .onChange(of: destination) { _ in copied = false }
            .onChange(of: chosenAddress) { _ in copied = false }
            .task {
                // derived, not reserved: opening the screen and cancelling uses no address up.
                // Checked on chain, so the preview never shows a slot already used.
                nextFreshAddress = await WalletManager.shared.verifiedFreshQuantumSlot()?.address
            }
            .sheet(item: $shareItem) { item in
                PaymentRequestShareSheet(url: item.url)
            }
        }
    }

    private var stepTransition: AnyTransition {
        .asymmetric(insertion: .move(edge: stepForward ? .trailing : .leading),
                    removal: .move(edge: stepForward ? .leading : .trailing))
    }

    private func go(to next: Step) {
        dismissSystemKeyboard()
        stepForward = next.rawValue > step.rawValue
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { step = next }
        }
    }

    // MARK: Where

    private var destinationStep: some View {
        SendStepScreen(title: Text("Request Payment"), onCancel: { dismiss() }, canContinue: payeeAddress != nil) {
            go(to: .amount)
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SendStepQuestion(text: "Where do you want to be paid?")
                    HStack(spacing: 10) {
                        SelectablePill(title: "Fresh Address", selected: destination == .fresh) {
                            destination = .fresh
                        }
                        SelectablePill(title: "Choose an Address", selected: destination == .chosen) {
                            destination = .chosen
                        }
                    }

                    switch destination {
                    case .fresh:
                        if let address = freshAddress ?? nextFreshAddress {
                            AddressResolutionCard(address: address)
                            Text("A brand-new address of yours that has never been used or handed out.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        } else {
                            HStack { Spacer(); ProgressView(); Spacer() }
                                .padding(.vertical, 18)
                        }
                    case .chosen:
                        // the list right here, no sheet: tap the address that gets paid
                        Text("Pick which of your addresses gets paid.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        OwnAddressList(selected: chosenAddress) { picked in
                            chosenAddress = picked.address
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: How much

    private var amountStep: some View {
        SendStepScreen(title: Text("Request Payment"), onBack: { go(to: .destination) }, onCancel: { dismiss() },
                       continueTitle: "Review", canContinue: amountSompi != nil) {
            go(to: .review)
        } content: {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    SendStepQuestion(text: "How much?")
                    if let payeeAddress {
                        SendInfoPill {
                            HStack(spacing: 4) {
                                Text("Paid to")
                                Text(verbatim: "\(payeeAddress.prefix(14))...\(payeeAddress.suffix(6))")
                                    .font(.caption.monospaced())
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                KaspaKeypadAmountEntry(
                    fiatAmountState: fiatAmountState,
                    onAmountChange: { amountInput = $0 },
                    showsMax: false,
                    onMax: {}
                )
            }
        }
    }

    // MARK: Review

    private var reviewStep: some View {
        SendStepScreen(title: Text("Review"), onBack: { go(to: .amount) }, onCancel: { dismiss() },
                       continueTitle: copied ? "Copied" : "Copy Payment Request",
                       canContinue: canMake && !isWorking) {
            copy()
        } content: {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 6) {
                        Text("You're requesting")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        if let amountSompi {
                            Text(verbatim: "\(KaspaUnit.plain(amountSompi)) \(KaspaUnit.symbol)")
                                .font(.system(size: 40, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                            if let price = PortfolioViewModel.shared.currentPriceUsd, price > 0 {
                                Text(verbatim: formatFiatAmount(Double(amountSompi) / 100_000_000.0 * price,
                                                                currency: PortfolioViewModel.shared.currentCurrency))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Paid to")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        AddressResolutionCard(address: payeeAddress)
                    }

                    VStack(alignment: .trailing, spacing: 6) {
                        TextField("What it's for (optional)", text: $memo, axis: .vertical)
                            .lineLimit(1...4)
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(.regularMaterial)
                            )
                            .onChange(of: memo) { value in
                                if value.count > PaymentRequest.memoLimit {
                                    memo = String(value.prefix(PaymentRequest.memoLimit))
                                }
                            }
                        Text(verbatim: "\(memo.count)/\(PaymentRequest.memoLimit)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Text("The memo shows to whoever pays, but doesn't travel with the payment.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }

                    Button(action: share) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canMake || isWorking)

                    Text("Anyone who opens it in KaPay or KaChat gets Send Kaspa with this filled in, and sees it was made by your chatting address (signed with its key).")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    /// The request to hand out, signed by your chatting address (whoever pays sees it's from you,
    /// even when it's paid to a spending address, which has no identity). A fresh address is
    /// reserved here, the first time it's needed.
    private func makeRequest() async -> PaymentRequest? {
        guard let sompi = amountSompi else { return nil }
        let address: String
        switch destination {
        case .fresh:
            if let freshAddress {
                address = freshAddress
            } else {
                guard let reserved = await walletManager.reserveFreshSpendingAddresses(count: 1).first?.address else {
                    errorMessage = AppLocalization.string("Couldn't make a new address. Please try again.")
                    return nil
                }
                freshAddress = reserved
                address = reserved
                // watched from now on, so its payment shows the moment it lands
                WalletService.shared.checkAndResubscribeIfNeeded()
            }
        case .chosen:
            guard let chosenAddress else { return nil }
            address = chosenAddress
        }
        let unsigned = PaymentRequest(address: address, amountSompi: sompi, memo: memo,
                                      toChattingAddress: address == chattingAddress)
        // an account whose key isn't on this phone can still ask; the payer is told it's unsigned
        guard let creator = chattingAddress, let key = WalletManager.shared.getPrivateKey() else { return unsigned }
        return unsigned.signed(by: creator, privateKey: key) ?? unsigned
    }

    private func copy() {
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            guard let request = await makeRequest() else { return }
            UIPasteboard.general.string = request.shareURLString
            Haptics.success()
            copied = true
        }
    }

    private func share() {
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            guard let request = await makeRequest(), let url = URL(string: request.shareURLString) else { return }
            shareItem = ShareURL(url: url)
        }
    }
}

private struct PaymentRequestShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Paying one

/// What a payment request asks for, above the amount on Send Kaspa.
struct PaymentRequestSummary: View {
    let request: PaymentRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Requested")
                .font(.caption.weight(.semibold))
                .foregroundColor(.accentColor)
                .textCase(.uppercase)
            Text(verbatim: "\(request.amountText) \(KaspaUnit.symbol)")
                .font(.headline)
            if !request.memo.isEmpty {
                Text(verbatim: request.memo)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().padding(.vertical, 4)

            if let creator = request.creator {
                // Who made it - checked against the signature in the link when it was opened.
                Label("Requested by", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.green)
                AddressResolutionCard(address: creator, addressOnly: true)
                if creator.lowercased() != request.address.lowercased() {
                    Text("Signed by their chatting address. The payment goes to the address above.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Label("Not signed: who made this request can't be confirmed.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
    }
}

/// One of your own payment requests, opened from a link: what it asks for and where it pays
/// into, with its link to copy or share again. Nothing to pay - it's yours.
struct OwnPaymentRequestView: View {
    let request: PaymentRequest
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 6) {
                        Text(verbatim: "\(request.amountText) \(KaspaUnit.symbol)")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .multilineTextAlignment(.center)
                        if !request.memo.isEmpty {
                            Text(verbatim: request.memo)
                                .font(.body)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Paid to your address")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.accentColor)
                            .textCase(.uppercase)
                        AddressResolutionCard(address: request.address)
                        Text("The memo shows to whoever pays, but doesn't travel with the payment.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }

                    SendActionButton(
                        title: copied ? "Copied" : "Copy Payment Request",
                        isBusy: false,
                        isEnabled: true,
                        requiresSlide: false
                    ) {
                        UIPasteboard.general.string = request.shareURLString
                        Haptics.success()
                        copied = true
                    }

                    if let url = URL(string: request.shareURLString) {
                        ShareLink(item: url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .navigationTitle("Your Payment Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

/// Presents Send Kaspa for the payment request waiting in `PaymentRequestRouter` - a link opened
/// from outside the app.
struct PaymentRequestSheetPresenter: ViewModifier {
    @ObservedObject private var router = PaymentRequestRouter.shared
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $router.pending) { request in
                if request.isOwn {
                    OwnPaymentRequestView(request: request)
                        .environmentObject(settingsViewModel)
                } else if let wallet = WalletManager.shared.currentWallet {
                    WithdrawKaspaView(
                        fromAddress: wallet.publicAddress,
                        availableBalanceSompi: wallet.balanceSompi,
                        paymentRequest: request
                    )
                    .environmentObject(WalletService.shared)
                    .environmentObject(WalletManager.shared)
                    .environmentObject(settingsViewModel)
                }
            }
    }
}
