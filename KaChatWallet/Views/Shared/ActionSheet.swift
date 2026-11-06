import SwiftUI

/// The app's frosted card. Every other place that draws one has its own file-private copy of
/// this; this file needs one too because it is not in any of them.
private func glassBackground(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
}

/// One option in a half-sheet menu: an icon, a title, and a line saying what the option does.
///
/// The app's menus used to be popovers and confirmation dialogs of bare labels, which have room
/// for a verb and nothing else. Every menu that has since become a sheet - the cold storage
/// account and address menus, Address Actions, the transaction menu below - is built from this,
/// so they read as the same kind of object wherever they appear.
struct ActionSheetRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var tint: Color = .accentColor
    var isBusy: Bool = false
    var isDisabled: Bool = false
    /// An asset image in place of the SF Symbol - the Kaspa logo on "Pay in Kaspa", which every
    /// menu in the app shows with the logo rather than a stand-in glyph.
    var customIcon: Image? = nil
    let action: () -> Void

    /// Set by `ActionSheetTiles`: draw as a square tile (icon over title) instead of a row.
    @Environment(\.actionSheetTiles) private var asTile

    var body: some View {
        if asTile {
            tile
        } else {
            row
        }
    }

    /// The square form, for long-press menus: the icon and a short title, so a glance says what
    /// each one does. The explanatory line becomes the VoiceOver hint.
    private var tile: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    if isBusy {
                        ProgressView()
                    } else if let customIcon {
                        customIcon
                            .resizable()
                            .scaledToFit()
                            .frame(width: 26, height: 26)
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(tint)
                    }
                }
                .frame(height: 30)
                Text(LocalizedStringKey(title))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(tint == .accentColor ? .primary : tint)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .frame(height: ActionSheetTileMetrics.tileHeight)
            .background(glassBackground(cornerRadius: 18))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .opacity(isDisabled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isBusy || isDisabled)
        .accessibilityHint(Text(LocalizedStringKey(subtitle)))
    }

    private var row: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Group {
                    if let customIcon {
                        customIcon
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                    } else {
                        Image(systemName: systemImage)
                            .font(.scaled(size: 18, weight: .semibold))
                            .foregroundColor(tint)
                    }
                }
                .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    // Looked up, not shown verbatim: `Text(String)` skips Localizable.strings, so
                    // every action sheet read in English in all 18 other languages. A title
                    // with no translation still shows as written.
                    Text(LocalizedStringKey(title))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(tint == .accentColor ? .primary : tint)
                    Text(LocalizedStringKey(subtitle))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if isBusy { ProgressView().controlSize(.small) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(glassBackground(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isBusy || isDisabled)
    }
}

private struct ActionSheetTilesKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether `ActionSheetRow`s draw as square tiles (inside `ActionSheetTiles`).
    var actionSheetTiles: Bool {
        get { self[ActionSheetTilesKey.self] }
        set { self[ActionSheetTilesKey.self] = newValue }
    }
}

/// Lays the `ActionSheetRow`s inside it out as square tiles, three to a row, so each option reads
/// at a glance instead of as a paragraph.
struct ActionSheetTiles<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let spacing = ActionSheetTileMetrics.spacing
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: 3), spacing: spacing) {
            content
        }
        .environment(\.actionSheetTiles, true)
    }
}

/// Sizes for `ActionSheetTiles`, and a sheet height to fit them.
enum ActionSheetTileMetrics {
    static let tileHeight: CGFloat = 96
    static let spacing: CGFloat = 12

    /// The grid's height for `count` tiles.
    static func gridHeight(for count: Int) -> CGFloat {
        let rows = CGFloat(max(1, (count + 2) / 3))
        return rows * tileHeight + (rows - 1) * spacing
    }

    /// A tiles sheet's height: its title area, the grid, and the bottom padding.
    static func sheetHeight(tiles count: Int, header: CGFloat = 70) -> CGFloat {
        header + gridHeight(for: count) + 44
    }
}

/// Renaming something, in a half sheet.
///
/// A system alert with a text field is the platform's default for this, and it is the wrong
/// shape: it steals the whole screen for one word, and its field is a cramped afterthought. This
/// is the same sheet every other cold-storage action already uses.
struct RenameSheet: View {
    let title: String
    var subtitle: String?
    var fieldLabel: String = "Name"
    @Binding var text: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 4)

            TextField(fieldLabel, text: $text)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focused)
                .onSubmit(save)
                .padding(14)
                .background(glassBackground(cornerRadius: 16))

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundColor(.primary)
                    .background(glassBackground(cornerRadius: 16))

                Button("Save", action: save)
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundColor(.black)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.accentColor.opacity(trimmed.isEmpty ? 0.4 : 1))
                    )
                    .disabled(trimmed.isEmpty)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(260)])
        .presentationDragIndicator(.visible)
        // A turn later: the field does not exist yet on the tap that presented this.
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        Haptics.success()
        dismiss()
    }
}

