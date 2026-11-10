import SwiftUI

/// The optional BIP39 passphrase ("25th word") step: Create with a Passphrase, or after the
/// seed-phrase entry (import).
///
/// Three screens rather than one. The old version was a single page of explainer cards with the
/// fields already on it and two buttons at the bottom, which asked someone to decide before it had
/// told them what they were deciding - and most people meeting this screen have never heard of a
/// passphrase. So it opens with the question, on its own, with a way to go and read about it
/// first:
///
///   1. `question` - "Did you create these words with a passphrase?" (import only: creating opens on
///      the entry screen). Yes / No / What is a passphrase?
///   2. `entry` - the field, with the chatting address it produces and that address's balance
///      updating underneath as you type. That live address is the point: it is the only direct
///      evidence that a passphrase opens a DIFFERENT account rather than protecting the same one,
///      and a balance is how someone importing can tell they typed the right one.
///   3. `found` - import with no passphrase: the wallet these words were found in.
///   4. `explainer` - plain-language, back only, so reading about it always returns to the screen
///      it was opened from (the question, or the entry screen, which links it too).
///
/// The caller (`CreateWalletView` / `ImportWalletView`) performs the actual wallet commit via
/// `onProceed`, which receives the chosen passphrase ("" when there is none).
struct PassphraseOptionView: View {
    enum Mode {
        case create
        case importExisting
    }

    private enum Step {
        case question
        case entry
        case found
        case explainer
    }

    let mode: Mode
    /// The words behind this flow, for the live address preview on the entry screen. Empty is
    /// tolerated - the preview simply does not appear.
    var seedWords: [String] = []
    /// Set on import: the preview searches every wallet type for these words and writes the
    /// choice here.
    var importChoice: Binding<ImportAccountChoice>?
    /// Performs the create/import commit with the chosen passphrase ("" = none). Throwing surfaces
    /// an inline error here and re-enables the buttons; on success the app router swaps onboarding
    /// for the main app, so this view is torn down automatically.
    let onProceed: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var step: Step
    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var reveal = false
    @State private var isBusy = false
    @State private var error: String?
    /// The import's search for the address holding funds is running: Import waits for it, or it
    /// would import onto #0 while the funds sit on another address.
    @State private var isSearchingAddresses = false
    /// Where the explainer's Back returns: the question (import) or the entry screen.
    @State private var explainerReturnStep: Step = .question

    init(
        mode: Mode,
        seedWords: [String] = [],
        importChoice: Binding<ImportAccountChoice>? = nil,
        onProceed: @escaping (String) async throws -> Void
    ) {
        self.mode = mode
        self.seedWords = seedWords
        self.importChoice = importChoice
        self.onProceed = onProceed
        // Creating only reaches here through "Advanced: Create with a Passphrase", which has
        // already answered the question.
        _step = State(initialValue: mode == .create ? .entry : .question)
    }

    var body: some View {
        Group {
            switch step {
            case .question: questionScreen
            case .entry: entryScreen
            case .found: foundScreen
            case .explainer: explainerScreen
            }
        }
        .interactiveDismissDisabled(isBusy)
        .alert("Error", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            if let error { Text(error) }
        }
    }

    // MARK: - 1. The question

    private var questionTitle: String {
        "Did you create these words with a passphrase?"
    }

    private var questionScreen: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            Image(systemName: "lock.shield.fill")
                .font(.scaled(size: 56))
                .foregroundColor(.accentColor)

