import SwiftUI

/// Send a token, in Send Kaspa's steps and shared pieces (`SendKaspaComponents.swift`): To (an
/// address or a name, Paste, Scan QR, Contacts), From (which of your addresses holding it: the
/// Chatting Address or a regular spending address; skipped when only one holds it), How much (on
/// the app's keypad, in the token), then the review with swipe up. The KAS it takes (the 1.5 KAS
/// that goes with the new coin, and the network fee) comes from the same address, so the send
/// links no other address of yours.
///
/// UI stage: the swipe ends in "Failed" with a line saying sends aren't switched on yet.
struct TokenSendView: View {
    let token: WalletToken
    /// Sent from this address (its own page's Send): no From step.
    var startFrom: TokenHolding? = nil
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var walletManager: WalletManager
    @ObservedObject private var tokens = TokenWallet.shared

    private enum Step: Int { case recipient, from, amount, review }
    @State private var step: Step = .recipient
    @State private var stepForward = true

    // To
    @State private var addressInput = ""
    @State private var resolvedAddress: String?
    @State private var resolvedName: String?
    @State private var lookupError: String?
    @State private var isResolving = false
    @State private var nameResolutions: [NameResolution] = []
    @State private var selectedTLD: NameServiceTLD?
    @State private var showScanner = false

    // From
    @State private var fromID: String?

    // How much
    @State private var amountText = ""

    // Review
    @State private var isSending = false
    @State private var failureMessage: String?
    /// The transfer, built and signed when the review opens (`KusdtTransfer.prepare`): the review
    /// shows its exact fee, and the swipe sends it.
    @State private var prepared: KusdtTransfer.Prepared?
    @State private var isPreparing = false
    @State private var prepareError: String?
    @State private var sent: SentTransaction?
    /// The last submit's answer was lost: Try Again sends the same signed transaction (same id,
    /// so it can't pay twice), never a rebuilt one.
    @State private var outcomeUnknown = false
    /// The sending address needs KAS (`KusdtTransfer.Failure.notEnoughKas`): about how much, for
    /// Fund This Address.
    @State private var fundShortfall: UInt64?
    /// Part of the shortfall is the 1.5 KAS of your change coin (a partial send).
    @State private var fundForChangeCoin = false
    /// Fund This Address: Send Kaspa with a request for the shortfall to the sending address.
    @State private var fundingRequest: PaymentRequest?
    /// The funding send went out: the review is built again once the KAS has landed.
    @State private var funded = false
    /// Waiting for the KAS a funding send put on its way (the review checks every few seconds).
    @State private var awaitingFunds = false
    /// KAS was sent to this address for this send and hasn't shown up yet: the review offers Check
    /// Again rather than another top-up, so nobody pays it twice.
    @State private var fundingSent = false

