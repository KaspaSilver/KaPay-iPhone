import SwiftUI
import UIKit

// The pieces every Send Kaspa screen is built from, so they look and behave the same: the 1:1
// Wallet tab's Send Kaspa, a spending address's Send, and KasSigner's send.
// Recipient on top (paste, scan a QR, names resolve), then the big amount (KAS or your currency,
// Max), the fee and balance, the fee speed and coin control, and a slide-to-send button.

/// The frosted card the Send Kaspa pieces sit on.
func sendKaspaGlass(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
        )
}

// MARK: - Recipient

/// Who the Kaspa goes to: an address or a name, with Paste and Scan QR beside the field and a
/// line saying what the input resolved to. The screen keeps its own lookup logic (it watches
/// `input`); this only shows it. With `lockedAddress` (Compound UTXOs) the recipient is fixed.
struct SendRecipientCard: View {
    @Binding var input: String
    var lockedAddress: String? = nil
    let isResolving: Bool
    let resolvedAddress: String?
    let resolvedName: String?
    let lookupError: String?
    let isValidAddress: Bool
    let onScan: () -> Void
    /// Every service's answer for a typed name (`NameServicesClient.resolveEverywhere`, .kachat
    /// first) and the one in use: the rest are offered under "Other domains".
    var nameResolutions: [NameResolution] = []
    var selectedTLD: NameServiceTLD? = nil
    var onSelectResolution: (NameResolution) -> Void = { _ in }
    /// Puts the cursor in the field when it appears empty (a send's first step).
    var focusOnAppear = false

    @ObservedObject private var addressBook = AddressBookManager.shared
    @State private var showAddressBook = false
    @FocusState private var isFocused: Bool

