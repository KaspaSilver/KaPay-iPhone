import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @State private var showCreateWallet = false
    @State private var isCreatingAccount = false
    @State private var createAccountError: String?
    @State private var showImportWallet = false
    @State private var signingInAccountId: String?
    @State private var pendingRemovalAccount: SavedAccountSummary?
    /// The pencil's half sheet: Rename or Delete for one saved account.
    @State private var accountActionsTarget: SavedAccountSummary?
    /// What the half sheet's choice opens, once the half sheet has finished closing: presenting
    /// the next sheet or alert while it is still going away can be dropped.
    @State private var afterAccountActions: (() -> Void)?
    @State private var isRemovingAccount = false
    @State private var signInErrorMessage: String?
    /// A saved account this device has no keys for (tapped after an iPhone restore): the sheet
    /// that says so and leads into Enter Recovery Phrase.
    @State private var accountNeedingKeys: SavedAccountSummary?
    @State private var pendingRenameAccount: SavedAccountSummary?
    @State private var renameText = ""
    @State private var showAppSettings = false

    /// The brand's near-black with a green cast, taken from the KaChat banner rather than the
    /// app's usual true black. Scoped to this screen only, and applied in both appearances on
    /// purpose - it is the sign-in screen, the one place the product introduces itself.
    private static let pageBackground = Color(red: 0.055, green: 0.086, blue: 0.078)
    /// One step up from the page, same cast, for the account rows.
    private static let rowBackground = Color(red: 0.102, green: 0.149, blue: 0.141)

    var body: some View {
        NavigationStack {
            // GeometryReader so the accounts list can be told a height that DEMONSTRABLY leaves
            // room for Create and Import. Sizing it off five rows alone pushed them off the
            // bottom of the screen on a short phone, and nothing here scrolls the page, so they
            // were simply unreachable.
            GeometryReader { proxy in
                VStack(spacing: hasSavedAccounts ? 20 : 40) {
                    Spacer(minLength: 0)
                    titleSection
                    Spacer(minLength: 0)
                    actionButtonsSection(availableHeight: proxy.size.height)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Which build this phone runs, right where sign-in problems get reported from.
                // An overlay inside the buttons' own 40pt bottom padding, so the height budget
                // that keeps Create and Import on screen is untouched.
                .overlay(alignment: .bottom) {
                    Text(verbatim: "KaPay \(AppVersion.display)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 10)
                        .allowsHitTesting(false)
                }
                .background(Self.pageBackground.ignoresSafeArea())
                // The background is dark in both appearances, so the system colors drawn on top
                // of it have to be their dark variants too - otherwise `.primary` text renders
                // black on near-black in light mode. Scoped to this subtree.
                .environment(\.colorScheme, .dark)
            }
            // App-wide settings (Security, Appearance/Language/Currency, Connection,
            // Diagnostics) - reachable with NO account active. Account-tier settings stay in
            // the in-account Settings.
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showAppSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("App Settings")
                }
            }
            .sheet(isPresented: $showAppSettings) {
                AppSettingsView()
            }
            .navigationDestination(isPresented: $showCreateWallet) {
                CreateWalletView()
            }
            .navigationDestination(isPresented: $showImportWallet) {
                // Source-wallet chooser first (KasWare-style): the picked wallet decides the
                // identity derivation path family, then seed entry continues as before.
                ImportSourceWalletView()
            }
            .sheet(item: $accountActionsTarget, onDismiss: {
                let next = afterAccountActions
                afterAccountActions = nil
                next?()
            }) { account in
                accountActionsSheet(account)
            }
            .sheet(isPresented: Binding(
                get: { pendingRemovalAccount != nil },
                set: { if !$0 { pendingRemovalAccount = nil } }
            )) {
                if let account = pendingRemovalAccount {
                    DeleteAccountSheet(
                        confirmSubtitle: "Deletes \(account.displayAlias) (\(account.shortPublicAddress)) and its local data from this device.",
                        notBackedUp: AccountBackupStatus.shared.isPending(account.publicAddress)
                    ) {
                        DeviceAuth.authenticate(reason: AppLocalization.string("Confirm deleting this account")) {
                            removeSavedAccount(account)
                        }
                    }
                }
            }
            .task {
                // Start node pool discovery early so it's ready when wallet is created/imported
                await NodePoolService.shared.startEarlyDiscovery(network: AppSettings.load().networkType)
            }
            .alert(
                "Rename Account",
                isPresented: Binding(
                    get: { pendingRenameAccount != nil },
                    set: { if !$0 { pendingRenameAccount = nil } }
                )
            ) {
                TextField("Account name", text: $renameText)
                Button("Save") {
                    guard let account = pendingRenameAccount else { return }
                    walletManager.renameSavedAccount(account, to: renameText)
                    pendingRenameAccount = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingRenameAccount = nil
                }
            } message: {
                Text("Enter a new name for this saved account.")
            }
            .sheet(item: $accountNeedingKeys) { account in
                AccountKeysNeededSheet(account: account) {
                    accountNeedingKeys = nil
                    // after the sheet's dismissal animation, or the push lands on nothing
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showImportWallet = true
                    }
                }
            }
            // The manager's message too: a sign-in that reached `loadWallet` replaced this screen
            // with the loading screen, so its own state didn't survive to say why it failed.
            .alert(
                "Sign In Failed",
                isPresented: Binding(
                    get: { signInErrorMessage != nil || walletManager.signInFailureMessage != nil },
                    set: {
                        if !$0 {
                            signInErrorMessage = nil
                            walletManager.clearSignInFailure()
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(signInErrorMessage ?? walletManager.signInFailureMessage ?? "Unable to sign in to this account.")
            }
            .alert(
                "Couldn't Create Account",
                isPresented: Binding(
                    get: { createAccountError != nil },
                    set: { if !$0 { createAccountError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(createAccountError ?? "")
            }
        }
    }

    private var hasSavedAccounts: Bool { !walletManager.savedAccounts.isEmpty }

    /// Creating, signing in or removing: one at a time, since each one replaces the account in
    /// the active slot.
    private var isAccountActionRunning: Bool {
        isCreatingAccount || signingInAccountId != nil || isRemovingAccount
    }

    /// Wordmark with the app mark beside it. KaPay's name says what it is, so there is no
    /// tagline under it (owner's call, 2026-10-24).
    private var titleSection: some View {
        HStack(spacing: 10) {
            Text(verbatim: "KaPay")
                .font(.largeTitle.weight(.bold))
            Image("KaChatWalletLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private func actionButtonsSection(availableHeight: CGFloat) -> some View {
        VStack(spacing: 16) {
            if hasSavedAccounts {
                savedAccountsSection(availableHeight: availableHeight)
            }

            Button {
                createAccount()
            } label: {
                HStack {
                    if isCreatingAccount {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "plus.circle.fill")
                    }
                    Text("Create New Account")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.accentColor)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(signingInAccountId != nil || isRemovingAccount)

            Button {
                showImportWallet = true
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.down")
                    Text("Import Existing Account")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.systemGray5))
                .foregroundColor(.primary)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(isAccountActionRunning)

            Button {
                showCreateWallet = true
            } label: {
                Text("Advanced: Create with a Passphrase")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.accentColor)
            }
            .disabled(isAccountActionRunning)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 40)
    }

    /// At most four rows, and never more than the page can spare - Create and Import have to
    /// stay on screen, and nothing here scrolls the page to reach them. The fifth account is
    /// where scrolling starts.
    private static let visibleSavedAccountRows = 4
    private static let savedAccountRowHeight: CGFloat = 64
    private static let savedAccountRowSpacing: CGFloat = 10

    private func savedAccountsSection(availableHeight: CGFloat) -> some View {
        let count = walletManager.savedAccounts.count
        let cappedRows = CGFloat(Self.visibleSavedAccountRows) * Self.savedAccountRowHeight
            + CGFloat(Self.visibleSavedAccountRows - 1) * Self.savedAccountRowSpacing
        // Everything else on this page - compact title, section header, both buttons and the
        // spacing around them. Whatever is left after that is what the list may take, floored at
        // two rows so it is always obviously a list.
        let reservedForRest: CGFloat = 340
        let twoRows = 2 * Self.savedAccountRowHeight + Self.savedAccountRowSpacing
        let spare = max(availableHeight - reservedForRest, twoRows)
        let listHeight = min(cappedRows, spare)
        let contentHeight = CGFloat(count) * Self.savedAccountRowHeight
            + CGFloat(max(count - 1, 0)) * Self.savedAccountRowSpacing
        let overflows = contentHeight > listHeight

        return VStack(alignment: .leading, spacing: 10) {
            Text("Saved Accounts")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            if overflows {
                // A List, not a ScrollView. This is a column of Buttons, and in a ScrollView the
                // buttons won the drag: scrolling did nothing and the attempt registered as a tap
                // that signed you in. A List is a UICollectionView underneath and gets
                // scroll-versus-tap right, which is the whole reason to reach for one here.
                List {
                    ForEach(walletManager.savedAccounts) { account in
                        savedAccountRow(account)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: Self.savedAccountRowSpacing, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: listHeight)
            } else {
                // Fits: no scroll container at all. One that cannot scroll still eats the drag.
                VStack(spacing: Self.savedAccountRowSpacing) {
                    ForEach(walletManager.savedAccounts) { account in
                        savedAccountRow(account)
                    }
                }
            }
        }
    }

    /// Rename or Delete for one saved account, behind the pencil.
    private func accountActionsSheet(_ account: SavedAccountSummary) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(account.displayAlias)
                    .font(.headline)
                Text(account.shortPublicAddress)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 20)
            .padding(.bottom, 4)

            ActionSheetRow(
                title: "Rename",
                subtitle: "Gives this account a name of your own.",
                systemImage: "pencil"
            ) {
                afterAccountActions = {
                    renameText = account.alias
                    pendingRenameAccount = account
                }
                accountActionsTarget = nil
            }
            ActionSheetRow(
                title: "Delete",
                subtitle: "Removes this account and its local data from this device.",
                systemImage: "trash",
                tint: .red
            ) {
                afterAccountActions = { pendingRemovalAccount = account }
                accountActionsTarget = nil
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
    }

    private func savedAccountRow(_ account: SavedAccountSummary) -> some View {
        HStack(spacing: 12) {
            Button {
                signIn(account)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.displayAlias)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                        Text(account.formattedPublicAddress)
                            .font(.scaled(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if signingInAccountId == account.id {
                        ProgressView()
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isAccountActionRunning)

            // Half sheet rather than a context menu, like every other chooser in the app - and
            // Delete gets a line saying what it takes with it, which a menu of bare verbs cannot.
            Button {
                accountActionsTarget = account
            } label: {
                Image(systemName: "pencil")
                    .font(.scaled(size: 15, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isAccountActionRunning)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.savedAccountRowHeight)
        .background(Self.rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func signIn(_ account: SavedAccountSummary) {
        guard !isAccountActionRunning else { return }
        signInErrorMessage = nil

        if settingsViewModel.settings.biometricAccountLoginEnabled {
            DeviceAuth.authenticate(reason: "Unlock to sign in to \(account.displayAlias)") {
                performSignIn(account)
            } onFailure: {
                signInErrorMessage = "Authentication failed."
            }
        } else {
            performSignIn(account)
        }
    }

    private func performSignIn(_ account: SavedAccountSummary) {
        // the Face ID prompt may have let another action start meanwhile
        guard !isAccountActionRunning else { return }
        signingInAccountId = account.id
        Task {
            let didSignIn = await walletManager.signInToSavedAccount(account)
            await MainActor.run {
                if !didSignIn {
                    if let needing = walletManager.savedAccountNeedingKeys {
                        // no keys for it on this phone: say so and offer the phrase, not an error
                        accountNeedingKeys = needing
                        walletManager.clearSavedAccountNeedingKeys()
                    }
                    // otherwise the reason is in `walletManager.signInFailureMessage`, which the
                    // alert reads (this screen may already be a new one by now)
                }
                signingInAccountId = nil
            }
        }
    }

    /// A new account in one tap: 24 words, no passphrase, the next free default name. The seed
    /// phrase comes later, through the Wallet tab's backup card.
    private func createAccount() {
        guard !isAccountActionRunning else { return }
        isCreatingAccount = true
        Task {
            do {
                let seedPhrase = try await walletManager.generateNewWalletSeedPhrase(wordCount: 24)
                _ = try await walletManager.commitCreatedWallet(
                    seedPhrase: seedPhrase,
                    passphrase: "",
                    alias: walletManager.nextDefaultAccountName()
                )
            } catch {
                createAccountError = error.localizedDescription
            }
            isCreatingAccount = false
        }
    }

    private func removeSavedAccount(_ account: SavedAccountSummary) {
        guard !isAccountActionRunning else { return }
        isRemovingAccount = true
        Task {
            await walletManager.removeSavedAccount(account)
            await MainActor.run {
                signingInAccountId = nil
                isRemovingAccount = false
                pendingRemovalAccount = nil
            }
        }
    }
}

/// "12 or 24 Words Needed" for one saved account: shown when signing in to an account whose
/// keys are not on this phone (after an iPhone restore - keys are locked to the phone they were
/// made on, only the active account gets the full-screen WalletRecoveryView). Explains what
/// happened and leads straight into Enter Recovery Phrase.
private struct AccountKeysNeededSheet: View {
    let account: SavedAccountSummary
    /// Closes the sheet and opens the import (seed entry) flow.
    let onEnterPhrase: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "key.slash")
                .font(.scaled(size: 44, weight: .semibold))
                .foregroundColor(.accentColor)
                .padding(.top, 28)
            Text("12 or 24 Words Needed")
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
            Text(String(format: AppLocalization.string("%@ is on this iPhone, but its keys are not. That happens after restoring from a backup, because keys are locked to the phone they were made on. Enter the account's 12 or 24 words to sign in. Its history on this phone is kept."), account.displayAlias))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            VStack(spacing: 4) {
                Text(account.displayAlias)
                    .font(.headline)
                Text(account.shortPublicAddress)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
            )
            Spacer()
            VStack(spacing: 10) {
                Button {
                    onEnterPhrase()
                } label: {
                    Text("Enter 12 or 24 Words")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentColor)
                        .foregroundColor(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                Button {
                    dismiss()
                } label: {
                    Text("Not Now")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    OnboardingView()
        .environmentObject(WalletManager.shared)
}