    private var trimmedInput: String { addressInput.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var typedAddressIsValid: Bool { KaspaAddress.isValidOnActiveNetwork(lowercasedKaspaAddress(trimmedInput)) }

    /// Where it goes: a resolved name's address, or a valid typed one.
    private var recipient: String? {
        if let resolvedAddress { return resolvedAddress }
        return typedAddressIsValid ? lowercasedKaspaAddress(trimmedInput) : nil
    }

    /// Tokens go only to a key's own address: sent to a script address (a quantum-safe one among
    /// them) kUSDT could be stuck or lost (kusdt-open SPEC section 4).
    private var recipientIsScript: Bool { WalletService.isScriptAddress(recipient) }

    private var canContinueFromRecipient: Bool { recipient != nil && !recipientIsScript && !isResolving }

    private var holdings: [TokenHolding] { tokens.holdings(of: token) }

    /// The address it's sent from: the pick, or the only one holding it.
    private var from: TokenHolding? {
        if let fromID, let picked = holdings.first(where: { $0.id == fromID }) { return picked }
        if let startFrom { return holdings.first(where: { $0.id == startFrom.id }) ?? startFrom }
        return holdings.count == 1 ? holdings[0] : nil
    }

    /// Only one address holds it, or the send started from one: no From step.
    private var skipsFrom: Bool { startFrom != nil || holdings.count <= 1 }

    private var balance: UInt64 { from?.units ?? 0 }

    private var amountUnits: UInt64? { TokenAmount.units(fromTyped: amountText, token: token) }

    private var amountTooHigh: Bool { (amountUnits ?? 0) > balance }

    var body: some View {
        NavigationStack {
            ZStack {
                switch step {
                case .recipient: recipientStep.transition(stepTransition)
                case .from: fromStep.transition(stepTransition)
                case .amount: amountStep.transition(stepTransition)
                case .review: reviewStep.transition(stepTransition)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showScanner) {
                QRScannerView { code in handleScanned(code) }
            }
        }
    }

    private var stepTransition: AnyTransition {
        .asymmetric(insertion: .move(edge: stepForward ? .trailing : .leading),
                    removal: .move(edge: stepForward ? .leading : .trailing))
    }

    private func go(to next: Step) {
        dismissSystemKeyboard()
        // leaving the review: what it built belongs to the old amount and recipient
        if step == .review || next == .review {
            prepared = nil
            prepareError = nil
            failureMessage = nil
            outcomeUnknown = false
        }
        stepForward = next.rawValue > step.rawValue
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { step = next }
        }
    }

    private var screenTitle: Text {
        Text(verbatim: String(format: AppLocalization.string("Send %@"), token.symbol))
    }

    // MARK: To

    private var recipientStep: some View {
        SendStepScreen(title: screenTitle, onCancel: { dismiss() }, canContinue: canContinueFromRecipient) {
            go(to: skipsFrom ? .amount : .from)
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SendStepQuestion(text: "Who are you sending to?")
                    SendRecipientCard(
                        input: $addressInput,
                        isResolving: isResolving,
                        resolvedAddress: resolvedAddress,
                        resolvedName: resolvedName,
                        lookupError: lookupError,
                        isValidAddress: typedAddressIsValid,
                        onScan: { showScanner = true },
                        nameResolutions: nameResolutions,
                        selectedTLD: selectedTLD,
                        onSelectResolution: select,
                        focusOnAppear: true
                    )
                    if recipientIsScript {
                        Label(String(format: AppLocalization.string("%@ can only go to a regular Kaspa address, not a quantum-safe or other script address."), token.symbol),
                              systemImage: "xmark.octagon.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(.red)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onChange(of: addressInput) { handleInputChange($0) }
    }

    // MARK: From

    private var fromStep: some View {
        SendStepScreen(title: screenTitle, onBack: { go(to: .recipient) }, onCancel: { dismiss() },
                       canContinue: from != nil) {
            go(to: .amount)
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SendStepQuestion(text: "Where are you sending from?")
                    ForEach(holdings) { holding in
                        fromRow(holding)
                    }
                    Text("The KAS for the fee comes from the same address, so the send doesn't link it to your other addresses.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
    }

    private func fromRow(_ holding: TokenHolding) -> some View {
        let selected = from?.id == holding.id
        return Button {
            Haptics.impact(.light)
            fromID = holding.id
            amountText = ""
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(selected ? .accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: holding.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text(verbatim: holding.address)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(verbatim: TokenAmount.amount(holding.units, token: token))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .monospacedDigit()
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(selected ? Color.accentColor : Color.white.opacity(0.18), lineWidth: selected ? 1.5 : 0.8)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    // MARK: How much

    private var amountStep: some View {
        SendStepScreen(title: screenTitle, onBack: { go(to: skipsFrom ? .recipient : .from) }, onCancel: { dismiss() },
                       continueTitle: "Review", canContinue: amountUnits != nil && !amountTooHigh) {
            go(to: .review)
        } content: {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    SendStepQuestion(text: "How much?")
                    HStack(spacing: 8) {
                        if let recipient {
                            SendStepChip(label: "To", value: resolvedName ?? recipient, isAddress: resolvedName == nil)
                        }
                        if let from {
                            SendStepChip(label: "From", value: from.label)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                TokenKeypadAmountEntry(
                    token: token,
                    text: $amountText,
                    footnote: amountTooHigh
                        ? String(format: AppLocalization.string("More than your %@."), token.symbol)
                        : String(format: AppLocalization.string("Available: %@"), TokenAmount.amount(balance, token: token)),
                    footnoteIsError: amountTooHigh,
                    onMax: { amountText = TokenAmount.typed(balance, token: token) }
                )
            }
        }
    }

    // MARK: Review

    private var reviewStep: some View {
        SwipeUpToSendScrollView(
            screenTitle: "",
            onCancel: { dismiss() },
            onBack: { go(to: .amount) },
            titleText: Text("Review"),
            title: "Swipe up to Send",
            isBusy: isSending,
            isEnabled: prepared != nil && !isPreparing && amountUnits != nil && recipient != nil && from != nil && !amountTooHigh,
            amountSompi: nil,
            recipient: resolvedName ?? recipient,
            sent: sent,
            failureMessage: failureMessage,
            onDone: { dismiss() },
            action: send
        ) {
            VStack(spacing: 18) {
                VStack(spacing: 6) {
                    Text("You're sending")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    if let amountUnits {
                        HStack(spacing: 10) {
                            TokenIcon(token: token, size: 34)
                            Text(verbatim: TokenAmount.amount(amountUnits, token: token))
                                .font(.system(size: 36, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                        }
                        if let dollars = TokenAmount.dollars(amountUnits, token: token) {
                            Text(verbatim: dollars)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

                VStack(alignment: .leading, spacing: 8) {
                    Text("To")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    AddressResolutionCard(address: recipient, domain: resolvedName)
                }

                VStack(spacing: 10) {
                    reviewLine(title: "From", value: from?.label ?? "--")
                    Divider()
                    reviewLine(title: "Goes With It", value: KaspaUnit.amount(prepared?.kasToRecipient ?? token.kasPerCoinSompi))
                    reviewLine(title: "Network Fee", value: prepared.map { KaspaUnit.amount($0.fee) } ?? (isPreparing ? "…" : "--"))
                    Divider()
                    reviewLine(title: "Total KAS", value: prepared.map { KaspaUnit.amount($0.kasToRecipient + $0.fee) } ?? "--", bold: true)
                    reviewLine(title: "KAS Paid From", value: from?.label ?? "--")
                }
                .padding(16)
                .background(sendKaspaGlass(cornerRadius: 18))

                if let prepared, prepared.feeFromTokenKas {
                    Label(AppLocalization.string("This address had no KAS, so the network fee came out of the KAS that goes with the kUSDT."),
                          systemImage: "info.circle.fill")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if awaitingFunds {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for your KAS to arrive…")
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)
                } else if isPreparing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Building the transaction…")
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)
                } else if fundingSent, fundShortfall != nil {
                    // KAS is on its way here already: look again, don't pay twice
                    VStack(spacing: 10) {
                        Label(AppLocalization.string("The KAS you sent hasn't shown up on this address yet. It usually takes a few seconds."),
                              systemImage: "clock.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            Haptics.impact(.light)
                            Task { await prepareAfterFunding(sent: true) }
                        } label: {
                            Text("Check Again")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .background(Capsule().fill(Color.accentColor))
                        }
                        .buttonStyle(.plain)
                        if let fundShortfall {
                            Button(String(format: AppLocalization.string("Add %@ More"), KaspaUnit.amount(fundShortfall))) {
                                openFunding(fundShortfall)
                            }
                            .font(.footnote.weight(.semibold))
                        }
                    }
                } else if let prepareError {
                    VStack(spacing: 10) {
                        Label(prepareError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        if let fundShortfall {
                            // the sending address has too little KAS: top it up from another one
                            Button {
                                Haptics.impact(.light)
                                openFunding(fundShortfall)
                            } label: {
                                Label(String(format: AppLocalization.string(fundForChangeCoin ? "Add %@ for Fee and Change Coin" : "Add %@ for the Network Fee"),
                                             KaspaUnit.amount(fundShortfall)),
                                      systemImage: "arrow.down.to.line")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.black)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 46)
                                    .background(Capsule().fill(Color.accentColor))
                            }
                            .buttonStyle(.plain)
                            Text("Pick which of your addresses the KAS comes from, swipe up, and you're back here.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        } else {
                            Button("Try Again") { Task { await prepare() } }
                                .font(.footnote.weight(.semibold))
                        }
                    }
                }

                Text(verbatim: String(format: AppLocalization.string("Every %@ coin holds %@. It goes to the recipient with the %@, so the KAS isn't lost."),
                                      token.symbol, KaspaUnit.amount(token.kasPerCoinSompi), token.symbol))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .task { if prepared == nil, sent == nil { await prepare() } }
        .sheet(item: $fundingRequest, onDismiss: {
            // closed by Done after the send, or swiped away (maybe after sending): look either way
            let sent = funded
            funded = false
            if sent { fundingSent = true }
            Task { await prepareAfterFunding(sent: sent) }
        }) { request in
            if let wallet = walletManager.currentWallet {
                WithdrawKaspaView(fromAddress: wallet.publicAddress, availableBalanceSompi: wallet.balanceSompi,
                                  paymentRequest: request, onComplete: { funded = true })
            }
        }
    }

    /// Send Kaspa, already filled in: the sending address and the shortfall, as a request signed by
    /// your Chatting Address (so it reads as yours), with a note saying what it's for.
    private func openFunding(_ amount: UInt64) {
        guard let from, let chatting = walletManager.currentWallet?.publicAddress else { return }
        let unsigned = PaymentRequest(address: from.address, amountSompi: amount,
                                      memo: String(format: AppLocalization.string("KAS for a %@ send"), token.symbol),
                                      toChattingAddress: from.isChatting)
        let request = WalletManager.shared.getPrivateKey().flatMap { unsigned.signed(by: chatting, privateKey: $0) } ?? unsigned
        fundingRequest = request
    }

    /// Funding closed: built again until the KAS has landed on the sending address. After a send,
    /// for up to a minute, showing "Waiting for your KAS" (no second top-up button); after a
    /// swipe-away, a couple of looks in case it was sent.
    private func prepareAfterFunding(sent: Bool) async {
        awaitingFunds = sent
        defer { awaitingFunds = false }
        let attempts = sent ? 20 : 3
        for attempt in 0..<attempts {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 3_000_000_000) }
            while isPreparing { try? await Task.sleep(nanoseconds: 200_000_000) }
            await prepare()
            if prepared != nil || fundShortfall == nil { return }
        }
    }

    /// Builds and signs the transfer for what's on the review (no network yet but the coin reads).
    private func prepare() async {
        guard let from, let recipient, let amountUnits, !isPreparing else { return }
        isPreparing = true
        prepareError = nil
        defer { isPreparing = false }
        do {
            prepared = try await KusdtTransfer.prepare(holding: from, coins: tokens.coins(of: from), recipient: recipient, amount: amountUnits)
            fundShortfall = nil
            fundingSent = false
        } catch KusdtTransfer.Failure.notEnoughKas(let short, let forChangeCoin) {
            prepared = nil
            fundShortfall = short
            fundForChangeCoin = forChangeCoin
            prepareError = KusdtTransfer.Failure.notEnoughKas(short: short, forChangeCoin: forChangeCoin).localizedDescription
        } catch {
            prepared = nil
            fundShortfall = nil
            prepareError = error.localizedDescription
        }
    }

    private func reviewLine(title: LocalizedStringKey, value: String, bold: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(verbatim: value)
                .font(bold ? .subheadline.weight(.bold) : .subheadline.weight(.semibold))
                .monospacedDigit()
        }
    }

    private func send() {
        guard !isSending else { return }
        failureMessage = nil
        isSending = true
        Task { @MainActor in
            defer { isSending = false }
            // a review left open a while is built again from the coins as they are now
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
                sent = SentTransaction(txId: txid, amountSompi: nil,
                                       recipient: "\(TokenAmount.amount(prepared.amount, token: token)) → \(resolvedName ?? recipient ?? "")")
            } catch is SendOutcomeUnknownError {
                outcomeUnknown = true
                // it may have landed: its kUSDT coins leave the balances until a lookup shows them
                // unspent, so nothing else is built on them meanwhile
                TokenWallet.shared.noteSent(prepared)
                failureMessage = AppLocalization.string("Not confirmed: the network didn't answer. It may still go through. Try Again resends the same transaction, so it can't be paid twice.")
            } catch {
                failureMessage = error.localizedDescription
            }
        }
    }

    // MARK: Recipient lookup (Send Kaspa's rules)

    private func handleInputChange(_ value: String) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // An upper-case address goes into the field in lower case; that change comes back here.
        let lowered = lowercasedKaspaAddress(text)
        if lowered != text {
            addressInput = lowered
            return
        }
        resolvedAddress = nil
        resolvedName = nil
        lookupError = nil
        nameResolutions = []
        selectedTLD = nil
        isResolving = false
        guard !text.isEmpty else { return }
        if text.lowercased().hasPrefix("kaspa:") || text.lowercased().hasPrefix("kaspatest:") { return }
        // A name, with or without its ending ("kaspasilver" looks up .kachat first), the way Send
        // Kaspa decides (`NameServicesClient.looksLikeName`): every name service, after a short
        // pause in the typing.
        guard NameServicesClient.looksLikeName(text) else { return }
        isResolving = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard trimmedInput == text else { return }
            let results = await NameServicesClient.shared.resolveEverywhere(text)
            guard trimmedInput == text else { return }
            nameResolutions = results
            isResolving = false
            if let resolution = NameServicesClient.primary(of: results, typed: text), resolution.address != nil {
                select(resolution)
            } else {
                lookupError = NameServicesClient.notFoundMessage(typed: text, results: results)
            }
        }
    }

    private func select(_ resolution: NameResolution) {
        guard let address = resolution.address, KaspaAddress.isValidOnActiveNetwork(address) else {
            resolvedAddress = nil
            resolvedName = nil
            selectedTLD = nil
            lookupError = NameServicesClient.notFoundMessage(typed: resolution.display, results: [])
            return
        }
        resolvedAddress = address
        resolvedName = resolution.display
        selectedTLD = resolution.tld
        lookupError = nil
    }

    private func handleScanned(_ code: String) {
        var address = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.lowercased().hasPrefix("kaspa:") || address.lowercased().hasPrefix("kaspatest:") {
            if let query = address.firstIndex(of: "?") { address = String(address[..<query]) }
            address = lowercasedKaspaAddress(address)
        }
        addressInput = address
    }
}

/// A token amount on the app's keypad: the big number in the token's unit, Max, a footnote
/// (Available, or why it can't be sent), then the keys. Up to the token's decimals.
private struct TokenKeypadAmountEntry: View {
    let token: WalletToken
    @Binding var text: String
    let footnote: String
    let footnoteIsError: Bool
    let onMax: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            KeypadAmountText(typed: text, unit: token.symbol,
                             accessibilityName: String(format: AppLocalization.string("Amount (%@)"), token.symbol))
            HStack(spacing: 10) {
                Button(action: onMax) {
                    Text("Max")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(sendKaspaGlass(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 12)
            Text(verbatim: footnote)
                .font(.footnote)
                .foregroundColor(footnoteIsError ? .red : .secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.top, 10)
                .padding(.horizontal, 20)
            Spacer(minLength: 8)
            KaspaKeypad { key in
                let next = KaspaKeypad.applying(key, to: text, maxDecimals: token.decimals)
                guard next != text else {
                    Haptics.impact(.rigid)
                    return
                }
                text = next
            }
            .padding(.horizontal, 12)
        }
    }
}