/// So the transaction menu can be presented with `.sheet(item:)`. A txid is already the identity
/// of a transaction, and the property is computed, so it stays out of the Codable synthesis.
extension KaspaFullTransactionResponse: Identifiable {
    var id: String { transactionId }
}

/// What to do with a transaction you tapped in an address history: look at it, or record it.
///
/// Shared by cold storage history, the spending-address histories and the chatting address, all
/// three of which used to raise their own identical confirmation dialog.
struct TransactionActionsSheet: View {
    let transaction: KaspaFullTransactionResponse
    /// The address the history was viewed under, which is what decides whether this reads as
    /// money in or money out.
    let address: String
    let onOpenExplorer: () -> Void
    /// Nil candidate means the transaction has no side involving `address` we can price, so
    /// there is nothing to record and the option is not offered.
    let onAddToPortfolio: (PortfolioCandidateTransaction) -> Void

    @Environment(\.dismiss) private var dismiss

    private var candidate: PortfolioCandidateTransaction? {
        PortfolioCandidateTransaction(transaction: transaction, address: address)
    }

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("Transaction")
                    .font(.headline)
                if let candidate {
                    Text(summary(candidate))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(transaction.transactionId)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .multilineTextAlignment(.center)
            .padding(.top, 8)

            ActionSheetRow(
                title: "Open in Explorer",
                subtitle: "Opens this transaction on the block explorer.",
                systemImage: "safari"
            ) {
                dismiss()
                onOpenExplorer()
            }

            if let candidate {
                ActionSheetRow(
                    title: "Add to Portfolio",
                    subtitle: "Records it as a buy or a sell in a portfolio of your choosing.",
                    systemImage: "chart.pie.fill"
                ) {
                    dismiss()
                    onAddToPortfolio(candidate)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .presentationDetents([.height(candidate == nil ? 250 : 320)])
        .presentationDragIndicator(.visible)
    }

    private func summary(_ candidate: PortfolioCandidateTransaction) -> String {
        let direction = candidate.isOutgoing ? "Sent" : "Received"
        return "\(direction) \(PortfolioFormat.kas(candidate.amountKas)) on "
            + candidate.timestamp.formatted(date: .abbreviated, time: .shortened)
    }
}


/// A yes/no confirmation, in a half sheet.
///
/// The app's confirmations were `.confirmationDialog`s - a stack of bare verbs with the reason
/// squeezed into a small grey line above them. As a sheet the consequence gets a full row of its
/// own next to the action it belongs to, which is what someone about to log out or delete
/// something is actually reading for.
struct ConfirmActionSheet: View {
    let title: String
    let confirmTitle: String
    /// What actually happens if they go ahead - the row's second line.
    let confirmSubtitle: String
    var confirmSystemImage: String = "checkmark.circle"
    var isDestructive: Bool = true
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.top, 20)
                .padding(.bottom, 4)

            ActionSheetRow(
                title: confirmTitle,
                subtitle: confirmSubtitle,
                systemImage: confirmSystemImage,
                tint: isDestructive ? .red : .accentColor
            ) { dismiss(); onConfirm() }

            ActionSheetRow(
                title: "Cancel",
                subtitle: "Leave everything as it is.",
                systemImage: "xmark"
            ) { dismiss() }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
    }
}