            Text(questionTitle)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // Import keeps a line of steer, because someone who has never heard of a passphrase
            // still has to answer a question about their own past. Create needs none: the choice
            // is theirs to make, and "What is a passphrase?" is right there if they want it.
            if mode == .importExisting {
                Text("If you are not sure, the answer is almost certainly no. A passphrase is something you would have typed in on purpose.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                Button {
                    step = .entry
                } label: {
                    Text("Yes")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(isBusy)

                Button {
                    // Held from here, not only once the search starts: Import must not be
                    // tappable before the search has run.
                    isSearchingAddresses = true
                    step = .found
                } label: {
                    Text("No")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundColor(.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(isBusy)

                Button {
                    explainerReturnStep = .question
                    step = .explainer
                } label: {
                    Text("What is a passphrase?")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
            }
        }
        .padding(24)
        .navigationTitle("Passphrase")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isBusy)
    }

    // MARK: - 2. Entry, with the address it produces

    private var entryScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(mode == .create ? "Choose your passphrase" : "Enter your passphrase")
                    .font(.title3.weight(.bold))

                Text(mode == .create
                     ? "Write it down somewhere safe. Without it this account cannot be recovered, even with your 12 or 24 words."
                     : "It has to be exactly what you used before, including capital letters and spaces.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                passphraseFields
                    // Nothing changes the account once it is being made.
                    .disabled(isBusy)

                PassphraseAddressPreview(
                    words: seedWords,
                    passphrase: passphrase,
                    family: .kaspaStandard,
                    showsFundsHint: mode == .importExisting,
                    selection: importChoice,
                    isSearching: importChoice == nil ? nil : $isSearchingAddresses
                )
                .disabled(isBusy)

                primaryButton(
                    title: mode == .create ? "Continue" : "Import",
                    searching: isSearchingAddresses && !passphrase.isEmpty,
                    enabled: canSubmitPassphrase
                ) {
                    submitFromEntry()
                }

                // The search is a network round trip: never the only way forward.
                if mode == .importExisting, isSearchingAddresses, !passphrase.isEmpty, !isBusy {
                    skipSearchButton { submitFromEntry(skippingSearch: true) }
                }

                Button {
                    explainerReturnStep = .entry
                    step = .explainer
                } label: {
                    Text("What is a passphrase?")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .disabled(isBusy)
            }
            .padding(24)
        }
        .navigationTitle("Passphrase")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Back") {
                    passphrase = ""
                    confirmPassphrase = ""
                    if mode == .create {
                        dismiss()
                    } else {
                        step = .question
                    }
                }
                .disabled(isBusy)
            }
        }
    }

    // MARK: - 3. Found (import, no passphrase)

    private var foundScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Your Account")
                    .font(.title3.weight(.bold))

                Text("KaPay checks your words against every kind of Kaspa wallet, so you don't need to know which one they came from.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                PassphraseAddressPreview(
                    words: seedWords,
                    passphrase: "",
                    family: .kaspaStandard,
                    showsFundsHint: true,
                    selection: importChoice,
                    isSearching: $isSearchingAddresses
                )
                .disabled(isBusy)

                primaryButton(title: "Import", searching: isSearchingAddresses, enabled: !isSearchingAddresses) {
                    submit(passphrase: "")
                }

                if isSearchingAddresses, !isBusy {
                    skipSearchButton {
                        importChoice?.wrappedValue = ImportAccountChoice()
                        submit(passphrase: "")
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Import Account")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Back") { step = .question }
                    .disabled(isBusy)
            }
        }
    }

    private func primaryButton(
        title: LocalizedStringKey,
        searching: Bool,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView().tint(.white)
                } else if searching {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("Finding your address...")
                            .font(.headline)
                    }
                } else {
                    Text(title)
                        .font(.headline)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(enabled ? Color.accentColor : Color.gray)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(!enabled || isBusy)
    }

    private func skipSearchButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Skip the Search: Import on Address #0")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
    }

    private var passphraseFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Group {
                    if reveal {
                        TextField("Passphrase", text: $passphrase)
                    } else {
                        SecureField("Passphrase", text: $passphrase)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Button {
                    reveal.toggle()
                } label: {
                    Image(systemName: reveal ? "eye.slash" : "eye")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if mode == .create {
                Group {
                    if reveal {
                        TextField("Re-enter passphrase", text: $confirmPassphrase)
                    } else {
                        SecureField("Re-enter passphrase", text: $confirmPassphrase)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding()
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - 4. What is a passphrase?

    private var explainerScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                explainerSection(
                    "The short version",
                    "A passphrase is an extra word or sentence you add on top of your 12 or 24 words. It is optional, and most people do not use one."
                )
                explainerSection(
                    "It does not lock your account",
                    "This is the part people get wrong. A passphrase does not put a password on your account. It opens a completely different account. Your 12 or 24 words with no passphrase open one account. The same words with the word \"apple\" opens another one. With \"banana\", another one again. Every passphrase is its own separate account, with its own address and its own balance."
                )
                explainerSection(
                    "Why anyone bothers",
                    "If someone finds your written 12 or 24 words, they get the account those words open on their own. They do not get the one behind your passphrase, because they do not know there is one, and they could not guess it anyway."
                )
                explainerSection(
                    "The catch",
                    "There is no reset and no recovery. If you forget your passphrase, the account it opened is gone for good. Your 12 or 24 words alone will not bring it back, and nobody can help you. Treat it exactly like the words themselves: written down, somewhere safe, before you rely on it."
                )
                explainerSection(
                    "One more thing to know",
                    "If you type the wrong passphrase, nothing will tell you. You will simply land in a different account, and it will look empty. That is not a bug and your money is not lost - it just means you are in the wrong account."
                )
                explainerSection(
                    "So do you need one?",
                    mode == .create
                        ? "If you are not sure, you do not need one: go back to the start and tap Create New Account, which makes an account without a passphrase. It is still protected by your 12 or 24 words, and you can always create another account with a passphrase later."
                        : "If you never set one up, choose No. A passphrase is something you would have typed in on purpose, so if this is the first you are hearing of it, you do not have one."
                )
            }
            .padding(24)
        }
        .navigationTitle("What is a passphrase?")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Back") { step = explainerReturnStep }
            }
        }
    }

    private func explainerSection(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(body)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private var canSubmitPassphrase: Bool {
        !passphrase.isEmpty && !isSearchingAddresses
    }

    /// - Parameter skippingSearch: Import on address #0 without waiting for the funds search.
    private func submitFromEntry(skippingSearch: Bool = false) {
        guard skippingSearch || !isSearchingAddresses else { return }
        guard !passphrase.isEmpty else {
            error = "Enter a passphrase, or go back and choose No."
            return
        }
        if mode == .create, passphrase != confirmPassphrase {
            error = "The passphrases do not match. Please re-enter them."
            return
        }
        if skippingSearch { importChoice?.wrappedValue = ImportAccountChoice() }
        submit(passphrase: passphrase)
    }

    private func submit(passphrase chosen: String) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            do {
                try await onProceed(chosen)
                // Success: the router replaces onboarding with the main app; nothing more to do.
            } catch {
                self.error = error.localizedDescription
                isBusy = false
            }
        }
    }
}

