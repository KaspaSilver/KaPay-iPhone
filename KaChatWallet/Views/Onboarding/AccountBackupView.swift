import SwiftUI
import UIKit

/// The Wallet tab's card above Manage Addresses while an account isn't backed up. It stays until
/// the backup steps are finished, and turns red once the account holds funds.
struct AccountBackupCard: View {
    let hasFunds: Bool
    let action: () -> Void

    private var tint: Color { hasFunds ? .red : .orange }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.scaled(size: 22, weight: .medium))
                    .foregroundColor(tint)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(tint.opacity(0.15)))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Backup Your Account To Prevent Loss Of Funds")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                    Text(hasFunds
                         ? "You now have funds that aren't backed up."
                         : "If you lose this phone, your seed phrase is the only way back.")
                        .font(.caption)
                        .foregroundColor(hasFunds ? .red : .secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(tint.opacity(0.1))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(tint.opacity(0.5), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }
}

/// Backing up an account's seed phrase and passphrase, in plain steps: why, getting ready, the
/// words a few at a time, proving they were written down, then where to keep them. Words are
/// written by hand: this flow never offers a copy (Settings > View Seed Phrase does).
struct AccountBackupView: View {
    private enum Step: Int, CaseIterable {
        case why, prepare, words, wordCheck, passphrase, passphraseCheck, tips
    }

    private static let wordsPerPage = 6
    private static let wordsToCheck = 4

    /// Opens the steps behind the seed phrase's biometric gate, when enabled.
    static func unlock(_ show: @escaping () -> Void) {
        if AppSettings.load().biometricSeedPhraseEnabled {
            DeviceAuth.authenticate(reason: "Unlock to view your seed phrase", onSuccess: show)
        } else {
            show()
        }
    }

    @EnvironmentObject private var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .why
    @State private var seedPhrase: SeedPhrase?
    @State private var loadFailed = false
    @State private var hasPenAndPaper = false
    @State private var isPrivate = false
    @State private var noPhotos = false
    @State private var wordPage = 0
    @State private var checkIndexes: [Int] = []
    @State private var answers: [Int: String] = [:]
    @State private var wrongIndexes: Set<Int> = []
    @State private var passphraseAnswer = ""
    @State private var revealPassphraseAnswer = false
    @State private var passphraseWrong = false
    @State private var showScreenshotWarning = false

    private var words: [String] { seedPhrase?.words ?? [] }
    private var passphrase: String? {
        guard let passphrase = seedPhrase?.passphrase, !passphrase.isEmpty else { return nil }
        return passphrase
    }
    private var pageCount: Int { max(1, (words.count + Self.wordsPerPage - 1) / Self.wordsPerPage) }