    private var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("To")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            if let lockedAddress {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.merge")
                        .foregroundColor(.accentColor)
                    Text(verbatim: lockedAddress)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("Consolidating This Address")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                TextField("kaspa:qr... or domain", text: $input)
                    .font(.system(.subheadline, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isFocused)
                HStack(spacing: 6) {
                    inputPill("Paste", systemImage: "doc.on.clipboard") {
                        if let pasted = UIPasteboard.general.string {
                            input = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    inputPill("Scan QR", systemImage: "qrcode.viewfinder", action: onScan)
                    // always there, as in KaChat: with no contacts yet it opens on "No contacts yet"
                    inputPill("Contacts", systemImage: "person.text.rectangle") {
                        showAddressBook = true
                    }
                    Spacer(minLength: 0)
                }
                AddressResolutionCard(address: resolvedAddress ?? (isValidAddress ? trimmed : nil), domain: resolvedName)
                if let savedName = addressBook.entry(for: resolvedAddress ?? trimmed)?.customName {
                    Label(savedName, systemImage: "person.text.rectangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.accentColor)
                }
                if !trimmed.isEmpty {
                    statusLine
                    if !isResolving {
                        OtherDomainsDropdown(resolutions: nameResolutions, selected: selectedTLD, onSelect: onSelectResolution)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sendKaspaGlass(cornerRadius: 20))
        .fullScreenCover(isPresented: $showAddressBook) {
            AddressBookPickerSheet { entry in input = entry.address }
        }
        .onAppear {
            guard focusOnAppear, lockedAddress == nil, trimmed.isEmpty else { return }
            // The field doesn't exist yet on the tap that presented the screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { isFocused = true }
        }
    }

    /// Paste, Scan QR, Contacts: a labelled pill under the field.
    private func inputPill(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.accentColor)
                .lineLimit(1)
                // three to a row on the narrowest phones
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusLine: some View {
        if isResolving {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.8)
                Text("Looking up domain...")
            }
            .font(.caption)
            .foregroundColor(.secondary)
        } else if let lookupError {
            Label(lookupError, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundColor(.red)
        } else if let resolvedAddress {
            VStack(alignment: .leading, spacing: 2) {
                Label("Resolved: \(resolvedName ?? "")", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
                Text(verbatim: resolvedAddress)
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            Label(KaspaAddress.validityText(trimmed, isValid: isValidAddress),
                  systemImage: isValidAddress ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption)
                .foregroundColor(isValidAddress ? .green : .red)
        }
    }
}

// MARK: - Other domains

/// "Other domains": what the same typed name points to on the other services, under the name it
/// resolved to, each selectable. Every field that takes an address shows it; the order is always
/// .kachat first (`NameServiceTLD.resolutionOrder`). Opens by itself when nothing was picked but
/// another service has the name.
struct OtherDomainsDropdown: View {
    let resolutions: [NameResolution]
    let selected: NameServiceTLD?
    let onSelect: (NameResolution) -> Void

    @State private var expanded = false

    private var others: [NameResolution] { resolutions.filter { $0.tld != selected } }

    var body: some View {
        if !others.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(others) { resolution in
                        Button {
                            onSelect(resolution)
                            expanded = false
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: resolution.display)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(resolution.address == nil ? .secondary : .primary)
                                    Text(resolution.address ?? Self.missingText(resolution))
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                                if resolution.address != nil {
                                    Image(systemName: "arrow.right.circle")
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(resolution.address == nil)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Other domains")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.accentColor)
            }
            .tint(.accentColor)
            .onAppear { openIfNothingPicked() }
            .onChange(of: resolutions) { _ in openIfNothingPicked() }
        }
    }

    private func openIfNothingPicked() {
        if selected == nil, resolutions.contains(where: { $0.address != nil }) { expanded = true }
    }

    static func missingText(_ r: NameResolution) -> String {
        if r.notLive { return String(localized: "Coming soon") }
        return r.failed ? String(localized: "Couldn't check") : String(localized: "Not registered")
    }
}

// MARK: - Amount

/// The big centred amount and its unit, with the KAS / your-currency switch (showing the
/// converted value) and Max under it. Hands the screen the KAS amount text after every edit.
struct KaspaAmountEntry: View {
    @ObservedObject var fiatAmountState: KaspaFiatAmountState
    @ObservedObject private var portfolio = PortfolioViewModel.shared
    /// Receives the amount in KAS (as text) after each edit - what the screen stores.
    let onAmountChange: (String) -> Void
    /// Cleans what was typed before it's used: by default digits and one decimal point, with
    /// "," read as "." for comma-decimal keyboards, at most 8 decimals.
    var sanitize: (String) -> String = KaspaUnit.sanitizeAmountInput
    var isEstimatingMax = false
    var maxEnabled = true
    /// False leaves Max out (asking for an amount, not sending one: Request Payment).
    var showsMax = true
    /// Puts the cursor in the amount when the screen appears (the amount is the first thing to type).
    var focusOnAppear = false
    let onMax: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        let display = Self.grouped(fiatAmountState.displayText)
        let fontSize: CGFloat = display.count <= 7 ? 52 : (display.count <= 10 ? 40 : 30)
        let price = portfolio.currentPriceUsd
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField(
                    "0",
                    // Shown with thousands separators ("12,345.5", or "12 345.5" where "," is the decimal point); what the screen gets stays plain.
                    text: Binding(
                        get: { Self.grouped(fiatAmountState.displayText) },
                        set: { newValue in
                            let plain = Self.ungrouped(newValue, previous: Self.grouped(fiatAmountState.displayText))
                            onAmountChange(fiatAmountState.onDisplayTextChange(sanitize(plain), priceInCurrency: price))
                        }
                    )
                )
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .keyboardType(.decimalPad)
                .fixedSize()
                .focused($isFocused)
                .accessibilityLabel(Text(KaspaUnit.label(AppLocalization.string("Amount (KAS)"))))

                Text(verbatim: fiatAmountState.isFiatMode ? portfolio.currentCurrency.code : KaspaUnit.symbol)
                    .font(.system(size: fontSize * 0.55, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }

            HStack(spacing: 10) {
                if price != nil {
                    Button {
                        fiatAmountState.toggleMode(priceInCurrency: price)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.caption.weight(.semibold))
                            if let conversion = fiatAmountState.conversionLabelText(priceInCurrency: price, currency: portfolio.currentCurrency) {
                                Text(verbatim: conversion)
                            } else {
                                Text(verbatim: fiatAmountState.isFiatMode ? KaspaUnit.symbol : portfolio.currentCurrency.code)
                            }
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(sendKaspaGlass(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Switch between Kaspa and your currency"))
                }

                if showsMax {
                Button(action: onMax) {
                    Group {
                        if isEstimatingMax {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Text("Max")
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(sendKaspaGlass(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(!maxEnabled || isEstimatingMax)
                .opacity(maxEnabled ? 1 : 0.5)
                }
            }
        }
        .onAppear {
            guard focusOnAppear else { return }
            // The field doesn't exist yet on the tap that presented the screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { isFocused = true }
        }
    }
}

extension KaspaAmountEntry {
    /// Where the device writes the decimal point as "," (de, fr, es, it, pt, ru, tr, id, vi...),
    /// a comma is ALWAYS the decimal point - "0,001" pasted from a message is 0.001, never 1 (IOS-078) -
    /// and thousands show as a thin space ("2 500"), which no reader takes for a decimal.
    /// Elsewhere thousands show as "," ("12,345.5").
    static func usesCommaDecimal(_ locale: Locale = .current) -> Bool {
        locale.decimalSeparator == ","
    }

    static func groupingSeparator(_ locale: Locale = .current) -> String {
        usesCommaDecimal(locale) ? "\u{202F}" : ","
    }

    /// "12345.5" -> "12,345.5", or "12 345,5" where "," is the decimal point: a separator every
    /// three digits of the whole part, the decimal point the device's own (so the person sees the
    /// "," they typed and doesn't type it again - IOS-082), the rest as typed.
    static func grouped(_ plain: String, locale: Locale = .current) -> String {
        let parts = plain.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let point = usesCommaDecimal(locale) ? "," : "."
        guard let whole = parts.first, whole.allSatisfy({ $0.isASCII && $0.isNumber }) else { return plain }
        var out = ""
        if whole.count > 3 {
            let separator = groupingSeparator(locale)
            for (i, ch) in whole.enumerated() {
                if i > 0, (whole.count - i) % 3 == 0 { out.append(separator) }
                out.append(ch)
            }
        } else {
            out = String(whole)
        }
        return parts.count > 1 ? out + point + parts[1] : out
    }

    /// The edited field back to a plain number ("." the decimal point).
    /// - Comma-decimal device: the thin spaces shown are ours and go; the first "," is the
    ///   decimal point and any further one is dropped (a second tap on the key never moves the
    ///   point - IOS-082). A pasted "1.234,5" (dots as grouping, a comma decimal) is 1234.5.
    /// - Otherwise: the commas shown are ours and go; a comma TYPED as the decimal point stays one:
    ///   typed at the end, or a single comma not three digits from the end in a number that had no
    ///   grouping ("0,5" is 0.5), or after a lone leading zero ("0,001" is 0.001, as no grouped
    ///   number starts "0,").
    static func ungrouped(_ edited: String, previous: String, locale: Locale = .current) -> String {
        if usesCommaDecimal(locale) {
            var text = edited.replacingOccurrences(of: "\u{202F}", with: "")
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "\u{00A0}", with: "")
            if text.contains(",") {
                // a comma is the decimal point; dots beside it can only be grouping
                text = text.replacingOccurrences(of: ".", with: "")
                if let first = text.firstIndex(of: ",") {
                    let head = text[..<first]
                    let tail = text[text.index(after: first)...].replacingOccurrences(of: ",", with: "")
                    text = String(head) + "." + tail
                }
            }
            return text
        }
        if edited == previous + "," {
            return previous.replacingOccurrences(of: ",", with: "") + "."
        }
        if !previous.contains(","), !edited.contains("."), edited.filter({ $0 == "," }).count == 1,
           let comma = edited.firstIndex(of: ","),
           edited[..<comma] == "0" || edited[..<comma].isEmpty
            || edited.distance(from: edited.index(after: comma), to: edited.endIndex) != 3 {
            return edited.replacingOccurrences(of: ",", with: ".")
        }
        return edited.replacingOccurrences(of: ",", with: "")
    }
}

extension Binding where Value == String {
    /// An amount field's text with thousands separators while shown ("12,345.5"), the plain number
    /// stored - the same rules as `KaspaAmountEntry`, for the amount fields that aren't one.
    var groupedAmount: Binding<String> {
        Binding(
            get: { KaspaAmountEntry.grouped(wrappedValue) },
            set: { wrappedValue = KaspaAmountEntry.ungrouped($0, previous: KaspaAmountEntry.grouped(wrappedValue)) }
        )
    }
}

// MARK: - Fee and coin control

/// Network fee (tap to set a custom one), the fee speed, and coin control - one card.
struct SendFeeControls: View {
    @Binding var feeTier: WithdrawFeeTier
    @Binding var isEditingFee: Bool
    @Binding var customFeeText: String
    let isEstimatingFee: Bool
    /// The fee as shown ("0.0001 KAS"), nil while unknown.
    let feeText: String?
    let onStartEditing: () -> Void
    let onCommit: () -> Void
    var showsCoinControl = true
    var coinControlSummary: String = ""
    var onCoinControl: () -> Void = {}
    /// Set: the fee shows with an Edit button that opens the screen's own fee editor (a send's
    /// review), instead of being typed here.
    var onEditFee: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Network Fee")
                    .font(.subheadline)
                Spacer()
                if let onEditFee {
                    if isEstimatingFee {
                        ProgressView().scaleEffect(0.75)
                    } else {
                        Text(verbatim: feeText ?? "—")
                            .font(.subheadline.monospacedDigit())
                            .foregroundColor(feeText == nil ? .secondary : .primary)
                    }
                    Button {
                        Haptics.impact(.light)
                        onEditFee()
                    } label: {
                        Label("Edit", systemImage: "pencil")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    .disabled(feeText == nil)
                    .opacity(feeText == nil ? 0.5 : 1)
                } else if isEditingFee {
                    TextField("0.00", text: $customFeeText)
                        .keyboardType(.decimalPad)
                        .numericKeyboardDoneButton()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 110)
                        .onSubmit(onCommit)
                    Button(action: onCommit) {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                } else if isEstimatingFee {
                    ProgressView().scaleEffect(0.75)
                } else if let feeText {
                    Button(action: onStartEditing) {
                        HStack(spacing: 4) {
                            Text(verbatim: feeText).underline()
                            Image(systemName: "pencil").font(.caption2)
                        }
                        .font(.subheadline)
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(verbatim: "—").foregroundColor(.secondary)
                }
            }
            Picker("Fee", selection: $feeTier) {
                ForEach(WithdrawFeeTier.allCases) { tier in
                    Text(LocalizedStringKey(tier.rawValue)).tag(tier)
                }
            }
            .pickerStyle(.segmented)
            Text(onEditFee == nil
                 ? LocalizedStringKey("If the network is busy, Fast or Priority pays a higher fee to help this confirm sooner. Tap the fee amount to set a custom fee.")
                 : LocalizedStringKey("If the network is busy, Fast or Priority pays a higher fee to help this confirm sooner. Edit sets a fee of your own."))
                .font(.caption)
                .foregroundColor(.secondary)

            if showsCoinControl {
                Divider()
                Button(action: onCoinControl) {
                    HStack {
                        Text("Coin Control")
                            .font(.subheadline)
                            .foregroundColor(.primary)
                        Spacer()
                        Text(verbatim: coinControlSummary)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(sendKaspaGlass(cornerRadius: 20))
    }
}

/// "Automatic" or "3 UTXOs selected", for the coin control row.
func coinControlSummary(_ manualUtxos: [UTXO]?) -> String {
    guard let manualUtxos else { return AppLocalization.string("Automatic") }
    return "\(manualUtxos.count) UTXO\(manualUtxos.count == 1 ? "" : "s") selected"
}

/// A small glass capsule for one line of context (available balance, fee).
struct SendInfoPill<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(sendKaspaGlass(cornerRadius: 14))
    }
}

// MARK: - Send steps

/// Puts the system keyboard away, wherever it is.
@MainActor
func dismissSystemKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

/// The header every send step draws in place of the navigation bar: Back (or Cancel on the
/// first step) on the left, the title in the middle, Cancel on the right once there is a Back.
/// Without `onCancel` (a step whose Cancel sits at the bottom, beside Continue) only the title
/// and Back show.
struct SendStepHeader: View {
    let title: Text
    var onBack: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    init(title: String, onBack: (() -> Void)? = nil, onCancel: (() -> Void)? = nil) {
        self.init(titleText: Text(LocalizedStringKey(title)), onBack: onBack, onCancel: onCancel)
    }

    init(titleText: Text, onBack: (() -> Void)? = nil, onCancel: (() -> Void)? = nil) {
        self.title = titleText
        self.onBack = onBack
        self.onCancel = onCancel
    }

    var body: some View {
        ZStack {
            title
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                // room for the buttons only when there are any
                .padding(.horizontal, onBack != nil || onCancel != nil ? 96 : 16)
            HStack {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                            .foregroundColor(.accentColor)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(.regularMaterial))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Back"))
                } else if let onCancel {
                    cancelButton(onCancel)
                }
                Spacer()
                if onBack != nil, let onCancel {
                    cancelButton(onCancel)
                }
            }
        }
        .frame(minHeight: 40)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private func cancelButton(_ onCancel: @escaping () -> Void) -> some View {
        Button(action: onCancel) {
            Text("Cancel")
                .font(.body)
                .foregroundColor(.accentColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(.regularMaterial))
        }
        .buttonStyle(.plain)
    }
}

/// A send step's Continue: a teal capsule pinned at the bottom, full width, or beside Cancel
/// when the step has `onCancel` (its header then leaves Cancel out).
struct SendContinueButton: View {
    var title: LocalizedStringKey = "Continue"
    let isEnabled: Bool
    var onCancel: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let onCancel {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.headline)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Capsule().fill(.regularMaterial))
                        .overlay(Capsule().stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Button {
                Haptics.impact(.light)
                action()
            } label: {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Capsule().fill(Color.accentColor.opacity(isEnabled ? 1 : 0.4)))
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// One step of a send (who to, how much, a fee, a price...): the header, the step's content, and
/// Continue pinned at the bottom. The first step (no `onBack`) has Cancel beside Continue; a
/// later one has Back and Cancel in its header.
struct SendStepScreen<Content: View>: View {
    let title: Text
    var onBack: (() -> Void)? = nil
    let onCancel: () -> Void
    var continueTitle: LocalizedStringKey = "Continue"
    let canContinue: Bool
    let onContinue: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            SendStepHeader(titleText: title, onBack: onBack, onCancel: onBack == nil ? nil : onCancel)
            content
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom) {
            SendContinueButton(title: continueTitle, isEnabled: canContinue,
                               onCancel: onBack == nil ? onCancel : nil, action: onContinue)
        }
    }
}

/// "To alice.kachat", "From Chatting Address": one line of what a step is about, as a glass
/// chip above its content (the amount step).
struct SendStepChip: View {
    let label: LocalizedStringKey
    let value: String
    /// An address: monospaced, cut in the middle.
    var isAddress = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundColor(.secondary)
            if isAddress {
                Text(verbatim: value)
                    .font(.subheadline.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(verbatim: value)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(sendKaspaGlass(cornerRadius: 18))
    }
}

/// The question a step asks, big, at the top of its content ("Who are you sending to?").
struct SendStepQuestion: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.title2.weight(.bold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A review's fee editor (its fee row's Edit): the whole network fee typed on `KaspaKeypad`,
/// Confirm hands it back, Cancel leaves it as it was. Says the network's minimum when known
/// (`minimumSompi`) and warns at more than ten times `referenceSompi` (the minimum, else the fee
/// it opened with).
struct SendFeeEditorScreen: View {
    @Binding var draft: String
    var minimumSompi: UInt64? = nil
    var referenceSompi: UInt64? = nil
    let onCancel: () -> Void
    let onConfirm: (UInt64) -> Void

    private var draftSompi: UInt64? {
        guard let sompi = KaspaUnit.sompi(fromUserText: draft), sompi > 0 else { return nil }
        return sompi
    }

    private var isHigh: Bool {
        guard let draftSompi, let reference = minimumSompi ?? referenceSompi, reference > 0 else { return false }
        return draftSompi > reference * 10
    }

    private var footnote: String? {
        let minimum = minimumSompi.map {
            KaspaUnit.label(String(format: AppLocalization.string("The network needs at least %@ KAS. A lower fee is raised to that."),
                                   locale: AppLocalization.locale, KaspaUnit.plain($0)))
        }
        guard isHigh else { return minimum }
        return [AppLocalization.string("This is much more than the network needs."), minimum]
            .compactMap { $0 }.joined(separator: " ")
    }

    var body: some View {
        // Cancel sits at the bottom, beside Confirm.
        SendStepScreen(title: Text("Network Fee"), onCancel: onCancel, continueTitle: "Confirm",
                       canContinue: draftSompi != nil) {
            guard let draftSompi else { return }
            Haptics.success()
            onConfirm(draftSompi)
        } content: {
            VStack(spacing: 0) {
                Text("Set your network fee")
                    .font(.title3.weight(.bold))
                    .padding(.top, 8)
                Spacer(minLength: 8)
                KeypadAmountText(typed: draft, unit: KaspaUnit.symbol,
                                 accessibilityName: AppLocalization.string("Network Fee"))
                Text(verbatim: footnote ?? " ")
                    .font(.footnote)
                    .foregroundColor(isHigh ? .orange : .secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                    .padding(.horizontal, 24)
                Spacer(minLength: 8)
                KaspaKeypad { key in
                    let text = KaspaKeypad.applying(key, to: draft, maxDecimals: 8)
                    guard text != draft else {
                        Haptics.impact(.rigid)
                        return
                    }
                    draft = text
                }
                .padding(.horizontal, 12)
            }
        }
    }
}

/// The amount step's From: the two pills of `SendFromSection` - Chatting Address and Choose an
/// Address (any of your addresses; once picked, the pill shows its name) - without the address
/// card under them, so the keypad has room. The balance it loads is the amount's Available.
struct SendFromCompactRow: View {
    @Binding var source: SendSource
    /// The chosen address's balance, loaded here (nil while it loads).
    @Binding var availableSompi: UInt64?
    /// Opened from one address's own page: that address only, shown as the one pill.
    var isLocked: Bool = false
    @State private var showPicker = false

    var body: some View {
        HStack(spacing: 10) {
            Text("From")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            if isLocked {
                SelectablePill(title: LocalizedStringKey(sourceTitle), selected: true) {}
                    .allowsHitTesting(false)
            } else {
                SelectablePill(title: "Chatting Address", selected: source == .chatting) {
                    source = .chatting
                }
                SelectablePill(title: chooseTitle, selected: source != .chatting) {
                    showPicker = true
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            OwnAddressPicker(title: "Send From", selected: source.address) { picked in
                source = picked
            }
        }
        .task(id: source) {
            availableSompi = nil
            guard let address = source.address else { return }
            // A failed read says nothing about the balance: left unknown, not shown as 0.
            let utxos = try? await NodePoolService.shared.getUtxosByAddresses([address])
            guard !Task.isCancelled, let utxos else { return }
            // what a send can spend: not coins just spent or not yet usable
            let spendable = source == .chatting
                ? WalletService.shared.withdrawalSpendable(utxos)
                : WalletService.shared.unreservedUtxos(utxos)
            availableSompi = spendable.reduce(UInt64(0)) { $0 + $1.amount }
        }
    }

    /// "Choose an Address", or the picked address's name.
    private var chooseTitle: LocalizedStringKey {
        if case .spending(_, _, let label) = source { return LocalizedStringKey(label) }
        return "Choose an Address"
    }

    private var sourceTitle: String {
        switch source {
        case .chatting: return AppLocalization.string("Chatting Address")
        case .spending(_, _, let label): return label
        }
    }
}

/// The amount on a send's amount step, typed on the app's own number pad (`KaspaKeypad`), so no
/// system keyboard comes up: the big amount and its unit, the KAS / your-currency switch and
/// Max, then the keys. Hands the screen the KAS amount text after every key, like
/// `KaspaAmountEntry`.
struct KaspaKeypadAmountEntry: View {
    @ObservedObject var fiatAmountState: KaspaFiatAmountState
    @ObservedObject private var portfolio = PortfolioViewModel.shared
    let onAmountChange: (String) -> Void
    var isEstimatingMax = false
    var maxEnabled = true
    /// False leaves Max out (an offer, a price).
    var showsMax = true
    /// A line under the amount (Available, or why the amount can't be sent).
    var footnote: String? = nil
    var footnoteIsError = false
    let onMax: () -> Void
    /// Any key press (not Max): the screen stops treating the amount as Max.
    var onKeyTyped: () -> Void = {}

    var body: some View {
        let price = portfolio.currentPriceUsd
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            amountLine
            HStack(spacing: 10) {
                if price != nil {
                    Button {
                        fiatAmountState.toggleMode(priceInCurrency: price)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.caption.weight(.semibold))
                            if let conversion = fiatAmountState.conversionLabelText(priceInCurrency: price, currency: portfolio.currentCurrency) {
                                Text(verbatim: conversion)
                            } else {
                                Text(verbatim: fiatAmountState.isFiatMode ? KaspaUnit.symbol : portfolio.currentCurrency.code)
                            }
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(sendKaspaGlass(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Switch between Kaspa and your currency"))
                }
                if showsMax {
                    Button(action: onMax) {
                        Group {
                            if isEstimatingMax {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Text("Max")
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(sendKaspaGlass(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .disabled(!maxEnabled || isEstimatingMax)
                    .opacity(maxEnabled ? 1 : 0.5)
                }
            }
            .padding(.top, 12)
            Text(verbatim: footnote ?? " ")
                .font(.footnote)
                .foregroundColor(footnoteIsError ? .red : .secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.top, 10)
                .padding(.horizontal, 20)
            Spacer(minLength: 8)
            KaspaKeypad { key in
                let text = KaspaKeypad.applying(key, to: fiatAmountState.displayText,
                                                maxDecimals: fiatAmountState.isFiatMode ? 2 : 8)
                guard text != fiatAmountState.displayText else {
                    Haptics.impact(.rigid)
                    return
                }
                onKeyTyped()
                onAmountChange(fiatAmountState.onDisplayTextChange(text, priceInCurrency: price))
            }
            .padding(.horizontal, 12)
        }
    }

    private var amountLine: some View {
        KeypadAmountText(typed: fiatAmountState.displayText,
                         unit: fiatAmountState.isFiatMode ? portfolio.currentCurrency.code : KaspaUnit.symbol,
                         accessibilityName: KaspaUnit.label(AppLocalization.string("Amount (KAS)")))
    }
}

/// The big number a keypad types into: the typed text grouped ("12,345.5", "0" while empty) and
/// its unit, shrinking as it grows.
struct KeypadAmountText: View {
    let typed: String
    let unit: String
    let accessibilityName: String

    var body: some View {
        let display = typed.isEmpty ? "0" : KaspaAmountEntry.grouped(typed)
        let fontSize: CGFloat = display.count <= 7 ? 60 : (display.count <= 10 ? 46 : 34)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: display)
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .foregroundColor(typed.isEmpty ? .secondary : .primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.15), value: display)
            Text(verbatim: unit)
                .font(.system(size: fontSize * 0.5, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: accessibilityName))
        .accessibilityValue(Text(verbatim: display))
    }
}

/// The app's own number pad: 1-9, the decimal point, 0 and delete (hold to clear). Used where a
/// system keyboard would cover the screen (a send's amount step).
struct KaspaKeypad: View {
    enum Key: Hashable {
        case digit(Int)
        case decimal
        case delete
        case clear
    }

    let onKey: (Key) -> Void

    private static let rows: [[Key]] = [
        [.digit(1), .digit(2), .digit(3)],
        [.digit(4), .digit(5), .digit(6)],
        [.digit(7), .digit(8), .digit(9)],
        [.decimal, .digit(0), .delete],
    ]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Self.rows, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.self) { key in
                        keyButton(key)
                    }
                }
            }
        }
    }

    private func keyButton(_ key: Key) -> some View {
        Button {
            Haptics.impact(.light)
            onKey(key)
        } label: {
            Group {
                switch key {
                case .digit(let n):
                    Text(verbatim: "\(n)")
                case .decimal:
                    Text(verbatim: KaspaAmountEntry.usesCommaDecimal() ? "," : ".")
                case .delete, .clear:
                    Image(systemName: "delete.left")
                        .font(.title2.weight(.medium))
                }
            }
            .font(.system(size: 30, weight: .medium, design: .rounded))
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(KaspaKeypadKeyStyle())
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                guard key == .delete else { return }
                Haptics.impact(.medium)
                onKey(.clear)
            }
        )
        .accessibilityLabel(Text(Self.accessibilityName(key)))
    }

    private static func accessibilityName(_ key: Key) -> String {
        switch key {
        case .digit(let n): return "\(n)"
        case .decimal: return AppLocalization.string("Decimal point")
        case .delete, .clear: return AppLocalization.string("Delete")
        }
    }

    /// The amount text after a key: plain digits with "." as the point, at most `maxDecimals`
    /// decimals and 11 whole digits (more than all the Kaspa there will ever be). A leading zero
    /// gives way to the next digit; the point on an empty amount writes "0.". A key that can't
    /// apply leaves the text as it was.
    static func applying(_ key: Key, to text: String, maxDecimals: Int) -> String {
        switch key {
        case .clear:
            return ""
        case .delete:
            return String(text.dropLast())
        case .decimal:
            if text.contains(".") || maxDecimals == 0 { return text }
            return text.isEmpty ? "0." : text + "."
        case .digit(let n):
            if let point = text.firstIndex(of: ".") {
                let decimals = text.distance(from: text.index(after: point), to: text.endIndex)
                return decimals >= maxDecimals ? text : text + "\(n)"
            }
            if text == "0" { return "\(n)" }
            if text.count >= 11 { return text }
            return text + "\(n)"
        }
    }
}

/// A keypad key: a soft round highlight while pressed.
private struct KaspaKeypadKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0))
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Send button

/// The send button: slide the knob to the right end to send, so a payment can't go out on a
/// stray touch. Letting go before the end springs it back; after a send that didn't go through
/// (an error, the small-amount question) it resets by itself. VoiceOver gets a plain activate
/// action. With `requiresSlide: false` it's an ordinary tap in the same look (KasSigner's "Build
/// Unsigned Transaction", which moves nothing by itself).
struct SendActionButton: View {
    let title: LocalizedStringKey
    let isBusy: Bool
    let isEnabled: Bool
    var requiresSlide = true
    let action: () -> Void

    @State private var offset: CGFloat = 0
    @State private var reachedEnd = false
    private let height: CGFloat = 56
    private let inset: CGFloat = 4

    private var active: Bool { isEnabled && !isBusy }

    var body: some View {
        Group {
            if requiresSlide {
                slider
            } else {
                track(progress: 0)
                    .overlay {
                        label.frame(maxWidth: .infinity)
                    }
                    .onTapGesture {
                        guard active else { return }
                        action()
                    }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            guard active else { return }
            action()
        }
        .onChange(of: isBusy) { busy in
            if !busy { reset() }
        }
    }

    private var slider: some View {
        GeometryReader { geometry in
            let knob = height - inset * 2
            let maxOffset = max(1, geometry.size.width - knob - inset * 2)
            let progress = min(1, offset / maxOffset)
            ZStack(alignment: .leading) {
                track(progress: progress, knob: knob)
                label
                    .opacity(isBusy ? 1 : Double(1 - progress))
                    .frame(maxWidth: .infinity)
                if !isBusy {
                    Circle()
                        .fill(Color.white)
                        .frame(width: knob, height: knob)
                        .overlay(
                            Image(systemName: "chevron.right.2")
                                .font(.headline.weight(.bold))
                                .foregroundColor(Color.accentColor)
                        )
                        .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
                        .offset(x: inset + offset)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard active else { return }
                                    if offset == 0 && value.translation.width > 0 { Haptics.impact(.light) }
                                    offset = min(max(0, value.translation.width), maxOffset)
                                    if offset >= maxOffset && !reachedEnd {
                                        reachedEnd = true
                                        Haptics.impact(.medium)
                                    } else if offset < maxOffset {
                                        reachedEnd = false
                                    }
                                }
                                .onEnded { _ in
                                    guard active else { return }
                                    if offset >= maxOffset * 0.95 {
                                        offset = maxOffset
                                        action()
                                        // A send that didn't start (dust question, a validation
                                        // error) leaves it not busy: put the knob back.
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                            if !isBusy { reset() }
                                        }
                                    } else {
                                        reset()
                                    }
                                }
                        )
                }
            }
        }
    }

    private func track(progress: CGFloat, knob: CGFloat = 0) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.accentColor.opacity(isEnabled || isBusy ? 1 : 0.4))
            if knob > 0 {
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: inset * 2 + knob + offset)
            }
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            if isBusy {
                ProgressView().tint(.black)
            } else {
                Text(title).font(.headline)
            }
        }
        .foregroundColor(.black)
    }

    private func reset() {
        reachedEnd = false
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { offset = 0 }
    }
}

// MARK: - Testing a failed send

/// Debug builds only: launched with `KACHAT_FAIL_SEND=1` in the environment (in the Simulator:
/// `SIMCTL_CHILD_KACHAT_FAIL_SEND=1 xcrun simctl launch ...`), every Send Kaspa send fails after a
/// moment as if the phone were offline - so the failure path can be seen without cutting the
/// Mac's network. Nothing is built or broadcast. Does nothing in release builds.
enum SendFailureSimulation {
    static func failIfEnabled() async throws {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["KACHAT_FAIL_SEND"] == "1" else { return }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        throw URLError(.notConnectedToInternet)
        #endif
    }
}

// MARK: - Swipe up to send

/// The words a swipe-up screen uses: a Kaspa send by default, a .kachat claim with `.claim`.
struct SwipeUpLabels {
    var release: LocalizedStringKey = "Release to Send"
    var working: LocalizedStringKey = "Sending"
    var workingDetail: LocalizedStringKey = "Broadcasting to the Kaspa BlockDAG..."
    var done: LocalizedStringKey = "Sent"
    /// Before the recipient line: "to kaspa:..." or "for name.kachat".
    var recipientWord = "to"
    var failedFallback = "The send didn't go out."

    static let send = SwipeUpLabels()
    static let buy = SwipeUpLabels(
        release: "Release to Buy",
        working: "Buying",
        workingDetail: "Sending the purchase to the Kaspa BlockDAG...",
        done: "Name Bought",
        recipientWord: "for",
        failedFallback: "The purchase didn't go out."
    )
    /// Any other transaction (a .kachat listing, transfer, offer...): `done` is its finished title.
    static func transaction(done: LocalizedStringKey) -> SwipeUpLabels {
        SwipeUpLabels(
            release: "Release to Confirm",
            working: "Sending",
            workingDetail: "Broadcasting to the Kaspa BlockDAG...",
            done: done,
            recipientWord: "for",
            failedFallback: "The transaction didn't go out."
        )
    }
    static let claim = SwipeUpLabels(
        release: "Release to Claim",
        working: "Claiming",
        workingDetail: "Committing to the Kaspa BlockDAG...",
        done: "Claim Started",
        recipientWord: "for",
        failedFallback: "The claim didn't start."
    )
}

/// A send screen's scroll view with "Swipe up to Send" pinned at the bottom. Press the bar and
/// drag it up: the whole screen moves up with the finger, and the send screen rises from below
/// in its place. Letting go about a third of the way up sends: the send screen takes over the full screen,
/// a BlockDAG runs across it while the transaction goes out, and then it shows the
/// confirmation (`sent`). Letting go sooner springs it back. A send that fails or never starts
/// shows "Failed" there with the screen's error, and Try Again brings the form back as it was.
/// Only the bar answers - scrolling the form never sends.
/// VoiceOver gets a plain activate action on the bar.
///
/// It draws its own header (Cancel and the screen's title) in place of the navigation bar, so
/// the header goes up with the rest of the screen.
struct SwipeUpToSendScrollView<Content: View>: View {
    /// The header's title, e.g. "Send Kaspa".
    let screenTitle: String
    let onCancel: () -> Void
    /// A step-by-step send's review: the header shows Back (and Cancel on the right).
    var onBack: (() -> Void)? = nil
    /// The title as a ready `Text` (a localized key with values), in place of `screenTitle`.
    var titleText: Text? = nil
    /// False: only Back in the header (a step pushed inside another sheet, which Back leaves).
    var showsCancel = true
    let title: LocalizedStringKey
    let isBusy: Bool
    let isEnabled: Bool
    /// What is being sent, for the sending screen; nil leaves the line out.
    var amountSompi: UInt64?
    var recipient: String?
    /// Set by the screen once the send went out: the confirmation shows it.
    let sent: SentTransaction?
    /// The screen's error for a send that failed, shown under "Failed".
    var failureMessage: String?
    var labels: SwipeUpLabels = .send
    /// What the Face ID prompt says, when this screen does something other than send Kaspa.
    var authReason: String? = nil
    /// For an action that ends without a `SentTransaction` (a .kachat claim): true once it
    /// worked, and `outcome` shows under the title in place of the transaction.
    var succeeded = false
    var outcome: AnyView?
    /// The confirmation's Done.
    let onDone: () -> Void
    let action: () -> Void
    @ViewBuilder let content: Content

    private enum Phase { case form, sending }

    /// How far the screen has been pushed up.
    @State private var lift: CGFloat = 0
    /// Past the threshold: letting go sends.
    @State private var armed = false
    @State private var phase: Phase = .form
    /// The DAG gets a moment on screen before the confirmation, however fast the send was.
    @State private var dagShown = false
    /// The screen went busy after the swipe: the send really started. State, not `isBusy`
    /// itself, so the delayed check in `startSending` reads today's value rather than the one
    /// its closure captured.
    @State private var sendStarted = false
    /// `sent` arrived. Read through state for the same reason as `sendStarted`: an `onChange`
    /// closure can still hold the view from before the change.
    @State private var confirmed = false
    /// The send ended without a transaction: the sending screen shows "Failed".
    @State private var failed = false
    /// Face ID is up for this swipe: nothing else starts until it answers.
    @State private var authPending = false

    private static var barHeight: CGFloat { 64 }
    private static var settle: Animation { .spring(response: 0.45, dampingFraction: 0.86) }

    private var active: Bool { isEnabled && !isBusy && !authPending }

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height + geometry.safeAreaInsets.bottom
            let threshold = max(120, height * 0.3)
            ZStack(alignment: .top) {
                form(threshold: threshold)
                    .offset(y: -lift)
                if lift > 0 || phase == .sending {
                    SendProgressScreen(
                        amountSompi: amountSompi,
                        recipient: recipient,
                        sent: dagShown ? sent : nil,
                        done: dagShown && (sent != nil || succeeded),
                        outcome: outcome,
                        labels: labels,
                        failure: failed && dagShown
                            ? (failureMessage ?? AppLocalization.string(labels.failedFallback))
                            : nil,
                        isSending: phase == .sending,
                        armed: armed,
                        onDone: onDone,
                        onTryAgain: returnToForm
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .offset(y: max(0, height - lift))
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .interactiveDismissDisabled(phase == .sending)
        .onChange(of: isBusy) { busy in
            if busy {
                sendStarted = true
            } else {
                // The screen sets `sent` as it stops being busy; give that a moment to land.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    if !confirmed { showFailure() }
                }
            }
        }
        .onChange(of: sent) { sent in
            if sent != nil {
                confirmed = true
                Haptics.success()
            }
        }
        .onChange(of: succeeded) { ok in
            if ok {
                confirmed = true
                Haptics.success()
            }
        }
    }

    private func form(threshold: CGFloat) -> some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                content
            }
        }
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom) { bar(threshold: threshold) }
    }

    /// Cancel (or Back) and the title, where the navigation bar would be.
    private var header: some View {
        SendStepHeader(titleText: titleText ?? Text(LocalizedStringKey(screenTitle)), onBack: onBack,
                       onCancel: showsCancel || onBack == nil ? onCancel : nil)
    }

    private func bar(threshold: CGFloat) -> some View {
        VStack(spacing: 6) {
            Image(systemName: armed ? "checkmark" : "chevron.up")
                .font(.headline.weight(.bold))
            Text(armed ? labels.release : title)
                .font(.headline)
        }
        .foregroundColor(.black)
        .frame(maxWidth: .infinity)
        .frame(height: Self.barHeight)
        .background(
            Capsule()
                .fill(Color.accentColor.opacity(isEnabled ? 1 : 0.4))
        )
        .contentShape(Capsule())
        .gesture(
            // Global coordinates: the bar moves with the screen, so its own space would chase
            // the finger.
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    guard active, phase == .form else { return }
                    if lift == 0 && value.translation.height < 0 {
                        // a keyboard left up (a custom fee) would sit over the rising screen
                        dismissSystemKeyboard()
                        Haptics.impact(.light)
                    }
                    lift = max(0, -value.translation.height)
                    let pastThreshold = lift >= threshold
                    if pastThreshold != armed {
                        armed = pastThreshold
                        Haptics.impact(pastThreshold ? .medium : .light)
                    }
                }
                .onEnded { _ in
                    // a touch while Face ID is up leaves the waiting send as it is
                    guard phase == .form, !authPending else { return }
                    if armed && active {
                        authenticateThenSend()
                    } else {
                        armed = false
                        withAnimation(Self.settle) { lift = 0 }
                    }
                }
        )
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            guard active, phase == .form else { return }
            authenticateThenSend()
        }
    }

    /// Kaspa never leaves on the swipe alone: Face ID first, on every screen that swipes up.
    /// Declined, the screen settles back with everything still filled in.
    private func authenticateThenSend() {
        guard !authPending, phase == .form else { return }
        authPending = true
        DeviceAuth.authenticate(
            reason: authReason ?? AppLocalization.string("Confirm sending Kaspa"),
            onSuccess: {
                startSending()
                authPending = false
            },
            onFailure: {
                authPending = false
                armed = false
                withAnimation(Self.settle) { lift = 0 }
            }
        )
    }

    private func startSending() {
        guard phase == .form else { return }
        armed = false
        dagShown = false
        sendStarted = isBusy
        confirmed = false
        failed = false
        // Only the movement animates: switching the screen's text and DAG to "sending" inside
        // the animation cross-faded two copies of them.
        phase = .sending
        withAnimation(Self.settle) {
            lift = UIScreen.main.bounds.height * 2
        }
        action()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation(.easeInOut(duration: 0.35)) { dagShown = true }
        }
        // A send that never started (a check failed before it went busy) fails too.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !sendStarted { showFailure() }
        }
    }

    /// The send ended without a transaction: "Failed" with the error, once the DAG has had its
    /// moment.
    private func showFailure() {
        guard phase == .sending, !confirmed, !failed else { return }
        withAnimation(.easeInOut(duration: 0.35)) { failed = true }
        Haptics.error()
    }

    /// Try Again: back down to the form, filled in as it was.
    private func returnToForm() {
        guard phase == .sending, !confirmed else { return }
        withAnimation(Self.settle) {
            lift = 0
        }
        // After the screen is back down, so the sending screen doesn't change on its way out.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            phase = .form
            failed = false
        }
    }
}