#Preview {
    NavigationStack {
        PassphraseOptionView(mode: .create) { _ in }
            .environmentObject(WalletManager.shared)
    }
}

/// The whole reason this screen shows an address: a passphrase does not protect one account,
/// it opens a different one. Watching #0 change with every character is what makes that
/// concrete, and on import it is how someone confirms they typed the right thing before
/// committing to an account that would otherwise look simply empty.
struct PassphraseAddressPreview: View {
    @EnvironmentObject private var walletManager: WalletManager

    let words: [String]
    let passphrase: String
    var chattingIndex: UInt32 = 0
    let family: WalletSourceFamily
    let showsFundsHint: Bool
    /// Set when the account isn't known yet: the preview searches every wallet type, picks the
    /// likeliest account, and lets the user pick another.
    var selection: Binding<ImportAccountChoice>?
    /// True while that search runs, so the caller can hold its Import until the pick is made.
    var isSearching: Binding<Bool>?

    /// How long Import waits for that search before letting go and importing onto #0.
    private static let searchTimeoutNanoseconds: UInt64 = 12_000_000_000

    /// What the search found, likeliest first.
    @State private var foundAddresses: [ImportAccountCandidate] = []
    /// Address #0 of every wallet type, for words the search can't place.
    @State private var everyWalletType: [ImportAccountCandidate] = []
    @State private var showsEveryWalletType = false
    @State private var previewHasHistory = false
    @State private var previewAddress: String?
    @State private var previewTask: Task<Void, Never>?
    /// What `previewAddress` holds: nil while looking it up, or when the lookup failed.
    @State private var previewBalanceSompi: UInt64?
    @State private var previewBalanceFailed = false
    /// The running search, so a late answer to an abandoned one is ignored.
    @State private var searchToken: UUID?
    @State private var searchTimeoutTask: Task<Void, Never>?
    /// The funds search failed or ran out of time: Import goes to #0, and the screen says so.
    @State private var searchIncomplete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your chatting address")
                .font(.caption)
                .foregroundColor(.secondary)
            // Every character, wrapped over as many lines as it takes. This is the one place the
            // address has to be readable in full: truncating it would hide exactly the part that
            // changes when the passphrase does, which is the whole reason it is on screen.
            Text(previewAddress ?? "Checking...")
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(previewAddress == nil ? .secondary : .primary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .animation(.none, value: previewAddress)
            previewBalanceRow
            if foundAddresses.count > 1 || showsEveryWalletType {
                foundAddressRows
            }
            if selection != nil, isSearching?.wrappedValue != true, !everyWalletType.isEmpty, !showsEveryWalletType {
                Button("See Every Wallet Type") { showsEveryWalletType = true }
                    .font(.caption.weight(.semibold))
                    .padding(.top, 4)
            }
            if searchIncomplete {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The search for funds on this account's other addresses didn't finish, so Import uses address #0.")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Search Again") { schedulePreview(for: passphrase) }
                        .font(.caption.weight(.semibold))
                }
                .padding(.top, 4)
            }
            Text(passphrase.isEmpty
                 ? "This is the account your 12 or 24 words open on their own."
                 : "A different passphrase gives a different address, and a different account.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .opacity(words.isEmpty ? 0 : 1)
        // The new value, not `passphrase`: this view holds a plain copy, and the closure still
        // sees the copy from before the change.
        .onChange(of: passphrase) { schedulePreview(for: $0) }
        .onAppear { schedulePreview(for: passphrase) }
        .onDisappear {
            previewTask?.cancel()
            searchTimeoutTask?.cancel()
            searchToken = nil
            isSearching?.wrappedValue = false
        }
    }

