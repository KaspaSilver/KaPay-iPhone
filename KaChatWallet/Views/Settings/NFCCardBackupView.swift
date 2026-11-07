#if canImport(CoreNFC) && !targetEnvironment(macCatalyst)
import SwiftUI

/// Settings > Back Up to NFC Card, behind the seed phrase's biometric gate and only offered for an
/// account with a passphrase. Two taps: the first reads the card to learn whether it needs a new PIN
/// or already holds a backup, the second saves. The passphrase is never written to the card.
/// It never clears the "not backed up" strip at the top of each tab: the written seed phrase stays the main
/// copy.
struct NFCCardBackupView: View {
    private enum Step {
        case intro, details, erase, saved, erased
    }

    @EnvironmentObject private var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .intro
    @State private var card: NFCCardStatus?
    @State private var pin = ""
    /// A new PIN, typed again: a typo here would lock the backup behind a PIN nobody knows.
    @State private var confirmPIN = ""
    @State private var pinCleared = false
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var showEraseConfirmation = false
    @State private var showReplaceConfirmation = false

    private var pinValid: Bool {
        NFCCard.isValidPIN(pin)
    }

    /// The PIN can go to the card: a valid one, typed twice when it's a new one.
    private var canSave: Bool {
        guard let card, pinValid else { return false }
        return card.pinSet || pin == confirmPIN
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch step {
                    case .intro: intro
                    case .details: details
                    case .erase: erase
                    case .saved: finished(title: "Backup saved",
                                          detail: "It was read back from the card and checked. To restore it, choose Import Existing Account, then Restore from NFC Card, and enter your PIN and passphrase. Your passphrase isn't on the card, so keep it and your written 12 or 24 words safe.")
                    case .erased: finished(title: "Backup erased",
                                           detail: pinCleared
                                               ? "The backup and PIN are gone from this card. The next backup on it will ask you to set a new PIN."
                                               : "The backup is gone from this card. Its PIN stays the same.")
                    }
                }
                .padding()
            }
            .navigationTitle("NFC Card Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step != .saved && step != .erased {
                        Button("Cancel") { dismiss() }
                            .disabled(busy)
                    }
                }
            }
            .alert("NFC Card", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .confirmationDialog("Erase the backup on this card?", isPresented: $showEraseConfirmation, titleVisibility: .visible) {
                Button("Erase Backup", role: .destructive) {
                    Task { @MainActor in await eraseBackup() }
                }
            } message: {
                Text("This can't be undone.")
            }
            .confirmationDialog("Replace the backup on this card?", isPresented: $showReplaceConfirmation, titleVisibility: .visible) {
                Button("Replace Backup", role: .destructive) {
                    Task { @MainActor in await save() }
                }
            } message: {
                Text("The old backup is removed once the new one is confirmed.")
            }
        }
        .interactiveDismissDisabled(busy)
        .onDisappear(perform: clearSecrets)
    }

    private var intro: some View {
        Group {
            Text("Back up to an NFC card")
                .font(.title2.weight(.bold))
            Text("Saves this account's 12 or 24 words on your card, behind a 6-digit PIN.")
                .foregroundColor(.secondary)
            NFCCardNote(icon: "key.fill", tint: .accentColor,
                        text: "Your passphrase is never saved to the card. You'll enter it when you restore, and it's what keeps this account safe if someone gets past the PIN.")
            NFCCardNote(icon: "exclamationmark.triangle.fill", tint: .orange,
                        text: "This isn't cold storage. The card only holds a copy and never creates keys, so keep your 12 or 24 words and passphrase written down too.")
            NFCCardNote(icon: "sdcard.fill", tint: .accentColor,
                        text: "Your card needs the KaChat-NFC software first. Load it from the NFC Card page in Kaspa Quick Start.")
            CreateWalletNextButton(title: "Scan Card", enabled: !busy, busy: busy) {
                Task { @MainActor in await scanCard() }
            }
            Button("Erase a Backup on a Card") {
                step = .erase
            }
            .frame(maxWidth: .infinity)
            .disabled(busy)
        }
    }

    private var details: some View {
        Group {
            if let card {
                if card.hasBackup {
                    NFCCardNote(icon: "exclamationmark.triangle.fill", tint: .orange,
                                text: "This card already holds a backup. Saving replaces it once the new one is confirmed.")
                }
                if card.pinSet {
                    NFCCardSecretField(title: "Card PIN", text: $pin, isNumeric: true)
                    if card.triesRemaining < 5 {
                        Text("\(card.triesRemaining) PIN tries left on this card.")
                            .font(.footnote)
                            .foregroundColor(.orange)
                    }
                } else {
                    NFCCardSecretField(title: "New 6-digit PIN", text: $pin, isNumeric: true)
                    NFCCardSecretField(title: "Re-enter PIN", text: $confirmPIN, isNumeric: true)
                    if NFCCard.isValidPIN(confirmPIN), pin != confirmPIN {
                        Text("The PINs don't match.")
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                    Text("Pick one you'll remember. After 5 wrong tries the PIN is blocked, and the only fix is reloading the card in Kaspa Quick Start, which erases it.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                CreateWalletNextButton(title: card.hasBackup ? "Replace Backup" : "Save to Card", enabled: canSave && !busy, busy: busy) {
                    if card.hasBackup {
                        showReplaceConfirmation = true
                    } else {
                        Task { @MainActor in await save() }
                    }
                }
            }
        }
    }

    private var erase: some View {
        Group {
            Text("Erase a backup")
                .font(.title2.weight(.bold))
            Text("Enter the card's PIN, then tap the card to erase the backup on it.")
                .foregroundColor(.secondary)
            NFCCardSecretField(title: "Card PIN", text: $pin, isNumeric: true)
            CreateWalletNextButton(title: "Erase Backup", enabled: pinValid && !busy, busy: busy) {
                showEraseConfirmation = true
            }
            Button("Back") {
                pin = ""
                step = .intro
            }
            .frame(maxWidth: .infinity)
            .disabled(busy)
        }
    }

    private func finished(title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        Group {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundColor(.green)
                .frame(maxWidth: .infinity)
            Text(title)
                .font(.title2.weight(.bold))
                .frame(maxWidth: .infinity)
            Text(detail)
                .foregroundColor(.secondary)
            CreateWalletNextButton(title: "Done", enabled: true) { dismiss() }
        }
    }

    private func clearSecrets() {
        pin = ""
        confirmPIN = ""
    }

    private func show(_ error: Error) {
        if case NFCCardError.cancelled = error { return }
        errorMessage = error.localizedDescription
    }

    @MainActor
    private func scanCard() async {
        busy = true
        defer { busy = false }
        do {
            let status = try await NFCCard.run(success: "Card found.") { connection in
                try await connection.select()
            }
            guard !status.pinBlocked else { throw NFCCardError.pinBlocked }
            card = status
            step = .details
        } catch {
            show(error)
        }
    }

    @MainActor
    private func save() async {
        guard let card, canSave, !busy else { return }
        busy = true
        defer { busy = false }
        let enteredPIN = pin
        do {
            guard let wallet = walletManager.currentWallet,
                  let seedPhrase = try walletManager.getSeedPhrase() else {
                throw NFCCardError.seedUnavailable
            }
            let passphrase = seedPhrase.passphrase ?? ""
            guard !passphrase.isEmpty else { throw NFCCardError.noPassphrase }
            let family = walletManager.walletSourceFamily(for: wallet.publicAddress)
            let index = walletManager.chattingAddressIndex(for: wallet.publicAddress)
            // The same derivation a restore checks against, so the two can't disagree.
            guard let chattingIndex = UInt32(exactly: index),
                  let chattingAddress = walletManager.previewChattingAddress(
                      words: seedPhrase.words,
                      passphrase: passphrase,
                      chattingIndex: chattingIndex,
                      family: family
                  ) else {
                throw NFCCardError.seedUnavailable
            }
            let payload = NFCCardBackupPayload(
                words: seedPhrase.words,
                chattingAddress: chattingAddress,
                family: family.rawValue,
                chattingAddressIndex: index,
                alias: wallet.alias
            )
            let backup = try await Task.detached(priority: .userInitiated) {
                try NFCCardBackupFormat.seal(payload, pin: enteredPIN)
            }.value
            guard backup.count <= card.maxBackup else { throw NFCCardError.backupTooLarge }

            try await NFCCard.run(success: "Backup saved.") { connection in
                connection.setMessage("Saving. Keep the card still.")
                let current = try await connection.select()
                if current.pinBlocked { throw NFCCardError.pinBlocked }
                // The confirmations were for the card scanned first. An interrupted save can
                // legitimately leave that card with its new PIN and no backup yet.
                // A PIN where the scanned card had none is another card too (this save sets the
                // PIN it then finds, and records that below): stopped before verifyPIN, which
                // would cost that card a try with a PIN that was never its own.
                if (current.hasBackup && !card.hasBackup) || (card.pinSet && !current.pinSet)
                    || (!card.pinSet && current.pinSet) {
                    throw NFCCardError.cardChanged
                }
                if !current.pinSet {
                    try await connection.setPIN(enteredPIN)
                    // The card has this PIN now, whatever happens next: a retry after an
                    // interrupted save finds it set and asks for it as the card's PIN.
                    self.card = NFCCardStatus(
                        pinSet: true,
                        hasBackup: card.hasBackup,
                        pinBlocked: false,
                        triesRemaining: current.triesRemaining,
                        maxBackup: card.maxBackup
                    )
                    confirmPIN = ""
                }
                try await connection.verifyPIN(enteredPIN)
                try await connection.writeBackup(backup)
                guard try await connection.readBackup() == backup else {
                    throw NFCCardError.saveNotConfirmed
                }
            }

            // What's on the card has to open with this PIN, not just match what was sent.
            _ = try await Task.detached(priority: .userInitiated) {
                try NFCCardBackupFormat.open(backup, pin: enteredPIN)
            }.value
            clearSecrets()
            step = .saved
        } catch NFCCardError.wrongPIN(let triesRemaining) {
            pin = ""
            confirmPIN = ""
            self.card = NFCCardStatus(
                pinSet: self.card?.pinSet ?? card.pinSet,
                hasBackup: card.hasBackup,
                pinBlocked: false,
                triesRemaining: triesRemaining,
                maxBackup: card.maxBackup
            )
            show(NFCCardError.wrongPIN(triesRemaining: triesRemaining))
        } catch {
            if case NFCCardError.pinBlocked = error { backToStart() }
            if case NFCCardError.cardChanged = error { backToStart() }
            show(error)
        }
    }

    private func backToStart() {
        clearSecrets()
        card = nil
        step = .intro
    }

    @MainActor
    private func eraseBackup() async {
        guard pinValid else { return }
        busy = true
        defer { busy = false }
        let enteredPIN = pin
        do {
            pinCleared = try await NFCCard.run(success: "Backup erased.") { connection in
                let current = try await connection.select()
                if current.pinBlocked { throw NFCCardError.pinBlocked }
                if !current.pinSet { throw NFCCardError.noPIN }
                if !current.hasBackup { throw NFCCardError.noBackup }
                try await connection.verifyPIN(enteredPIN)
                try await connection.wipe()
                // Cards loaded with older software keep their PIN. The erase has already worked,
                // so a card pulled away here only costs the wording.
                return (try? await connection.select())?.pinSet == false
            }
            clearSecrets()
            step = .erased
        } catch {
            pin = ""
            show(error)
        }
    }
}

/// A PIN or passphrase entry, shown as typed so a mistake is caught before it costs a PIN try. It
/// never offers to save the value or autofill it. A PIN field only takes digits, up to the PIN's length.
struct NFCCardSecretField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    let isNumeric: Bool

    var body: some View {
        TextField(title, text: $text)
            .keyboardType(isNumeric ? .numberPad : .default)
            .textContentType(nil)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: text) { value in
                guard isNumeric else { return }
                let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(NFCCard.pinLength))
                if digits != value { text = digits }
            }
            .padding()
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct NFCCardNote: View {
    let icon: String
    let tint: Color
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(tint)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(tint.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
#endif
