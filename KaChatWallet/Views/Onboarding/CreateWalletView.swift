import SwiftUI

/// Create New Account's advanced path, for someone who wants a passphrase: a new 24-word seed,
/// then `PassphraseOptionView`, which commits the account. The sign-in screen's Create New Account
/// makes one with no passphrase in a tap. The seed phrase isn't shown here either: the Wallet tab's
/// card leads to the backup steps (`AccountBackupView`).
struct CreateWalletView: View {
    @EnvironmentObject private var walletManager: WalletManager
    @State private var seedPhrase: SeedPhrase?
    @State private var error: String?

    var body: some View {
        Group {
            if let seedPhrase {
                PassphraseOptionView(mode: .create, seedWords: seedPhrase.words) { passphrase in
                    _ = try await walletManager.commitCreatedWallet(
                        seedPhrase: seedPhrase,
                        passphrase: passphrase,
                        alias: walletManager.nextDefaultAccountName()
                    )
                }
            } else if let error {
                Text(error)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
            } else {
                ProgressView()
            }
        }
        .task {
            guard seedPhrase == nil else { return }
            do {
                seedPhrase = try await walletManager.generateNewWalletSeedPhrase(wordCount: 24)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// The account name step of Import Account: a name local to this device.
/// Next stays off until there is a name.
struct AccountNameForm: View {
    @Binding var alias: String
    let onNext: () -> Void
    @FocusState private var nameFocused: Bool

    private var hasName: Bool { !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Create a name for your wallet")
                        .font(.title2.weight(.bold))
                    Text("This name is only stored on this device, to tell your wallets apart. No one else will ever see it.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                TextField("Enter account name", text: $alias)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .submitLabel(.next)
                    .onSubmit { next() }

                CreateWalletNextButton(title: "Next", enabled: hasName) { next() }
            }
            .padding()
        }
        .onAppear { nameFocused = true }
    }

    private func next() {
        guard hasName else { return }
        nameFocused = false
        onNext()
    }
}

/// One of Import Account's two seed lengths (12 or 24 words): a full-width button, filled when
/// chosen and outlined otherwise.
struct SeedLengthButton: View {
    let count: Int
    let title: LocalizedStringKey
    @Binding var selection: Int?
    var disabled = false

    var body: some View {
        let chosen = selection == count
        Button {
            selection = count
        } label: {
            HStack {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                Text(title)
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding()
            .background(chosen ? Color.accentColor : Color.clear)
            .foregroundColor(chosen ? .white : .accentColor)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 1.5))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            // the whole card is the button: an unchosen one's clear background isn't hit-testable
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// What a seed phrase is, in plain words: the page behind the backup steps' "What is a seed
/// phrase?". A full page on a plain background, like "What is a passphrase?", so it reads easily.
struct SeedPhraseExplainerPage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("The short version",
                        "A seed phrase is a list of 12 or 24 ordinary words that works as the master key to your account. Your wallet, its addresses and your .kachat names all come from it.")
                section("Anyone with it can take everything",
                        "Anyone who has these words can take everything in your account. If you lose them and lose this device, nobody can get your account back, not even KaPay.")
                section("How to keep it safe",
                        "Write the words on paper, in order, and keep them somewhere safe and private. Never type them into a website, send them in a chat, or keep them in a screenshot or cloud notes.")
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemBackground))
        .navigationTitle("What is a seed phrase?")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(_ title: LocalizedStringKey, _ body: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(body)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The accent-filled continue button of the Import Account and backup steps (dims while disabled).
struct CreateWalletNextButton: View {
    let title: LocalizedStringKey
    let enabled: Bool
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                if busy {
                    ProgressView().tint(.white)
                }
                Text(title)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.accentColor)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            // A custom background doesn't dim on its own when the button is disabled.
            .opacity(enabled || busy ? 1 : 0.4)
        }
        .disabled(!enabled)
    }
}

struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundColor(configuration.isOn ? .accentColor : .secondary)
                    .font(.title3)

                configuration.label
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        CreateWalletView()
            .environmentObject(WalletManager.shared)
    }
}