    /// The balance is only the chatting address's: funds can also sit on the account's other
    /// addresses, so an empty one suggests a wrong passphrase rather than proving it.
    @ViewBuilder
    private var previewBalanceRow: some View {
        HStack(spacing: 6) {
            Text("Balance")
                .font(.caption)
                .foregroundColor(.secondary)
            if let previewBalanceSompi {
                Text(verbatim: KaspaUnit.amount(previewBalanceSompi))
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(previewBalanceSompi > 0 ? .green : .primary)
            } else if previewBalanceFailed {
                Text("Couldn't check")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(height: 14)
            }
        }
        .padding(.top, 4)
        if showsFundsHint, let previewBalanceSompi {
            fundsHint(balance: previewBalanceSompi)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func fundsHint(balance: UInt64) -> some View {
        if balance > 0 {
            Text("This address holds funds, so this looks like the right account.")
                .foregroundColor(.green)
        } else if previewHasHistory {
            Text("This address has history, so this looks like the right account.")
                .foregroundColor(.green)
        } else if passphrase.isEmpty {
            Text("No funds or history on this address.")
                .foregroundColor(.secondary)
        } else {
            Text("No funds on this address. If you expected funds here, check your passphrase.")
                .foregroundColor(.orange)
        }
    }

    private var visibleAddressRows: [ImportAccountCandidate] {
        guard showsEveryWalletType else { return foundAddresses }
        let foundIDs = Set(foundAddresses.map(\.id))
        return foundAddresses + everyWalletType.filter { !foundIDs.contains($0.id) }
    }

    private var foundAddressRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("We picked the most likely account. Tap another if that's not the one you use.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(visibleAddressRows) { found in
                Button {
                    select(found)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: selection?.wrappedValue == found.choice ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: found.family.displayName)
                                .font(.caption.weight(.semibold))
                            Text("Address #\(found.index)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(verbatim: "\(found.address.prefix(14))...\(found.address.suffix(6))")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if found.balanceSompi > 0 {
                            Text(verbatim: KaspaUnit.amount(found.balanceSompi))
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.green)
                        } else if found.hasHistory {
                            Text("Has history")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }

    private func select(_ found: ImportAccountCandidate) {
        selection?.wrappedValue = found.choice
        previewAddress = found.address
        previewBalanceSompi = found.balanceSompi
        previewHasHistory = found.hasHistory
    }

    private func schedulePreview(for typed: String) {
        previewTask?.cancel()
        searchTimeoutTask?.cancel()
        searchToken = nil
        searchIncomplete = false
        guard !words.isEmpty else {
            isSearching?.wrappedValue = false
            return
        }
        previewBalanceSompi = nil
        previewBalanceFailed = false
        previewHasHistory = false
        foundAddresses = []
        everyWalletType = []
        showsEveryWalletType = false
        selection?.wrappedValue = ImportAccountChoice()
        // Held from the first keystroke, not only once the lookup starts: an Import tapped in
        // the pause would otherwise go to #0.
        isSearching?.wrappedValue = selection != nil
        previewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let address = walletManager.previewChattingAddress(
                words: words,
                passphrase: typed,
                chattingIndex: chattingIndex,
                family: family
            )
            previewAddress = address
            guard let address else {
                previewBalanceFailed = true
                isSearching?.wrappedValue = false
                return
            }
            // a further pause, so only the passphrase someone stopped typing is looked up
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            if selection != nil {
                everyWalletType = walletManager.importAddressesAtZero(words: words, passphrase: typed)
                // A slow or unreachable node lets Import go after the timeout, onto #0, and says
                // so; an answer that comes later is ignored.
                let token = UUID()
                searchToken = token
                let timeout = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: Self.searchTimeoutNanoseconds)
                    guard !Task.isCancelled, searchToken == token else { return }
                    searchToken = nil
                    searchIncomplete = true
                    previewBalanceFailed = true
                    isSearching?.wrappedValue = false
                    // a node-less search falls back to one REST call per address: stop those
                    previewTask?.cancel()
                }
                searchTimeoutTask = timeout
                let found = await walletManager.findImportAccounts(words: words, passphrase: typed)
                timeout.cancel()
                guard !Task.isCancelled, searchToken == token else { return }
                searchToken = nil
                isSearching?.wrappedValue = false
                guard let found else {
                    searchIncomplete = true
                    previewBalanceFailed = true
                    return
                }
                foundAddresses = found
                if let first = found.first {
                    select(first)
                } else {
                    previewBalanceSompi = 0
                }
                return
            }
            let utxos = try? await NodePoolService.shared.getUtxosByAddresses([address])
            guard !Task.isCancelled else { return }
            if let utxos {
                previewBalanceSompi = utxos.reduce(UInt64(0)) { $0 + $1.amount }
            } else {
                previewBalanceFailed = true
            }
        }
    }
}