/// The full screen a swipe-up send moves to: a BlockDAG running across while the transaction
/// goes out, then the confirmation - what was sent, to whom, and the transaction id as a link to
/// the block explorer Settings names - or "Failed" with the error and Try Again.
private struct SendProgressScreen: View {
    let amountSompi: UInt64?
    let recipient: String?
    /// Non-nil once confirmed.
    let sent: SentTransaction?
    /// It worked: `sent` (with its transaction) or a screen's own `outcome`.
    let done: Bool
    let outcome: AnyView?
    let labels: SwipeUpLabels
    /// Non-nil once the send failed: the error to show.
    let failure: String?
    /// False while the swipe is still being dragged (a preview of what's coming).
    let isSending: Bool
    let armed: Bool
    let onDone: () -> Void
    let onTryAgain: () -> Void

    /// Sent or failed: the DAG steps back and the outcome takes over.
    private var finished: Bool { done || failure != nil }

    /// It may have gone through, so there's nothing to try again.
    private var outcomeUnknown: Bool { failure == SendOutcomeUnknownError.message }

    private var explorerURL: URL? {
        sent.flatMap { AppSettings.load().kaspaExplorer.txURL(for: $0.txId) }
    }

    private func kasText(_ sompi: UInt64) -> String {
        var text = String(format: "%.8f", Double(sompi) / 100_000_000.0)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "\(text) \(KaspaUnit.symbol)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // From the top rather than centred: while the swipe is still rising, the DAG is the
            // first thing that comes into view.
            ZStack {
                BlockDAGAnimationView(highlight: isSending && failure == nil)
                    .frame(height: 200)
                    .opacity(finished ? 0.35 : 1)
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.scaled(size: 72, weight: .semibold))
                        .foregroundStyle(.black, Color.accentColor)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                } else if outcomeUnknown {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.scaled(size: 72, weight: .semibold))
                        .foregroundStyle(.black, Color.orange)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                } else if failure != nil {
                    Image(systemName: "xmark.circle.fill")
                        .font(.scaled(size: 72, weight: .semibold))
                        .foregroundStyle(.white, Color.red)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }

            VStack(spacing: 6) {
                Text(done ? labels.done : outcomeUnknown ? "Not confirmed" : failure != nil ? "Failed"
                     : (isSending ? labels.working : (armed ? labels.release : "Keep Swiping")))
                    .font(.largeTitle.weight(.bold))
                if let amount = sent?.amountSompi ?? amountSompi {
                    Text(verbatim: kasText(amount))
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.accentColor)
                }
                if let to = sent?.recipient ?? recipient, !to.isEmpty {
                    Text(verbatim: "\(AppLocalization.string(labels.recipientWord)) \(to)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 32)
                }
                // Before that, the title above already says Keep Swiping or Release.
                if !finished && isSending {
                    Text(labels.workingDetail)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                }
            }
            .padding(.top, 24)

            if let failure {
                Label {
                    Text(verbatim: failure)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.subheadline)
                .foregroundColor(outcomeUnknown ? .orange : .red)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(sendKaspaGlass(cornerRadius: 14))
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .transition(.opacity)
            }

            if let sent {
                VStack(spacing: 8) {
                    if let explorerURL {
                        Link(destination: explorerURL) {
                            HStack(spacing: 6) {
                                Text(sent.txId)
                                    .font(.system(.footnote, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Image(systemName: "arrow.up.right.square")
                                    .font(.footnote)
                            }
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity)
                            .background(sendKaspaGlass(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        Text("Tap the transaction to open it in the explorer.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text(sent.txId)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .transition(.opacity)
            }

            if done, let outcome {
                ScrollView {
                    outcome
                        .padding(.horizontal, 20)
                }
                .padding(.top, 20)
                .transition(.opacity)
            }

            Spacer(minLength: 0)

            if done || outcomeUnknown {
                Button(action: onDone) {
                    Text("Done")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .foregroundColor(.black)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if failure != nil {
                Button(action: onTryAgain) {
                    Text("Try Again")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .foregroundColor(.black)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.top, 70)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemBackground))
    }
}

/// Kaspa's BlockDAG drifting right to left: columns of blocks, each pointing back at one to three
/// blocks of the column before (several parents, not a chain). With `highlight`, one block -
/// the transaction going out - lights up as it enters on the right, and the blocks after it
/// point back at it in the same colour. Laid out from each
/// column's index, so the picture is stable as it moves.
struct BlockDAGAnimationView: View {
    var highlight = true

    @State private var start = Date()
    /// When `highlight` turned on: the block entering on the right then is the transaction's.
    @State private var highlightStart: Date?

    private static let spacing: CGFloat = 54
    /// Points per second.
    private static let speed: CGFloat = 60
    private static let block: CGFloat = 18

    /// A stable pseudo-random number for (column, salt).
    private static func hash(_ column: Int, _ salt: Int) -> Int {
        var x = UInt64(bitPattern: Int64(column &* 73_856_093 ^ salt &* 19_349_663))
        x ^= x >> 33; x &*= 0xff51afd7ed558ccd; x ^= x >> 33
        return Int(x % 1_000_003)
    }

    private static func count(_ column: Int) -> Int { 1 + hash(column, 1) % 3 }

    /// Block `row` of `column`'s centre height, as a fraction of the view.
    private static func y(_ column: Int, _ row: Int) -> CGFloat {
        let n = count(column)
        let jitter = CGFloat(hash(column, 10 + row) % 100) / 100 * 0.12 - 0.06
        return (CGFloat(row) + 1) / CGFloat(n + 1) + jitter
    }

    /// The parents of block `row` in `column`: rows of `column - 1`.
    private static func parents(_ column: Int, _ row: Int) -> [Int] {
        let previous = count(column - 1)
        let first = hash(column, 20 + row) % previous
        var result = [first]
        if previous > 1, hash(column, 30 + row) % 2 == 0 { result.append((first + 1) % previous) }
        return result
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(start)
                let scroll = CGFloat(elapsed) * Self.speed
                let firstVisible = Int(floor(scroll / Self.spacing)) - 1
                let visibleColumns = Int(size.width / Self.spacing) + 3
                // The column just off the right edge when the send started is the transaction's.
                let highlightScroll = CGFloat((highlightStart ?? start).timeIntervalSince(start)) * Self.speed
                let txColumn = Int((highlightScroll + size.width) / Self.spacing) + 1
                func x(_ column: Int) -> CGFloat { CGFloat(column) * Self.spacing - scroll }
                func point(_ column: Int, _ row: Int) -> CGPoint {
                    CGPoint(x: x(column), y: Self.y(column, row) * size.height)
                }
                let accent = Color.accentColor
                let dim = Color.primary.opacity(0.28)

                // Edges first, under the blocks.
                for column in firstVisible...(firstVisible + visibleColumns) {
                    for row in 0..<Self.count(column) {
                        for parent in Self.parents(column, row) {
                            var path = Path()
                            path.move(to: point(column, row))
                            path.addLine(to: point(column - 1, parent))
                            let lit = highlight && column - 1 == txColumn && parent == 0
                            context.stroke(path, with: .color(lit ? accent.opacity(0.8) : dim), lineWidth: lit ? 2 : 1)
                        }
                    }
                }
                for column in firstVisible...(firstVisible + visibleColumns) {
                    for row in 0..<Self.count(column) {
                        let center = point(column, row)
                        let rect = CGRect(x: center.x - Self.block / 2, y: center.y - Self.block / 2,
                                          width: Self.block, height: Self.block)
                        let shape = Path(roundedRect: rect, cornerRadius: 5)
                        if highlight && column == txColumn && row == 0 {
                            let glow = Path(roundedRect: rect.insetBy(dx: -7, dy: -7), cornerRadius: 9)
                            let pulse = 0.25 + 0.2 * sin(elapsed * 4)
                            context.fill(glow, with: .color(accent.opacity(pulse)))
                            context.fill(shape, with: .color(accent))
                        } else {
                            context.fill(shape, with: .color(Color.primary.opacity(0.16)))
                            context.stroke(shape, with: .color(Color.primary.opacity(0.45)), lineWidth: 1)
                        }
                    }
                }
            }
        }
        .onAppear {
            start = Date()
            if highlight { highlightStart = start }
        }
        .onChange(of: highlight) { on in
            highlightStart = on ? Date() : nil
        }
        .accessibilityHidden(true)
    }
}

// MARK: - From (which of your addresses a send comes out of)

/// Where a send comes from: the chatting address (every send screen's default), or one of the
/// spending addresses picked under Choose an Address.
enum SendSource: Equatable, Hashable {
    case chatting
    case spending(index: Int, address: String, label: String)

    var spendingIndex: Int? {
        if case .spending(let index, _, _) = self { return index }
        return nil
    }

    @MainActor
    var address: String? {
        switch self {
        case .chatting: return WalletManager.shared.currentWallet?.publicAddress
        case .spending(_, let address, _): return address
        }
    }
}

/// A pill to pick one of a few choices, like the amount's currency switch: the chosen one
/// filled in teal. Send screens' From, Request Payment's address.
struct SelectablePill: View {
    let title: LocalizedStringKey
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(selected ? .black : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.horizontal, 6)
                .background(
                    Capsule().fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial))
                )
                .overlay(Capsule().stroke(Color.accentColor.opacity(selected ? 0 : 0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The From section every send screen starts with, so it is always plain which address the
/// Kaspa leaves from: Chatting Address (the default) or Choose an Address (any of your
/// addresses, each marked used or unused), and the chosen address with its balance.
struct SendFromSection: View {
    @Binding var source: SendSource
    /// The chosen address's balance, loaded here (nil while it loads) - the screen's Available.
    @Binding var availableSompi: UInt64?
    /// Opened from one address's own page (its history's Send): that address only, no choice.
    var isLocked: Bool = false
    @State private var showPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("From")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            if !isLocked {
                HStack(spacing: 10) {
                    SelectablePill(title: "Chatting Address", selected: source == .chatting) {
                        source = .chatting
                    }
                    SelectablePill(title: "Choose an Address", selected: source != .chatting) {
                        showPicker = true
                    }
                }
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title)
                        .font(.subheadline.weight(.semibold))
                    if let address = source.address {
                        Text(verbatim: "\(address.prefix(14))...\(address.suffix(6))")
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                if let availableSompi {
                    Text(verbatim: "\(KaspaUnit.plain(availableSompi)) \(KaspaUnit.symbol)")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(12)
            .background(sendKaspaGlass(cornerRadius: 14))
        }
        .sheet(isPresented: $showPicker) {
            OwnAddressPicker(title: "Send From", selected: source.address) { picked in
                source = picked
            }
        }
        .task(id: source) {
            availableSompi = nil
            guard let address = source.address else { return }
            // A failed read says nothing about the balance: left unknown, not shown as 0.
            let utxos = try? await NodePoolService.shared.getUtxosByAddresses([address])
            guard !Task.isCancelled, let utxos else { return }
            // what a send can spend: not coins just spent or not yet usable
            let spendable = source == .chatting
                ? WalletService.shared.withdrawalSpendable(utxos)
                : WalletService.shared.unreservedUtxos(utxos)
            availableSompi = spendable.reduce(UInt64(0)) { $0 + $1.amount }
        }
    }

    private var title: String {
        switch source {
        case .chatting: return AppLocalization.string("Chatting Address")
        case .spending(_, _, let label): return label
        }
    }
}

/// Your addresses to pick from - the chatting address, then the spending addresses (the ones
/// Manage Addresses shows, plus hidden ones holding Kaspa) - each with its name, balance and
/// whether it was ever used (a balance means used, else the cached answer, else a history
/// lookup, eight at a time; "Checking" until answered, never a possibly-wrong "Unused").
/// A send's Choose an Address, as a sheet (`OwnAddressPicker`).
struct OwnAddressPicker: View {
    let title: LocalizedStringKey
    let selected: String?
    /// The .kachat market signs its funding inputs as plain P2PK, which a quantum-safe (KIP-22)
    /// address can't be - its picker leaves them out.
    var excludeQuantum: Bool = false
    let onPick: (SendSource) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                OwnAddressList(selected: selected, excludeQuantum: excludeQuantum) { picked in
                    onPick(picked)
                    dismiss()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// The address list itself, to sit on a screen (Request Payment's "Where do you want to be
/// paid?") or in `OwnAddressPicker`'s sheet: the chatting address, then the spending addresses,
/// as tappable cards with Used / Unused and the balance; the picked one has a check.
struct OwnAddressList: View {
    let selected: String?
    var excludeQuantum: Bool = false
    let onPick: (SendSource) -> Void
    @State private var entries: [SpendingAddressEntry]?
    @State private var used: [String: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let chatting = WalletManager.shared.currentWallet {
                sectionTitle("Chatting Address")
                row(title: AppLocalization.string("Chatting Address"), address: chatting.publicAddress,
                    balance: chatting.balanceSompi) { .chatting }
            }
            sectionTitle("Spending Addresses")
                .padding(.top, 8)
            if let entries {
                ForEach(entries) { entry in
                    row(title: entry.displayLabel, address: entry.address, balance: entry.balanceSompi) {
                        .spending(index: entry.index, address: entry.address, label: entry.displayLabel)
                    }
                }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .padding(.vertical, 12)
            }
        }
        .task {
            let all = await WalletManager.shared.getSpendingAddressList()
            let shown = all
                .filter { !$0.hidden || $0.balanceSompi > 0 }
                .filter { !excludeQuantum || !$0.isQuantum }
                .sorted { $0.index < $1.index }
            entries = shown
            await checkUsed(shown)
        }
    }

    private func sectionTitle(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
    }

    private func checkUsed(_ shown: [SpendingAddressEntry]) async {
        let chat = WalletService.shared
        var all: [(address: String, balance: UInt64)] = shown.map { ($0.address, $0.balanceSompi) }
        if let wallet = WalletManager.shared.currentWallet {
            all.insert((wallet.publicAddress, wallet.balanceSompi ?? 0), at: 0)
        }
        var toProbe: [String] = []
        for item in all {
            if item.balance > 0 {
                used[item.address] = true
            } else if let cached = chat.cachedSpendingAddressUsedState(item.address) {
                used[item.address] = cached
            } else {
                toProbe.append(item.address)
            }
        }
        var pending = toProbe.makeIterator()
        await withTaskGroup(of: (String, Bool?).self) { group in
            for _ in 0..<8 {
                guard let address = pending.next() else { break }
                group.addTask { (address, await chat.spendingAddressUsedState(address)) }
            }
            while let (address, answer) = await group.next() {
                if let answer { used[address] = answer }
                if let next = pending.next() {
                    group.addTask { (next, await chat.spendingAddressUsedState(next)) }
                }
            }
        }
    }

    @ViewBuilder
    private func usedTag(_ address: String) -> some View {
        switch used[address] {
        case true?:
            Text("Used")
                .font(.caption2.weight(.bold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
        case false?:
            Text("Unused")
                .font(.caption2.weight(.bold))
                .foregroundColor(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.green.opacity(0.15)))
        case nil:
            Text("Checking")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
        }
    }

    private func row(title: String, address: String, balance: UInt64?, source: @escaping () -> SendSource) -> some View {
        let isSelected = address == selected
        return Button {
            Haptics.impact(.light)
            onPick(source())
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verbatim: title)
                            .font(.subheadline.weight(.semibold))
                        usedTag(address)
                    }
                    Text(verbatim: "\(address.prefix(14))...\(address.suffix(6))")
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let balance {
                    Text(verbatim: "\(KaspaUnit.plain(balance)) \(KaspaUnit.symbol)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(balance > 0 ? .primary : .secondary)
                }
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .padding(14)
            .background(sendKaspaGlass(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.accentColor.opacity(isSelected ? 0.9 : 0), lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension View {
    /// The Send Kaspa sheets' size. On iPad a `.large` sheet is a short centred form, too short
    /// for Review (the fee hint ended up under the slide-to-send bar); page sizing gives it most
    /// of the screen. iPhone is unchanged, and iPadOS 17 and earlier keep the form size.
    @ViewBuilder
    func sendKaspaSheetSizing() -> some View {
        if #available(iOS 18.0, *) {
            presentationSizing(.page)
        } else {
            self
        }
    }
}