    /// This account's steps, for the progress bar: the passphrase's only when it has one.
    private var steps: [Step] {
        Step.allCases.filter { passphrase != nil || ($0 != .passphrase && $0 != .passphraseCheck) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if seedPhrase != nil {
                    stepContent
                } else if loadFailed {
                    Text("This account's seed phrase isn't available on this phone.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Back Up Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if seedPhrase != nil, step != .why {
                        Button("Back") { goBack() }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled()
        .task { load() }
        // iOS can't stop a screenshot, only say so afterwards.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            if step == .words || step == .passphrase { showScreenshotWarning = true }
        }
        .alert("Delete That Screenshot", isPresented: $showScreenshotWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("A screenshot of your seed phrase can end up online. Delete it from your photos and write the words on paper instead.")
        }
    }

    private func load() {
        guard seedPhrase == nil else { return }
        if let loaded = try? walletManager.getSeedPhrase() {
            seedPhrase = loaded
        } else {
            loadFailed = true
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .why: whyStep
        case .prepare: prepareStep
        case .words: wordsStep
        case .wordCheck: wordCheckStep
        case .passphrase: passphraseStep
        case .passphraseCheck: passphraseCheckStep
        case .tips: tipsStep
        }
    }

    /// One step's page: progress on top, the content scrolling, its button always in reach.
    private func screen<Content: View>(
        buttonTitle: LocalizedStringKey,
        buttonEnabled: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ProgressView(
                    value: Double((steps.firstIndex(of: step) ?? 0) + 1),
                    total: Double(steps.count)
                )
                content()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            CreateWalletNextButton(title: buttonTitle, enabled: buttonEnabled, action: action)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
        }
    }

    private func heading(_ title: LocalizedStringKey, _ detail: LocalizedStringKey? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func point(_ icon: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.scaled(size: 20, weight: .medium))
                .foregroundColor(.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func checkbox(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.subheadline)
        }
        .toggleStyle(CheckboxToggleStyle())
    }

    // MARK: - Why

    private var whyStep: some View {
        screen(buttonTitle: "Start Backup", action: { go(to: .prepare) }) {
            heading("Protect your funds")
            point("key.fill", "Your seed phrase is your account",
                  "These secret words are created just for you. They are the master key to your funds.")
            point("iphone.slash", "Your phone can't be your only copy",
                  "If you lose, break or replace this phone, these words are the only way back to your account.")
            point("person.fill.xmark", "Nobody can reset them",
                  "There is no password reset. KaPay never sees your words, so we can't recover them for you.")
            NavigationLink {
                SeedPhraseExplainerPage()
            } label: {
                Label("What is a seed phrase?", systemImage: "questionmark.circle")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    // MARK: - Getting ready

    private var prepareStep: some View {
        screen(
            buttonTitle: "Show My Seed Phrase",
            buttonEnabled: hasPenAndPaper && isPrivate && noPhotos,
            action: { wordPage = 0; go(to: .words) }
        ) {
            heading("Get ready", "Your secret words are next. Before you see them:")
            checkbox("I have a pen and paper", isOn: $hasPenAndPaper)
            checkbox("Nobody can see my screen", isOn: $isPrivate)
            checkbox("I won't take a photo or screenshot", isOn: $noPhotos)
        }
    }

    // MARK: - The words

    private var pageRange: Range<Int> {
        let start = wordPage * Self.wordsPerPage
        return start..<min(start + Self.wordsPerPage, words.count)
    }

    private var wordsStep: some View {
        screen(
            buttonTitle: wordPage + 1 < pageCount ? "Next Words" : "I Wrote Them Down",
            action: {
                if wordPage + 1 < pageCount {
                    wordPage += 1
                } else {
                    startWordCheck()
                }
            }
        ) {
            heading("Write down these words", "Write them on paper in this exact order, with their numbers.")
            Text("Words \(pageRange.lowerBound + 1) to \(pageRange.upperBound) of \(words.count)")
                .font(.footnote.weight(.semibold))
                .foregroundColor(.accentColor)
            SecureView {
                VStack(spacing: 8) {
                    ForEach(Array(pageRange), id: \.self) { index in
                        HStack(spacing: 14) {
                            Text(verbatim: "\(index + 1).")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .frame(width: 32, alignment: .trailing)
                            Text(verbatim: words[index])
                                .font(.system(.title3, design: .monospaced).weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 14)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }

    // MARK: - Word check

    private func startWordCheck() {
        checkIndexes = Array(words.indices.shuffled().prefix(Self.wordsToCheck)).sorted()
        answers = [:]
        wrongIndexes = []
        go(to: .wordCheck)
    }

    private func normalized(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func checkWords() {
        wrongIndexes = Set(checkIndexes.filter { normalized(answers[$0] ?? "") != words[$0] })
        guard wrongIndexes.isEmpty else {
            Haptics.error()
            return
        }
        go(to: passphrase != nil ? .passphrase : .tips)
    }

    private var wordCheckStep: some View {
        screen(
            buttonTitle: "Check My Words",
            buttonEnabled: checkIndexes.allSatisfy { !normalized(answers[$0] ?? "").isEmpty },
            action: checkWords
        ) {
            heading("Check your paper", "Enter these words from what you wrote down, to be sure your copy is right.")
            ForEach(checkIndexes, id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Word \(index + 1)")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.secondary)
                    TextField("", text: Binding(
                        get: { answers[index] ?? "" },
                        set: { answers[index] = $0; wrongIndexes.remove(index) }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .padding(12)
                    .background(Color(.systemGray6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(wrongIndexes.contains(index) ? Color.red : Color.clear, lineWidth: 1.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            if !wrongIndexes.isEmpty {
                Text("That doesn't match. Check your paper, or go back to see the words again.")
                    .font(.footnote)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("See My Words Again") {
                    wordPage = 0
                    go(to: .words)
                }
                .font(.subheadline.weight(.semibold))
            }
        }
    }

    // MARK: - Passphrase

    private var passphraseStep: some View {
        screen(buttonTitle: "I Wrote It Down", action: { passphraseAnswer = ""; passphraseWrong = false; go(to: .passphraseCheck) }) {
            heading("Write down your passphrase",
                    "This account also needs its passphrase. Your seed phrase alone won't bring it back. Write it exactly, including capital letters and spaces.")
            SecureView {
                Text(verbatim: passphrase ?? "")
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func checkPassphrase() {
        guard passphraseAnswer == passphrase else {
            passphraseWrong = true
            Haptics.error()
            return
        }
        go(to: .tips)
    }

    private var passphraseCheckStep: some View {
        screen(buttonTitle: "Check My Passphrase", buttonEnabled: !passphraseAnswer.isEmpty, action: checkPassphrase) {
            heading("Check your passphrase", "Enter it from what you wrote down. It has to match exactly.")
            HStack {
                Group {
                    if revealPassphraseAnswer {
                        TextField("Passphrase", text: $passphraseAnswer)
                    } else {
                        SecureField("Passphrase", text: $passphraseAnswer)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                Button {
                    revealPassphraseAnswer.toggle()
                } label: {
                    Image(systemName: revealPassphraseAnswer ? "eye.slash" : "eye")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .onChange(of: passphraseAnswer) { _ in passphraseWrong = false }
            if passphraseWrong {
                Text("That doesn't match. Check your paper, or go back to see it again.")
                    .font(.footnote)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Where to keep it

    private var tipsStep: some View {
        screen(buttonTitle: "Finish Backup", action: finish) {
            heading("Keep it safe", "Your copy is right. Now keep it that way.")
            point("doc.text.fill", "Keep it on paper",
                  "Store it somewhere safe and private, away from fire and water.")
            point("icloud.slash.fill", "Never keep it online",
                  "No photos, screenshots, cloud storage, notes apps, email or chats.")
            point("hand.raised.fill", "Never share it",
                  "Nobody needs your words. KaPay and real support will never ask for them. Anyone who asks is trying to take your funds.")
            if passphrase != nil {
                point("square.split.2x1.fill", "Keep your passphrase apart",
                      "Store it away from your seed phrase. You need both, and losing either one loses the account.")
            }
            point("gearshape.fill", "You can see it again",
                  "Your seed phrase stays available in Settings > View Seed Phrase.")
        }
    }

    private func finish() {
        if let address = walletManager.currentWallet?.publicAddress {
            AccountBackupStatus.shared.markConfirmed(address)
        }
        Haptics.success()
        dismiss()
    }

    // MARK: - Moving between steps

    private func go(to next: Step) {
        dismissSystemKeyboard()
        step = next
    }

    private func goBack() {
        switch step {
        case .why: break
        case .prepare: go(to: .why)
        case .words:
            if wordPage > 0 {
                wordPage -= 1
            } else {
                go(to: .prepare)
            }
        case .wordCheck:
            wordPage = pageCount - 1
            go(to: .words)
        case .passphrase: startWordCheck()
        case .passphraseCheck: go(to: .passphrase)
        case .tips:
            if passphrase != nil {
                passphraseAnswer = ""
                go(to: .passphraseCheck)
            } else {
                startWordCheck()
            }
        }
    }
}

/// The Wallet tab's card above Manage Addresses every six months after a finished backup.
struct BackupHygieneCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.scaled(size: 22, weight: .medium))
                    .foregroundColor(.accentColor)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))
                Text("Backup Hygiene")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.accentColor.opacity(0.1))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.accentColor.opacity(0.5), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }
}

/// Checks the written backup still works: five words of the seed phrase, asked in random order on
/// the app's own keyboard, then the passphrase if the account has one, since the words alone
/// wouldn't bring it back. Can't Complete This goes through the backup steps again. Either one
/// starts the six months over; closing leaves the card up.
struct BackupHygieneView: View {
    private static let wordsToCheck = 5

    @EnvironmentObject private var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss

    @State private var seedWords: [String] = []
    /// Which words are asked (positions in the phrase), in the order they're asked.
    @State private var asked: [Int] = []
    @State private var answers: [String] = []
    @State private var wrong = false
    /// This account's passphrase, when it has one.
    @State private var passphrase: String?
    @State private var checkingPassphrase = false
    @State private var passphraseAnswer = ""
    @State private var revealPassphraseAnswer = false
    @State private var passed = false
    @State private var redoingBackup = false

    private var allFilled: Bool {
        !asked.isEmpty && answers.allSatisfy { BIP39.shared.isValidWord($0) }
    }

    var body: some View {
        if redoingBackup {
            AccountBackupView()
        } else {
            NavigationStack {
                Group {
                    if passed {
                        passedScreen
                    } else if checkingPassphrase {
                        passphraseScreen
                    } else {
                        checkScreen
                    }
                }
                .navigationTitle("Backup Hygiene")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Close") { dismiss() }
                    }
                }
            }
            .interactiveDismissDisabled()
            .task { load() }
        }
    }

    private var checkScreen: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Let's ensure your account is backed up in case you lose access to your phone.")
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Enter these \(asked.count) words from your seed phrase. Each box shows the word's number.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SeedPhraseKeyboardView(
                words: $answers,
                wordCount: asked.count,
                slotNumbers: asked.map { $0 + 1 }
            )
            .onChange(of: answers) { _ in wrong = false }

            if wrong {
                Text("Some of those words don't match. Check your paper and try again.")
                    .font(.footnote)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            CreateWalletNextButton(title: "Check My Words", enabled: allFilled, action: check)

            cantCompleteButton
        }
        .padding()
    }

    private var passphraseScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Now enter your passphrase")
                    .font(.subheadline.weight(.semibold))
                Text("Your seed phrase alone won't bring this account back. Enter the passphrase from what you wrote down, exactly, including capital letters and spaces.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Group {
                        if revealPassphraseAnswer {
                            TextField("Passphrase", text: $passphraseAnswer)
                        } else {
                            SecureField("Passphrase", text: $passphraseAnswer)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    Button {
                        revealPassphraseAnswer.toggle()
                    } label: {
                        Image(systemName: revealPassphraseAnswer ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .onChange(of: passphraseAnswer) { _ in wrong = false }

                if wrong {
                    Text("That doesn't match. Check your paper and try again.")
                        .font(.footnote)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                CreateWalletNextButton(title: "Check My Passphrase", enabled: !passphraseAnswer.isEmpty, action: checkPassphrase)

                cantCompleteButton
            }
            .padding()
        }
    }

    private var cantCompleteButton: some View {
        Button {
            AccountBackupView.unlock { redoingBackup = true }
        } label: {
            Text("Can't Complete This")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
    }

    private var passedScreen: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.shield.fill")
                .font(.scaled(size: 56))
                .foregroundColor(.accentColor)
            Text("Your backup is good")
                .font(.title2.weight(.bold))
            Text("We'll check again in 6 months.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
            CreateWalletNextButton(title: "Done", enabled: true) { dismiss() }
        }
        .padding(20)
    }

    private func load() {
        guard asked.isEmpty, let seedPhrase = try? walletManager.getSeedPhrase(), !seedPhrase.words.isEmpty else { return }
        let words = seedPhrase.words
        seedWords = words
        passphrase = seedPhrase.passphrase.flatMap { $0.isEmpty ? nil : $0 }
        asked = Array(words.indices.shuffled().prefix(Self.wordsToCheck))
        answers = Array(repeating: "", count: asked.count)
    }

    private func check() {
        guard zip(asked, answers).allSatisfy({ seedWords[$0] == $1.lowercased() }) else {
            wrong = true
            Haptics.error()
            return
        }
        wrong = false
        if passphrase != nil {
            checkingPassphrase = true
        } else {
            finish()
        }
    }

    private func checkPassphrase() {
        guard passphraseAnswer == passphrase else {
            wrong = true
            Haptics.error()
            return
        }
        finish()
    }

    private func finish() {
        if let address = walletManager.currentWallet?.publicAddress {
            AccountBackupStatus.shared.markConfirmed(address)
        }
        Haptics.success()
        passed = true
    }
}
