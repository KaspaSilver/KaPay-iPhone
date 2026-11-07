#if canImport(CoreNFC) && !targetEnvironment(macCatalyst)
import SwiftUI

/// Import Account > Restore from NFC Card: the PIN and a tap read the backup, then the passphrase,
/// which was never on the card, opens the account. A wrong passphrase needs no second tap, since the
/// backup is in memory.
struct NFCCardRestoreView: View {
    @EnvironmentObject private var walletManager: WalletManager

    @State private var pin = ""
    @State private var passphrase = ""
    @State private var payload: NFCCardBackupPayload?
    @State private var busy = false
    @State private var errorMessage: String?

    private var pinValid: Bool {
        NFCCard.isValidPIN(pin)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if payload == nil {
                    Text("Restore from an NFC card")
                        .font(.title2.weight(.bold))
                    Text("Enter the card's PIN, then tap the card to read your backup.")
                        .foregroundColor(.secondary)
                    NFCCardSecretField(title: "Card PIN", text: $pin, isNumeric: true)
                    NFCCardNote(icon: "exclamationmark.triangle.fill", tint: .orange,
                                text: "After 5 wrong tries the PIN is blocked for good, and this backup can no longer be read.")
                    CreateWalletNextButton(title: "Scan Card", enabled: pinValid && !busy, busy: busy) {
                        Task { @MainActor in await readCard() }
                    }
                } else {
                    Text("Enter your passphrase")
                        .font(.title2.weight(.bold))
                    Text("The backup was read from your card. Your passphrase was never on the card, so enter it exactly as you set it, including capitals and spaces.")
                        .foregroundColor(.secondary)
                    NFCCardSecretField(title: "Passphrase", text: $passphrase, isNumeric: false)
                    if let payload, !passphrase.isEmpty,
                       let family = WalletSourceFamily(rawValue: payload.family),
                       let chattingIndex = UInt32(exactly: payload.chattingAddressIndex) {
                        PassphraseAddressPreview(
                            words: payload.words,
                            passphrase: passphrase,
                            chattingIndex: chattingIndex,
                            family: family,
                            showsFundsHint: true
                        )
                    }
                    CreateWalletNextButton(title: "Restore Account", enabled: !passphrase.isEmpty && !busy, busy: busy) {
                        Task { @MainActor in await restore() }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Import Account")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(busy)
        .alert("NFC Card", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onDisappear {
            pin = ""
            passphrase = ""
            payload = nil
        }
    }

    private func show(_ error: Error) {
        if case NFCCardError.cancelled = error { return }
        errorMessage = error.localizedDescription
    }

    @MainActor
    private func readCard() async {
        guard pinValid else { return }
        busy = true
        defer { busy = false }
        let enteredPIN = pin
        do {
            let backup = try await NFCCard.run(success: "Backup read.") { connection in
                connection.setMessage("Reading. Keep the card still.")
                let current = try await connection.select()
                if current.pinBlocked { throw NFCCardError.pinBlocked }
                if !current.pinSet { throw NFCCardError.noPIN }
                if !current.hasBackup { throw NFCCardError.noBackup }
                try await connection.verifyPIN(enteredPIN)
                return try await connection.readBackup()
            }
            payload = try await Task.detached(priority: .userInitiated) {
                try NFCCardBackupFormat.open(backup, pin: enteredPIN)
            }.value
            pin = ""
        } catch {
            pin = ""
            show(error)
        }
    }

    @MainActor
    private func restore() async {
        guard let payload else { return }
        busy = true
        defer { busy = false }
        let enteredPassphrase = passphrase
        do {
            guard let family = WalletSourceFamily(rawValue: payload.family),
                  let chattingIndex = UInt32(exactly: payload.chattingAddressIndex),
                  let address = walletManager.previewChattingAddress(
                      words: payload.words,
                      passphrase: enteredPassphrase,
                      chattingIndex: chattingIndex,
                      family: family
                  ) else {
                throw NFCCardError.unreadableBackup
            }
            // A wrong passphrase still derives a valid account, just not this one. Compared as an
            // account, not a string: a card saved on mainnet holds a `kaspa:` address, and this
            // phone may be on testnet (or the other way round).
            guard WalletManager.isSameAccount(address, payload.chattingAddress) else { throw NFCCardError.wrongPassphrase }
            try await commitImport(payload, passphrase: enteredPassphrase, family: family)
        } catch {
            show(error)
        }
    }

    @MainActor
    private func commitImport(_ payload: NFCCardBackupPayload, passphrase: String, family: WalletSourceFamily) async throws {
        // An account already saved here keeps the name it has, not the one on the card.
        let savedName = walletManager.savedAccounts
            .first { WalletManager.isSameAccount($0.publicAddress, payload.chattingAddress) }?
            .alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let wallet = try await walletManager.importWallet(
            from: SeedPhrase(words: payload.words, passphrase: passphrase),
            alias: savedName.flatMap { $0.isEmpty ? nil : $0 } ?? payload.alias,
            chattingAddressIndex: payload.chattingAddressIndex,
            family: family
        )
        // Same as typing the words: whoever restored it has the seed.
        AccountBackupStatus.shared.markConfirmed(wallet.publicAddress)
        Task {
            await walletManager.discoverSpendingAddresses()
            await HotWalletBalance.shared.refresh(force: true)
        }
    }
}
#endif