/// The warning before an account is deleted, from Settings or the sign-in screen. Nothing can
/// bring the account back without its seed phrase (and passphrase), so it says that first.
struct DeleteAccountSheet: View {
    /// What goes: the Delete row's second line.
    let confirmSubtitle: String
    /// Settings only: a signed-out account on the sign-in screen has no seed phrase open to show.
    var onViewSeedPhrase: (() -> Void)? = nil
    /// This account hasn't finished the backup steps: the warning says so. Deleting stays possible
    /// (an empty account someone doesn't want shouldn't have to be backed up first).
    var notBackedUp = false
    /// Settings only: into the backup steps, in place of the seed phrase row.
    var onBackUp: (() -> Void)? = nil
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.scaled(size: 34, weight: .semibold))
                    .foregroundColor(.red)
                    .padding(.top, 24)

                Text("Delete Account")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                if notBackedUp {
                    Text("This account isn't backed up. If you delete it now, it and its funds can never be recovered.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                    if onBackUp == nil {
                        Text("To back it up first, sign in to it and tap the backup strip at the top of any tab.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }

                Text("Make sure your 12 or 24 words are backed up, and your passphrase too if you have one. They are the only way to recover this account and its funds.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 8)

                if notBackedUp, let onBackUp {
                    ActionSheetRow(
                        title: "Back Up Account",
                        subtitle: "Write down your 12 or 24 words before you delete.",
                        systemImage: "exclamationmark.shield",
                        action: onBackUp
                    )
                } else if let onViewSeedPhrase {
                    ActionSheetRow(
                        title: "View 12 or 24 Words and Passphrase",
                        subtitle: "The passphrase shows too, if this account has one.",
                        systemImage: "key",
                        action: onViewSeedPhrase
                    )
                }

                ActionSheetRow(
                    title: "Delete Account",
                    subtitle: confirmSubtitle,
                    systemImage: "trash",
                    tint: .red
                ) { dismiss(); onConfirm() }

                ActionSheetRow(
                    title: "Cancel",
                    subtitle: "Leave everything as it is.",
                    systemImage: "xmark"
                ) { dismiss() }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Sent confirmation

/// A completed Kaspa send, for `SentConfirmationSheet`. Identifiable on the txid so it can drive
/// a `.sheet(item:)` directly.
struct SentTransaction: Identifiable, Equatable {
    let txId: String
    /// Amount in sompi. nil omits the amount line - a consolidation has no meaningful "to whom"
    /// or "how much" to report.
    var amountSompi: UInt64?
    /// Who it went to: a contact's name, a KNS domain, an address. nil omits the line.
    var recipient: String?

    var id: String { txId }
}

/// The half sheet every successful Kaspa send ends on: a checkmark, what was sent, and the
/// transaction id as a live link to whichever block explorer Settings names.
///
/// This used to be `WithdrawalSuccessCard`, a dimmed full-screen overlay, and only the two
/// withdraw screens had it - other sends just closed the sheet and
/// left you with nothing to check. A send is the one moment where the txid is worth handing over,
/// so it is a link rather than text: tapping it opens the explorer.
///
/// The explorer URL is resolved here rather than passed in, so a call site only needs the txid.
struct SentConfirmationSheet: View {
    let transaction: SentTransaction
    let onDone: () -> Void

    private var explorerURL: URL? {
        AppSettings.load().kaspaExplorer.txURL(for: transaction.txId)
    }

    /// Trailing zeros trimmed - "1.5 KAS", not "1.50000000 KAS".
    private var amountText: String? {
        guard let sompi = transaction.amountSompi else { return nil }
        var text = String(format: "%.8f", Double(sompi) / 100_000_000.0)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "\(text) \(KaspaUnit.symbol)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark.circle.fill")
                .font(.scaled(size: 52))
                .foregroundColor(.green)
                .padding(.top, 28)

            Text("Sent")
                .font(.title3.weight(.bold))
                .padding(.top, 12)

            if let amountText {
                Text(amountText)
                    .font(.headline)
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }

            if let recipient = transaction.recipient, !recipient.isEmpty {
                Text("to \(recipient)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 32)
                    .padding(.top, 2)
            }

            // The txid, as the link. Middle truncation because both ends identify it and the
            // middle does not - a leading-truncated hash is unrecognisable.
            if let explorerURL {
                Link(destination: explorerURL) {
                    HStack(spacing: 6) {
                        Text(transaction.txId)
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
                    .background(glassBackground(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.top, 20)
            } else {
                // No explorer configured: the id is still worth showing, just not as a link.
                Text(transaction.txId)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
            }

            Text("Tap the transaction to open it in the explorer.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 8)

            Spacer(minLength: 0)

            Button(action: onDone) {
                Text("Done")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundColor(.black)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The detent every `SentConfirmationSheet` uses, so the sheet is the same size wherever a send
/// finishes. Taller when there is a recipient line to show.
extension SentTransaction {
    var sheetHeight: CGFloat {
        let hasRecipient = !(recipient ?? "").isEmpty
        return hasRecipient ? 420 : 390
    }
}

// MARK: - Coin list failure

/// In place of an empty coin list when the node could not be asked. An outage used to render
/// as "no coins", which on a cold storage address is the wrong thing to believe.
struct UtxoLoadFailureRow: View {
    let detail: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Couldn't load the coins at this address", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.red)
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
            Button("Try Again", action: retry)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Type that follows the user's text size

extension Font {
    /// A fixed point size, scaled by the user's Dynamic Type setting the way the system text
    /// styles are. 173 places in the views set a point size directly and stayed that size
    /// however large the person set their text; this keeps the design's proportions and
    /// grows with the setting.
    static func scaled(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: UIFontMetrics.default.scaledValue(for: size), weight: weight, design: design)
    }
}

// MARK: - Underline tab bar

/// The app's tab bar for switching pages inside a screen: bold teal labels (dimmed when not
/// selected), a teal bar under the selected one, a divider below. Used by Your Domains, Cold
/// Storage, Manage Addresses, .kachat and Connection Settings.
struct UnderlineTabBar<Tab: Hashable>: View {
    let tabs: [(tab: Tab, title: String)]
    @Binding var selection: Tab

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(tabs.indices, id: \.self) { index in
                    let item = tabs[index]
                    let isSelected = selection == item.tab
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { selection = item.tab }
                    } label: {
                        VStack(spacing: 8) {
                            Text(LocalizedStringKey(item.title))
                                .font(.subheadline.weight(.bold))
                                .foregroundColor(isSelected ? .accentColor : .accentColor.opacity(0.5))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 12)
                            Rectangle()
                                .fill(isSelected ? Color.accentColor : Color.clear)
                                .frame(height: 2.5)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            Divider()
        }
    }
}

// MARK: - Wallet action tile

