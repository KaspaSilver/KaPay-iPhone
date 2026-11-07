import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct SettingsView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @ObservedObject private var hotWallet = HotWalletBalance.shared
    @Environment(\.dismiss) private var dismiss
    /// KaPay shows Settings as its own dock tab: no Done button there.
    var isDockTab = false

    @State private var showSeedPhrase = false
    @State private var showNFCCardBackup = false
    /// The backup steps from Back Up Account. Finishing them clears the backup banner.
    @State private var showAccountBackup = false
    @State private var accountHasPassphrase = false
    @State private var showLogoutConfirmation = false
    @State private var showDeleteAccountConfirmation = false
    /// The seed phrase over the Delete Account warning, which it closes back to.
    @State private var showSeedPhraseOverDeleteWarning = false
    /// The backup steps over the Delete Account warning, for an account that hasn't finished them.
    @State private var showBackupOverDeleteWarning = false
    @ObservedObject private var backupStatus = AccountBackupStatus.shared
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success
    /// Settings > Storage > Address Book Photos: bytes on this device, nil while measuring.
    @State private var addressBookPhotoBytes: Int64?
    @State private var confirmRemoveAddressBookPhotos = false

    var body: some View {
        NavigationStack {
            Form {
                // Alphabetical. Delete Account and Log Out stay apart below.
                settingsCategoryRow("About", icon: "info.circle", tint: .accentColor) {
                    AccountAboutPage()
                }
                settingsCategoryRow("Account Name", icon: "pencil", tint: .accentColor) {
                    AccountNamePage()
                }
                settingsCategoryRow("Back Up Account", icon: "key", tint: .accentColor) {
                    backUpAccountPage
                }
                settingsCategoryRow("Connection", icon: "antenna.radiowaves.left.and.right", tint: .accentColor) {
                    ConnectionHubPage()
                }
                settingsCategoryRow("Customization", icon: "paintbrush.pointed", tint: .accentColor) {
                    customizationPage
                }
                settingsCategoryRow("Diagnostics", icon: "stethoscope", tint: .accentColor) {
                    DiagnosticsSettingsPage()
                }
                settingsCategoryRow("Notifications", icon: "bell.badge", tint: .accentColor) {
                    NotificationsHubPage()
                }
                settingsCategoryRow("Security", icon: "lock.shield", tint: .accentColor) {
                    SecuritySettingsPage()
                }
                settingsCategoryRow("Storage", icon: "internaldrive", tint: .accentColor) {
                    storagePage
                }
                // Moved here from the Wallet tab (owner's call, 2026-10-27).
                Section {
                    Button(role: .destructive) {
                        showDeleteAccountConfirmation = true
                    } label: {
                        Label {
                            Text("Delete Account")
                                .foregroundColor(.red)
                        } icon: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                    }
                    Button(role: .destructive) {
                        showLogoutConfirmation = true
                    } label: {
                        Label {
                            Text("Log Out")
                                .foregroundColor(.red)
                        } icon: {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .foregroundColor(.red)
                        }
                    }
                }
            }
            .pinnedTabHeader("Settings")
            .toast(message: toastMessage, style: toastStyle)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    ConnectionStatusIndicator()
                }
                ToolbarItem(placement: .principal) {
                    balanceToolbarView
                }
                if !isDockTab {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
            }
            .sheet(isPresented: $showSeedPhrase) {
                SeedPhraseView()
            }
            .sheet(isPresented: $showAccountBackup) {
                AccountBackupView()
            }
            .task(id: walletManager.currentWallet?.publicAddress) {
                // A failed read (the words are readable only while unlocked) says nothing: it isn't
                // taken as "no passphrase", and the next visit asks again.
                guard let seed = try? walletManager.getSeedPhrase() else { return }
                accountHasPassphrase = !(seed.passphrase ?? "").isEmpty
            }
            .sheet(isPresented: $showNFCCardBackup) {
                #if canImport(CoreNFC) && !targetEnvironment(macCatalyst)
                NFCCardBackupView()
                #endif
            }
            // Half sheet rather than a confirmation dialog, matching every other chooser in the
            // app - and it gives the consequence a row of its own beside the action.
            .sheet(isPresented: $showLogoutConfirmation) {
                ConfirmActionSheet(
                    title: "Log Out",
                    confirmTitle: "Log Out",
                    confirmSubtitle: "Signs out of this account. Its data stays on this device.",
                    confirmSystemImage: "rectangle.portrait.and.arrow.right"
                ) {
                    Task { await walletManager.logout() }
                }
            }
            .sheet(isPresented: $showDeleteAccountConfirmation) {
                DeleteAccountSheet(
                    confirmSubtitle: "Removes this account and its data from this device.",
                    onViewSeedPhrase: { unlockSeedPhrase { showSeedPhraseOverDeleteWarning = true } },
                    notBackedUp: backupStatus.isPending(walletManager.currentWallet?.publicAddress),
                    onBackUp: { AccountBackupView.unlock { showBackupOverDeleteWarning = true } }
                ) {
                    DeviceAuth.authenticate(reason: AppLocalization.string("Confirm deleting this account")) {
                        Task { await walletManager.deleteCurrentAccount() }
                    }
                }
                .sheet(isPresented: $showSeedPhraseOverDeleteWarning) {
                    SeedPhraseView()
                }
                .sheet(isPresented: $showBackupOverDeleteWarning) {
                    AccountBackupView()
                }
            }
        }
        .onAppear {
            Task { _ = try? await walletManager.refreshBalance() }
        }
    }

    /// The seed phrase, behind the biometric gate when enabled.
    private func unlockSeedPhrase(_ show: @escaping () -> Void) {
        if settingsViewModel.settings.biometricSeedPhraseEnabled {
            DeviceAuth.authenticate(reason: "Unlock to view your 12 or 24 words", onSuccess: show)
        } else {
            show()
        }
    }

    // MARK: - Settings categories (each section is its own page)

    private var backUpAccountPage: some View {
        Form {
            if backupStatus.isPending(walletManager.currentWallet?.publicAddress) {
                Section {
                    Button {
                        AccountBackupView.unlock { showAccountBackup = true }
                    } label: {
                        Label {
                            Text("Complete Your Backup")
                                .foregroundColor(.primary)
                        } icon: {
                            Image(systemName: "exclamationmark.shield.fill")
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
            Section {
                Button {
                    unlockSeedPhrase { showSeedPhrase = true }
                } label: {
                    Label {
                        Text("View 12 or 24 Words")
                            .foregroundColor(.primary)
                    } icon: {
                        Image(systemName: "key")
                            .foregroundColor(.accentColor)
                    }
                }
                #if canImport(CoreNFC) && !targetEnvironment(macCatalyst)
                // Without a passphrase, nothing would protect the seed if someone got past the PIN.
                if NFCCard.isAvailable && accountHasPassphrase {
                    Button {
                        unlockSeedPhrase { showNFCCardBackup = true }
                    } label: {
                        Label {
                            Text("Back Up to NFC Card")
                                .foregroundColor(.primary)
                        } icon: {
                            Image(systemName: "wave.3.right")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                #endif
            }
        }
        .navigationTitle("Back Up Account")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var customizationPage: some View {
        Form {
            Section("Customization") {
                // Appearance/Language/Currency are extracted so the accounts-screen App Settings
                // can reuse the exact same rows (one source of truth).
                AppWideCustomizationPickers()
            }
        }
        .navigationTitle("Customization")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Storage hub: a category list like the main Settings screen — each provider row leads
    /// into its own screen.
    private var storagePage: some View {
        Form {
            // Your own data, not cache: photos you assigned in the Address Book. Kept apart from
            // Cache, whose "clear" must never delete anything you'd miss.
            Section {
                HStack {
                    Label("Contact Photos", systemImage: "person.text.rectangle")
                    Spacer()
                    if let bytes = addressBookPhotoBytes {
                        Text(CacheManager.formatted(bytes))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    } else {
                        ProgressView()
                    }
                }
                if (addressBookPhotoBytes ?? 0) > 0 {
                    Button(role: .destructive) {
                        confirmRemoveAddressBookPhotos = true
                    } label: {
                        Text("Remove Contact Photos")
                            .foregroundColor(.red)
                    }
                }
            } header: {
                Text("On This Device")
            }
            .task { await refreshAddressBookPhotoBytes() }
            .sheet(isPresented: $confirmRemoveAddressBookPhotos) {
                ConfirmActionSheet(
                    title: AppLocalization.string("Remove Contact Photos?"),
                    confirmTitle: AppLocalization.string("Remove"),
                    confirmSubtitle: String(
                        format: AppLocalization.string("Frees %@. Saved addresses keep their names; they show the avatar their owner set instead."),
                        CacheManager.formatted(addressBookPhotoBytes ?? 0)
                    ),
                    confirmSystemImage: "trash"
                ) {
                    AddressBookManager.shared.removeAllPhotos()
                    Task { await refreshAddressBookPhotoBytes() }
                }
            }

            Section {
                settingsCategoryRow("Cache", icon: "trash", tint: .accentColor) {
                    CacheSettingsPage()
                }
            }

            Section {
                settingsCategoryRow("Nextcloud", icon: "externaldrive.connected.to.line.below", tint: .accentColor) {
                    NextcloudSettingsView()
                        .navigationTitle("Nextcloud")
                        .navigationBarTitleDisplayMode(.inline)
                }
            } header: {
                Text("Backup")
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func refreshAddressBookPhotoBytes() async {
        addressBookPhotoBytes = await Task.detached(priority: .utility) {
            AddressBookManager.photosBytesOnDevice()
        }.value
    }

    private var balanceToolbarView: some View {
        let sompi = hotWallet.totalSompi(for: walletManager.currentWallet)
        let exact = sompi.map(formatKaspaExact) ?? "--"
        // Kaspa logo + bold, matching the balance style on every other screen's top bar.
        return HStack(spacing: 6) {
            Image("KaspaLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 15, height: 15)
            Text(verbatim: "\(exact) \(KaspaUnit.symbol)")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
        .onTapGesture {
            guard sompi != nil else { return }
            UIPasteboard.general.string = exact
            Haptics.success()
            showToast("Balance copied to clipboard.")
        }
        .task(id: walletManager.currentWallet?.publicAddress) {
            await hotWallet.refreshUntilKnown()
        }
    }

    private func showToast(_ message: String, style: ToastStyle = .success) {
        let token = UUID()
        toastToken = token
        toastStyle = style
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }

    private func formatKaspaExact(_ sompi: UInt64) -> String {
        let kas = Double(sompi) / 100_000_000.0
        return String(format: "%.8f", kas)
    }
}

// MARK: - About

/// Settings > About: this account's created date, then the app's version, links and licenses.
private struct AccountAboutPage: View {
    @EnvironmentObject private var walletManager: WalletManager

    @State private var showOpenSourceLicenses = false

    private static let websiteURL = URL(string: "https://home.kachat.app")!
    private static let privacyPolicyURL = URL(string: "https://home.kachat.app/privacy/")!
    private static let supportEmailURL = URL(string: "mailto:kaspasilver@gmail.com")!

    var body: some View {
        Form {
            Section {
                if let wallet = walletManager.currentWallet {
                    HStack {
                        Text("Created")
                        Spacer()
                        Text(SharedFormatting.mediumDateShortTime.string(from: wallet.createdAt))
                            .foregroundColor(.secondary)
                    }
                }
                HStack {
                    Text("Version")
                    Spacer()
                    Text(AppVersion.display)
                        .foregroundColor(.secondary)
                }
                Link(destination: Self.websiteURL) {
                    HStack {
                        Text("Website")
                            .foregroundColor(.primary)
                        Spacer()
                        Text(verbatim: "home.kachat.app")
                            .foregroundColor(.secondary)
                    }
                }
                Link(destination: Self.supportEmailURL) {
                    HStack {
                        Text("Support Email")
                            .foregroundColor(.primary)
                        Spacer()
                        Text(verbatim: "kaspasilver@gmail.com")
                            .foregroundColor(.secondary)
                    }
                }
                Link(destination: Self.privacyPolicyURL) {
                    HStack {
                        Text("Privacy Policy")
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                }
                Button {
                    showOpenSourceLicenses = true
                } label: {
                    HStack {
                        Text("Open Source Licenses")
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showOpenSourceLicenses) {
            OpenSourceLicensesView()
        }
    }
}

// MARK: - Shared category row (SettingsView + AppSettingsView)

/// The standard Settings category row: icon + title behind a NavigationLink. File-scope so the
/// in-account SettingsView and the accounts-screen AppSettingsView render identical rows.
fileprivate func settingsCategoryRow<Destination: View>(
    _ title: String,
    icon: String,
    tint: Color,
    @ViewBuilder destination: @escaping () -> Destination
) -> some View {
    NavigationLink {
        destination()
    } label: {
        Label {
            Text(title)
                .foregroundColor(tint == .red ? .red : .primary)
        } icon: {
            Image(systemName: icon)
                .foregroundColor(tint)
        }
    }
}

// MARK: - App-wide settings pages (shared by SettingsView and AppSettingsView)
//
// These pages carry the app-wide settings tier - everything here applies to the whole install
// regardless of which account is active, which is why the accounts-list screen's App Settings
// (see AppSettingsView) can host the SAME views without a wallet loaded. The in-account
// SettingsView embeds them unchanged, so there's exactly one source of truth per page.

// MARK: - Account Name

/// Settings > Account Name: your own label for this account, saved when you leave the page.
private struct AccountNamePage: View {
    @EnvironmentObject private var walletManager: WalletManager
    @State private var name = ""

    var body: some View {
        Form {
            Section {
                TextField("Account name", text: $name)
                    .submitLabel(.done)
            }
        }
        .navigationTitle("Account Name")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = walletManager.currentWallet?.alias ?? "" }
        .onDisappear(perform: save)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let wallet = walletManager.currentWallet, !trimmed.isEmpty, trimmed != wallet.alias,
              let account = walletManager.savedAccounts.first(where: { $0.publicAddress == wallet.publicAddress })
        else { return }
        walletManager.renameSavedAccount(account, to: trimmed)
    }
}

/// Security page: the biometric toggles. All fields live in the global AppSettings blob - nothing
/// here needs an active account, so it is reachable from the accounts list too.
struct SecuritySettingsPage: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @ObservedObject private var walletManager = WalletManager.shared

    /// A biometric lock that could be switched off without passing the lock is not a lock -
    /// anyone holding an unlocked phone could have turned all three off and then read the seed
    /// phrase. So the switch itself is gated, in BOTH directions: turning one on is a claim
    /// about who is holding the device too.
    ///
    /// The Toggle is driven off a proxy binding rather than the setting: the write only happens
    /// after authentication succeeds, so a failed or cancelled prompt leaves the switch exactly
    /// where it was instead of flipping and flipping back.
    private func biometricToggle(_ title: String, reason: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { isOn.wrappedValue },
            set: { requested in
                guard requested != isOn.wrappedValue else { return }
                DeviceAuth.authenticate(reason: reason) {
                    isOn.wrappedValue = requested
                    settingsViewModel.saveSettings()
                } onFailure: {
                    // Nothing to undo - the setting was never written.
                    Haptics.impact(.medium)
                }
            }
        ))
    }

    var body: some View {
        Form {
            Section("Security") {
                biometricToggle(
                    "Biometrics for 12 or 24 Words",
                    reason: "Unlock to change the 12 or 24 words biometric lock",
                    isOn: $settingsViewModel.settings.biometricSeedPhraseEnabled
                )
                biometricToggle(
                    "Biometrics for Account Login",
                    reason: "Unlock to change the account login biometric lock",
                    isOn: $settingsViewModel.settings.biometricAccountLoginEnabled
                )
                biometricToggle(
                    "Biometrics for Address Private Keys",
                    reason: "Unlock to change the private key biometric lock",
                    isOn: $settingsViewModel.settings.biometricSpendingKeyEnabled
                )
            }
        }
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The three app-wide customization pickers (Appearance / Language / Currency) as loose rows,
/// so each host wraps them in its own Section: SettingsView's Customization page adds the
/// per-account extras (Customize Dock, Show Setup Guides) after them; AppSettingsView shows
/// them alone.
struct AppWideCustomizationPickers: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    var body: some View {
        Group {
            Picker("Appearance", selection: $settingsViewModel.settings.appearance) {
                ForEach(AppAppearance.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .onChange(of: settingsViewModel.settings.appearance) { _ in
                settingsViewModel.saveSettings()
            }

            Picker("Language", selection: $settingsViewModel.settings.language) {
                ForEach(AppLanguage.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .onChange(of: settingsViewModel.settings.language) { newValue in
                settingsViewModel.saveSettings()
                settingsViewModel.applyLanguagePreference(newValue)
            }

            Picker("Currency", selection: $settingsViewModel.settings.currency) {
                ForEach(AppCurrency.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .onChange(of: settingsViewModel.settings.currency) { _ in
                settingsViewModel.saveSettings()
            }
        }
    }
}

/// Connection hub: endpoints (indexers/KNS/REST/node) and explorer choice - all global
/// AppSettings fields, safe with no active account.
struct ConnectionHubPage: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                // Mainnet <-> testnet, first in the section (no footer). The choice applies at the
                // next launch, all at once (`PendingNetworkSwitch`); each network keeps its own
                // connection settings (`AppSettings.switchNetwork(to:)`), so after the restart
                // Connection Settings below shows that network's values.
                Toggle(isOn: Binding(
                    get: { settingsViewModel.selectedNetworkType == .testnet },
                    set: { on in
                        settingsViewModel.switchNetwork(to: on ? .testnet : .mainnet)
                        Haptics.success()
                    }
                )) {
                    Label("Testnet", systemImage: "testtube.2")
                }
                .tint(.orange)

                if settingsViewModel.selectedNetworkType != settingsViewModel.launchNetworkType {
                    Label {
                        Text(settingsViewModel.selectedNetworkType == .testnet
                             ? LocalizedStringKey("Close KaPay completely and open it again to finish switching to Testnet.")
                             : LocalizedStringKey("Close KaPay completely and open it again to finish switching back to Mainnet."))
                    } icon: {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .foregroundColor(.orange)
                    }
                    .font(.subheadline)
                }

                NavigationLink {
                    ConnectionSettingsView()
                } label: {
                    Label("Connection Settings", systemImage: "network")
                }
            } header: {
                Text("Connection")
            }

            Section {
                NavigationLink {
                    KaspaExplorerSettingsView()
                } label: {
                    HStack {
                        Label("Kaspa Explorer", systemImage: "safari")
                        Spacer()
                        Text(settingsViewModel.settings.kaspaExplorer.displayName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Diagnostics export, self-contained (own progress/share-sheet/toast state) so it can be
/// hosted from both the in-account Settings and the accounts-screen App Settings. Works with
/// no active account: everything it collects comes from singletons that degrade gracefully.
struct DiagnosticsSettingsPage: View {
    @State private var isPreparingDiagnostics = false
    @State private var diagnosticsArchiveURL: URL?
    @State private var showDiagnosticsShareSheet = false
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success
    @State private var verboseAPILogging = AppSettings.load().verboseAPILogging

    var body: some View {
        Form {
            Section("Diagnostics") {
                Button {
                    Task {
                        await exportDiagnosticsArchive()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: "ladybug.fill")
                                .font(.title3)
                                .foregroundColor(.accentColor)
                            Text("Export Diagnostics Archive")
                                .font(.body.weight(.medium))
                                .foregroundColor(.accentColor)
                            Spacer()
                            if isPreparingDiagnostics {
                                ProgressView()
                            }
                        }
                        Text("Exports the app version, iOS version, the wallet's settings and connection state, the Kaspa node pool and the last day of the app's own logs as a zip, for troubleshooting with support. No private keys, 12 or 24 words, addresses, contacts or portfolios are included.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .disabled(isPreparingDiagnostics)
            }
            Section {
                Toggle("Verbose API Logging", isOn: $verboseAPILogging)
                    .onChange(of: verboseAPILogging) { newValue in
                        var settings = AppSettings.load()
                        guard settings.verboseAPILogging != newValue else { return }
                        settings.verboseAPILogging = newValue
                        AppSettings.save(settings)
                        // AppSettings.save posts .settingsDidChange WITH the settings object,
                        // which the app's long-lived SettingsViewModel deliberately ignores
                        // (it assumes object-bearing posts came from its own saveSettings).
                        // Follow up with a nil-object post - the account-switch signal - so
                        // that instance reloads from disk and its next save can't stomp this
                        // flag with a stale in-memory copy.
                        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
                    }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toast(message: toastMessage, style: toastStyle)
        .sheet(isPresented: $showDiagnosticsShareSheet) {
            if let diagnosticsArchiveURL {
                DiagnosticsShareSheet(fileURL: diagnosticsArchiveURL)
            }
        }
    }

    private func exportDiagnosticsArchive() async {
        if isPreparingDiagnostics { return }
        isPreparingDiagnostics = true
        defer { isPreparingDiagnostics = false }

        let archive = await buildDiagnosticsArchive()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folderName = "kachat-wallet-diagnostics-\(timestamp)"
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(folderName, isDirectory: true)
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(folderName).zip")

        do {
            if FileManager.default.fileExists(atPath: tempDir.path) {
                try FileManager.default.removeItem(at: tempDir)
            }
            if FileManager.default.fileExists(atPath: zipURL.path) {
                try FileManager.default.removeItem(at: zipURL)
            }
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(archive)
            let jsonURL = tempDir.appendingPathComponent("diagnostics.json")
            try data.write(to: jsonURL, options: .atomic)

            let logs = await collectAppLogs()
            let logData = logs.data(using: .utf8, allowLossyConversion: true) ?? Data()
            let logsURL = tempDir.appendingPathComponent("app.log")
            try logData.write(to: logsURL, options: .atomic)

            let zipFiles = [
                SimpleZipWriter.FileEntry(name: "diagnostics.json", data: data),
                SimpleZipWriter.FileEntry(name: "app.log", data: logData)
            ]
            try SimpleZipWriter.createZip(at: zipURL, files: zipFiles)
            diagnosticsArchiveURL = zipURL
            showDiagnosticsShareSheet = true
        } catch {
            AppLog.log("[Settings] Failed to export diagnostics: %@", error.localizedDescription)
            showToast("Failed to export diagnostics.", style: .error)
        }
    }

    private func buildDiagnosticsArchive() async -> DiagnosticsArchive {
        let settings = AppSettings.load()
        let nodePoolRecords = await NodePoolService.shared.allNodeRecords()
        let nodeStateCounts = await NodePoolService.shared.nodeStateCounts()

        let appInfo = DiagnosticsArchive.AppInfo(
            bundleId: Bundle.main.bundleIdentifier ?? "unknown",
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        )

        let deviceInfo = DiagnosticsArchive.DeviceInfo(
            model: UIDevice.current.model,
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion
        )

        let nodePoolSummary = DiagnosticsArchive.NodePoolSummary(
            counts: nodeStateCounts.mapValues { $0 },
            totalRecords: nodePoolRecords.count
        )

        // The wallet's live state - counts and flags only, never an address.
        let walletService = WalletService.shared
        let nextcloud = NextcloudService.shared
        let walletInfo = DiagnosticsArchive.WalletInfo(
            hasActiveAccount: WalletManager.shared.currentWallet != nil,
            liveSubscriptionActive: walletService.isRpcSubscribed,
            lastSuccessfulSync: walletService.lastSuccessfulSyncDate,
            pushRegistered: PushNotificationManager.shared.isRegistered,
            pushWatchedAddressCount: PushNotificationManager.shared.watchedAddressesCount,
            kachatNamesSource: KachatNamesRegistry.shared.source.map { $0.isIndexer ? "indexer" : "chain" },
            nextcloudConnected: nextcloud.isConnected,
            nextcloudAutomaticBackup: nextcloud.autoBackupEnabled,
            nextcloudLastBackup: nextcloud.lastBackupAt
        )

        return DiagnosticsArchive(
            generatedAt: Date(),
            app: appInfo,
            device: deviceInfo,
            settings: settings,
            wallet: walletInfo,
            nodePool: nodePoolSummary,
            nodePoolRecords: nodePoolRecords
        )
    }

    private func collectAppLogs() async -> String {
        if #available(iOS 15.0, macOS 12.0, *) {
            do {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                let start = store.position(date: Date().addingTimeInterval(-24 * 60 * 60))
                let entries = try store.getEntries(at: start)
                var lines: [String] = []
                lines.reserveCapacity(5000)
                let formatter = ISO8601DateFormatter()
                let bundleId = Bundle.main.bundleIdentifier ?? "com.kachat.wallet"
                var count = 0
                for case let entry as OSLogEntryLog in entries {
                    let subsystem = entry.subsystem
                    let category = entry.category
                    let message = entry.composedMessage
                    // The app's own logs only - not every iOS framework's chatter.
                    guard subsystem.isEmpty || subsystem == bundleId || subsystem.hasPrefix("com.kachat") else { continue }

                    let date = formatter.string(from: entry.date)
                    let line = "\(date) [\(String(describing: entry.level))] \(subsystem) \(category): \(message)"
                    lines.append(line)
                    count += 1
                    if count >= 5000 { break }
                }
                return lines.joined(separator: "\n")
            } catch {
                return "Failed to export logs: \(error.localizedDescription)"
            }
        }
        return "Log export not supported on this OS version."
    }

    private func showToast(_ message: String, style: ToastStyle = .success) {
        let token = UUID()
        toastToken = token
        toastStyle = style
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }
}

// MARK: - App Settings (accounts-list cog)

/// The app-wide settings tier, reachable from the accounts list's gear button when no account
/// is active. Contains ONLY settings that apply to the entire install: Customization
/// (Appearance/Language/Currency), Security, Connection endpoints, and Diagnostics. Everything
/// account-specific (storage, Nextcloud, notifications) lives only in the in-account SettingsView.
struct AppSettingsView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                settingsCategoryRow("Customization", icon: "paintbrush.pointed", tint: .accentColor) {
                    appCustomizationPage
                }
                settingsCategoryRow("Security", icon: "lock.shield", tint: .accentColor) {
                    SecuritySettingsPage()
                }
                settingsCategoryRow("Connection", icon: "antenna.radiowaves.left.and.right", tint: .accentColor) {
                    ConnectionHubPage()
                }
                settingsCategoryRow("Diagnostics", icon: "stethoscope", tint: .accentColor) {
                    DiagnosticsSettingsPage()
                }
            }
            .navigationTitle("App Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var appCustomizationPage: some View {
        Form {
            Section("Customization") {
                AppWideCustomizationPickers()
            }
        }
        .navigationTitle("Customization")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings > Notifications: push on or off, the own-address receive-activity toggle (see
/// AddressActivityNotifier), and the sound/vibration it and every foreground banner use - all on
/// one page.
struct NotificationsHubPage: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var pushManager: PushNotificationManager

    @State private var isEnablingPush = false
    @State private var notificationPermissionDenied = false
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success

    private var pushEnabled: Bool {
        settingsViewModel.settings.notificationMode == .remotePush
    }

    var body: some View {
        Form {
            // The master switch, at the top of the screen it governs: push carries "Received"
            // and .kachat name events, so it sits above the switches for them.
            //
            // A toggle rather than the old Mode picker of two cases, and the registration
            // Status / Watching rows are gone with it. Those answered "is the plumbing
            // connected", which is a question for a diagnostics screen; here the only question
            // is whether you want push at all, and a picker with exactly two options was a
            // switch wearing a menu.
            Section {
                Toggle(isOn: Binding(
                    get: { pushEnabled },
                    set: { handleNotificationModeChange(to: $0 ? .remotePush : .disabled) }
                )) {
                    HStack(spacing: 8) {
                        Text("Push Notifications")
                        if isEnablingPush {
                            ProgressView().scaleEffect(0.8)
                        }
                    }
                }
                .disabled(isEnablingPush)
            }

            Section {
                Toggle("Address Activity", isOn: $settingsViewModel.settings.addressActivityNotificationsEnabled)
                    .onChange(of: settingsViewModel.settings.addressActivityNotificationsEnabled) { _ in
                        settingsViewModel.saveSettings()
                    }
            }

            Section {
                Toggle("Play sound", isOn: $settingsViewModel.settings.incomingNotificationSoundEnabled)
                    .onChange(of: settingsViewModel.settings.incomingNotificationSoundEnabled) { _ in
                        settingsViewModel.saveSettings()
                    }

                Toggle("Vibration", isOn: $settingsViewModel.settings.incomingNotificationVibrationEnabled)
                    .onChange(of: settingsViewModel.settings.incomingNotificationVibrationEnabled) { _ in
                        settingsViewModel.saveSettings()
                    }
            } header: {
                Text("Sound & Vibration")
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toast(message: toastMessage, style: toastStyle)
        .alert("Notifications Disabled", isPresented: $notificationPermissionDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("To receive notifications, please enable them in Settings.")
        }
    }

    private func handleNotificationModeChange(to newMode: NotificationMode) {
        let previousMode = settingsViewModel.settings.notificationMode
        guard newMode != previousMode else { return }

        switch newMode {
        case .disabled:
            if previousMode == .remotePush {
                disablePushNotifications()
            }
            settingsViewModel.settings.notificationMode = .disabled
            settingsViewModel.saveSettings()
        case .remotePush:
            settingsViewModel.settings.notificationMode = .remotePush
            settingsViewModel.saveSettings()
            BackgroundTaskManager.shared.cancelBackgroundFetch()
            enablePushNotifications(previousMode: previousMode)
        }
    }

    private func enablePushNotifications(previousMode: NotificationMode) {
        isEnablingPush = true
        Task {
            do {
                try await pushManager.requestPermissionAndRegisterAndWaitForIndexer()
                settingsViewModel.settings.notificationMode = .remotePush
                settingsViewModel.saveSettings()
            } catch {
                AppLog.log("[Settings] Failed to enable push: %@", error.localizedDescription)
                settingsViewModel.settings.notificationMode = previousMode
                settingsViewModel.saveSettings()
                if case PushError.permissionDenied = error {
                    notificationPermissionDenied = true
                }
                showToast("Push subscription failed.", style: .error)
            }
            isEnablingPush = false
        }
    }

    private func disablePushNotifications() {
        Task {
            await pushManager.unregister()
            settingsViewModel.saveSettings()
        }
    }

    private func showToast(_ message: String, style: ToastStyle = .success) {
        let token = UUID()
        toastToken = token
        toastStyle = style
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }
}

private struct DiagnosticsArchive: Codable {
    struct AppInfo: Codable {
        let bundleId: String
        let version: String
        let build: String
    }

    struct DeviceInfo: Codable {
        let model: String
        let systemName: String
        let systemVersion: String
    }

    struct WalletInfo: Codable {
        let hasActiveAccount: Bool
        let liveSubscriptionActive: Bool
        let lastSuccessfulSync: Date?
        let pushRegistered: Bool
        let pushWatchedAddressCount: Int?
        /// "indexer" or "chain"; nil before the first check.
        let kachatNamesSource: String?
        let nextcloudConnected: Bool
        let nextcloudAutomaticBackup: Bool
        let nextcloudLastBackup: Date?
    }

    struct NodePoolSummary: Codable {
        let counts: [NodeState: Int]
        let totalRecords: Int
    }

    let generatedAt: Date
    let app: AppInfo
    let device: DeviceInfo
    /// The wallet's settings: network, connection endpoints, notification and security switches.
    let settings: AppSettings
    let wallet: WalletInfo
    let nodePool: NodePoolSummary
    let nodePoolRecords: [NodeRecord]
}

private struct DiagnosticsShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private enum SimpleZipWriter {
    struct FileEntry {
        let name: String
        let data: Data
    }

    static func createZip(at url: URL, files: [FileEntry]) throws {
        var localFileHeaders: [Data] = []
        var centralDirectory: [Data] = []
        var offset: UInt32 = 0

        for file in files {
            let crc = crc32(file.data)
            let fileNameData = Data(file.name.utf8)
            let localHeader = buildLocalFileHeader(
                fileNameLength: UInt16(fileNameData.count),
                crc32: crc,
                size: UInt32(file.data.count)
            )
            var localEntry = Data()
            localEntry.append(localHeader)
            localEntry.append(fileNameData)
            localEntry.append(file.data)
            localFileHeaders.append(localEntry)

            let centralHeader = buildCentralDirectoryHeader(
                fileNameLength: UInt16(fileNameData.count),
                crc32: crc,
                size: UInt32(file.data.count),
                localHeaderOffset: offset
            )
            var centralEntry = Data()
            centralEntry.append(centralHeader)
            centralEntry.append(fileNameData)
            centralDirectory.append(centralEntry)

            offset += UInt32(localEntry.count)
        }

        let centralStart = offset
        var centralData = Data()
        for entry in centralDirectory {
            centralData.append(entry)
            offset += UInt32(entry.count)
        }

        let endRecord = buildEndOfCentralDirectory(
            totalEntries: UInt16(files.count),
            centralDirectorySize: UInt32(centralData.count),
            centralDirectoryOffset: centralStart
        )

        var archive = Data()
        for entry in localFileHeaders {
            archive.append(entry)
        }
        archive.append(centralData)
        archive.append(endRecord)

        try archive.write(to: url, options: .atomic)
    }

    private static func buildLocalFileHeader(fileNameLength: UInt16, crc32: UInt32, size: UInt32) -> Data {
        var data = Data()
        data.appendUInt32(0x04034b50)
        data.appendUInt16(20)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt32(crc32)
        data.appendUInt32(size)
        data.appendUInt32(size)
        data.appendUInt16(fileNameLength)
        data.appendUInt16(0)
        return data
    }

    private static func buildCentralDirectoryHeader(
        fileNameLength: UInt16,
        crc32: UInt32,
        size: UInt32,
        localHeaderOffset: UInt32
    ) -> Data {
        var data = Data()
        data.appendUInt32(0x02014b50)
        data.appendUInt16(20)
        data.appendUInt16(20)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt32(crc32)
        data.appendUInt32(size)
        data.appendUInt32(size)
        data.appendUInt16(fileNameLength)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt32(0)
        data.appendUInt32(localHeaderOffset)
        return data
    }

    private static func buildEndOfCentralDirectory(
        totalEntries: UInt16,
        centralDirectorySize: UInt32,
        centralDirectoryOffset: UInt32
    ) -> Data {
        var data = Data()
        data.appendUInt32(0x06054b50)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt16(totalEntries)
        data.appendUInt16(totalEntries)
        data.appendUInt32(centralDirectorySize)
        data.appendUInt32(centralDirectoryOffset)
        data.appendUInt16(0)
        return data
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ crcTable[index]
        }
        return crc ^ 0xFFFFFFFF
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                if c & 1 == 1 {
                    c = 0xEDB88320 ^ (c >> 1)
                } else {
                    c = c >> 1
                }
            }
            return c
        }
    }()
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: MemoryLayout<UInt16>.size))
    }

    mutating func appendUInt32(_ value: UInt32) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: MemoryLayout<UInt32>.size))
    }
}

struct SeedPhraseView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var walletManager: WalletManager
    @State private var seedPhrase: SeedPhrase?
    @State private var isRevealed = false
    @State private var revealToken = UUID()
    @State private var error: String?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success
    @State private var showScreenshotWarning = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Warning
                VStack(alignment: .leading, spacing: 12) {
                    Label("Security Warning", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundColor(.orange)

                    Text("Anyone with your 12 or 24 words can access your account. Never share them with anyone.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text("Best practice is to write your 12 or 24 words down to back them up, and never store it online.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if let seedPhrase = seedPhrase {
                    // A passphrase (the "25th word") changes every key: the words alone restore a
                    // different, empty wallet, so the backup screen must say so.
                    if let passphrase = seedPhrase.passphrase, !passphrase.isEmpty {
                        Label("This wallet also uses a passphrase. You need it together with these words to restore it.",
                              systemImage: "key.fill")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if isRevealed {
                        // Seed phrase grid. SecureView only blurs it while the screen is recorded or
                        // mirrored; iOS can't stop a screenshot, so one gets the warning below.
                        SecureView {
                            LazyVGrid(columns: [
                                GridItem(.flexible()),
                                GridItem(.flexible()),
                                GridItem(.flexible())
                            ], spacing: 8) {
                                ForEach(Array(seedPhrase.words.enumerated()), id: \.offset) { index, word in
                                    HStack(spacing: 4) {
                                        Text("\(index + 1).")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .frame(width: 18, alignment: .trailing)
                                        Text(word)
                                            .font(.system(.subheadline, design: .monospaced))
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.6)
                                            .allowsTightening(true)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 6)
                                    .background(Color(.systemGray6))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                        if let passphrase = seedPhrase.passphrase, !passphrase.isEmpty {
                            SecureView {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Passphrase")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(verbatim: passphrase)
                                        .font(.system(.subheadline, design: .monospaced))
                                        .textSelection(.disabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }

                        // Both copies go through the sensitive path: local-only clipboard (never
                        // Handoff / Universal Clipboard), wiped again 30 s later.
                        VStack(spacing: 12) {
                            Button {
                                copySensitiveToClipboard(seedPhrase.words.joined(separator: " "))
                                Haptics.success()
                                showToast("Words copied. Clipboard will clear in 30s.")
                            } label: {
                                Label("Copy 12 or 24 Words", systemImage: "doc.on.doc")
                            }
                            Button {
                                guard let privateKey = walletManager.getPrivateKey() else {
                                    showToast("Private key unavailable.", style: .error)
                                    return
                                }
                                copySensitiveToClipboard(privateKey.hexString)
                                Haptics.success()
                                showToast("Private key hex copied. Clipboard will clear in 30s.")
                            } label: {
                                Label("Copy Private Key Hex", systemImage: "number")
                            }
                        }
                        .padding(.top)
                    } else {
                        Button {
                            isRevealed = true
                            let token = UUID()
                            revealToken = token
                            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                                if revealToken == token {
                                    isRevealed = false
                                }
                            }
                        } label: {
                            VStack(spacing: 12) {
                                Image(systemName: "eye.slash.fill")
                                    .font(.largeTitle)
                                Text("Tap to reveal your 12 or 24 words")
                                    .font(.subheadline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(60)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .foregroundColor(.secondary)
                    }
                } else if let error = error {
                    Text(error)
                        .foregroundColor(.red)
                } else {
                    ProgressView()
                }

                Spacer()
            }
            .padding()
            .navigationTitle("12 or 24 Words")
            .navigationBarTitleDisplayMode(.inline)
            .toast(message: toastMessage, style: toastStyle)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadSeedPhrase()
            }
            // iOS can't stop a screenshot, only say so afterwards, as the backup steps do.
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
                if isRevealed { showScreenshotWarning = true }
            }
            .alert("Delete That Screenshot", isPresented: $showScreenshotWarning) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("A screenshot of your 12 or 24 words can end up online. Delete it from your photos and write the words on paper instead.")
            }
        }
    }

    private func loadSeedPhrase() {
        do {
            seedPhrase = try KeychainService.shared.loadSeedPhrase()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Copies sensitive material (the private key hex) to the clipboard with a hard 30s system
    /// expiration and `localOnly` (never syncs to other devices via Universal Clipboard/Handoff).
    /// The system honors `expirationDate` even if the app is suspended before it elapses; the
    /// asyncAfter wipe below is a belt-and-suspenders in-app clear that also fires at 30s when
    /// nothing else has overwritten the clipboard in the meantime.
    private func copySensitiveToClipboard(_ value: String) {
        UIPasteboard.general.setItems(
            [["public.utf8-plain-text": value]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(30)]
        )
        let copiedValue = value
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            if UIPasteboard.general.string == copiedValue {
                UIPasteboard.general.string = ""
            }
        }
    }

    private func showToast(_ message: String, style: ToastStyle = .success) {
        let token = UUID()
        toastToken = token
        toastStyle = style
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }
}

struct KaspaExplorerSettingsView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                ForEach(KaspaExplorer.allCases, id: \.self) { explorer in
                    Button {
                        settingsViewModel.kaspaExplorer = explorer
                    } label: {
                        HStack {
                            Text(explorer.displayName)
                                .foregroundColor(.primary)
                            Spacer()
                            if settingsViewModel.settings.kaspaExplorer == explorer {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            } header: {
                Text("Explorer")
            }
        }
        .navigationTitle("Kaspa Explorer")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ConnectionSettingsView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    /// The .kachat names indexer (Domains tab). Blank = the network's default.
    @State private var indexerURL: String = ""
    @State private var pushIndexerURL: String = ""
    /// Where .kachat names are read from right now, for the Domains tab.
    @ObservedObject private var kachatRegistry = KachatNamesRegistry.shared
    @State private var kaspaRestAPIURL: String = ""
    @State private var trustedNodeValidationError: String?

    @State private var newSavedNodeLabel: String = ""
    @State private var newSavedNodeAddress: String = ""
    @State private var savedNodeAddressError: String?

    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success

    /// Decision 3A: every endpoint field on this page is https-only. Shown inline under any
    /// field whose value starts with http://, and Save refuses to persist while one remains.
    private static let httpsRequiredError = "Use https. Unencrypted connections are not supported."

    /// True when the field value explicitly asks for cleartext http. Bare hostnames (no scheme)
    /// are fine - they are normalized to https:// on save, matching
    /// `NextcloudService.normalizedServerURL`.
    private func isCleartextHTTP(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://")
    }

    /// Inline red caption shown under a URL field while it holds an http:// value.
    @ViewBuilder
    private func httpsInlineError(for value: String) -> some View {
        if isCleartextHTTP(value) {
            Text(Self.httpsRequiredError)
                .font(.caption)
                .foregroundColor(.red)
        }
    }

    /// Normalizes a saved endpoint: trims whitespace and defaults a scheme-less value
    /// ("indexer.kachat.app") to https://, so bare hostnames keep working exactly like the
    /// Nextcloud server field already did. http:// never reaches here - Save rejects it first.
    private func normalizedHTTPSURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.lowercased().hasPrefix("https://") { return trimmed }
        return "https://" + trimmed
    }

    /// The Push tab: the push registration server. (.kachat names have their own indexer field,
    /// on the Domains tab.)
    @ViewBuilder
    private var pushSections: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Push Indexer URL")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField(indexerPlaceholder(AppSettings.defaultPushIndexerURL), text: $pushIndexerURL)
                    .font(.system(.body, design: .monospaced))
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                httpsInlineError(for: pushIndexerURL)
            }
        } header: {
            Text("Push Registration")
        }

    }

    @ViewBuilder
    private var nodeSections: some View {
        Section {
            Picker(
                "Kaspa Node",
                selection: Binding(get: { nodeChoiceSelection }, set: { applyNodeChoice($0) })
            ) {
                // The shipped default node is a mainnet node.
                if settingsViewModel.settings.networkType == .mainnet || nodeChoiceSelection == .defaultNode {
                    Text("Default (Recommended)").tag(NodeChoice.defaultNode)
                }
                Text("Automatic Scan").tag(NodeChoice.automatic)
                ForEach(settingsViewModel.settings.savedNodeAddresses) { entry in
                    Text(entry.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? entry.address : entry.label)
                        .tag(NodeChoice.saved(entry.address))
                }
                if case .custom(let address) = nodeChoiceSelection {
                    Text(address).tag(NodeChoice.custom(address))
                }
            }

            if let trustedNodeValidationError {
                Text(trustedNodeValidationError)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if !settingsViewModel.settings.trustedNodeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Connected only to this node")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
        } header: {
            Text("Kaspa Node")
        }

        Section {
            TextField("Label (optional)", text: $newSavedNodeLabel)
                .autocapitalization(.words)

            HStack {
                TextField("host:port or grpcs://host", text: $newSavedNodeAddress)
                    .font(.system(.body, design: .monospaced))
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onChange(of: newSavedNodeAddress) { _ in
                        savedNodeAddressError = nil
                    }

                Button {
                    addSavedNodeAddress()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.accentColor)
                }
                .disabled(newSavedNodeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let savedNodeAddressError {
                Text(savedNodeAddressError)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if settingsViewModel.settings.savedNodeAddresses.isEmpty {
                Text("No saved addresses")
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                ForEach(settingsViewModel.settings.savedNodeAddresses) { entry in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            if !entry.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(entry.label)
                                Text(entry.address)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                            } else {
                                Text(entry.address)
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            UIPasteboard.general.string = entry.address
                            Haptics.success()
                            showToast("Node address copied.")
                        }

                        Button {
                            deleteSavedNodeAddress(entry)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete saved address")
                    }
                }
                .onDelete { indexSet in
                    settingsViewModel.settings.savedNodeAddresses.remove(atOffsets: indexSet)
                    settingsViewModel.saveSettings()
                }
            }
        } header: {
            Text("IP Address Book")
        }
    }

    @ViewBuilder
    private var domainsSections: some View {
        // .kachat first: it is what every address field resolves before anything else. Names are
        // read through this indexer when it serves this network's registry and keeps up, else
        // straight from the chain (`KachatNamesRegistry.chooseSource`).
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(".kachat Indexer URL")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField(indexerPlaceholder(AppSettings.defaultIndexerURL), text: $indexerURL)
                    .font(.system(.body, design: .monospaced))
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                httpsInlineError(for: indexerURL)
            }
            HStack {
                Text("Reading names from")
                Spacer()
                kachatSourceLabel
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .task { await kachatRegistry.refreshIfStale() }
        } header: {
            Text(".kachat Names")
        }
        // The other name services this app reads (see `NameServicesClient`). Shown, not
        // editable. The .kas URL had no empty-string fallback, so saving it blank wrote "" and
        // every lookup then failed with an unsupported-URL error until it was typed back in. It
        // now follows the selected network.
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: ".kas")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(settingsViewModel.knsBaseURL)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            ForEach([NameServiceTLD.k, .kaspa], id: \.self) { tld in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: tld.suffix)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(tld.apiBaseURL(for: settingsViewModel.settings.networkType) ?? String(localized: "Not available on this network"))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Other Domains")
        }
    }

    /// The .kachat names source `KachatNamesRegistry` last chose.
    @ViewBuilder
    private var kachatSourceLabel: some View {
        if !KachatNamesService.isLaunched {
            Text("Not live on this network")
        } else {
            switch kachatRegistry.source {
            case .indexer(let base):
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Indexer")
                    Text(verbatim: URLComponents(string: base)?.host ?? base)
                        .font(.caption)
                }
            case .chain:
                VStack(alignment: .trailing, spacing: 2) {
                    Text("The chain")
                    Text("Indexer not usable right now")
                        .font(.caption)
                }
            case nil:
                if kachatRegistry.isRefreshing {
                    ProgressView()
                } else {
                    Text(kachatRegistry.lastError == nil ? "Checking..." : "Couldn't check")
                }
            }
        }
    }

    @ViewBuilder
    private var explorerSections: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Kaspa REST API URL")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField(AppSettings.defaultKaspaRestURL(for: settingsViewModel.settings.networkType), text: $kaspaRestAPIURL)
                    .font(.system(.body, design: .monospaced))
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                httpsInlineError(for: kaspaRestAPIURL)
            }
        } header: {
            Text("Kaspa Explorer API")
        }

    }

    /// The field hint: the network's default (testnet has none).
    private func indexerPlaceholder(_ mainnetDefault: String) -> String {
        settingsViewModel.settings.networkType == .mainnet
            ? mainnetDefault
            : "None - enter an indexer URL"
    }

    /// One tab per kind of connection, so the page stays short: push registration, the Kaspa
    /// node, name services, the block explorer.
    private enum ConnectionTab: String, CaseIterable {
        case push, node, domains, explorer

        var title: String {
            switch self {
            case .push: return "Push"
            case .node: return "Node"
            case .domains: return "Domains"
            case .explorer: return "Explorer"
            }
        }
    }

    @State private var selectedTab: ConnectionTab = .push

    var body: some View {
        VStack(spacing: 0) {
            UnderlineTabBar(
                tabs: ConnectionTab.allCases.map { (tab: $0, title: $0.title) },
                selection: $selectedTab
            )
            // Save covers every tab: the fields keep their edits while you switch between them.
            Form {
                switch selectedTab {
                case .push: pushSections
                case .node: nodeSections
                case .domains: domainsSections
                case .explorer: explorerSections
                }
            }
        }
        .navigationTitle("Connection Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if saveSettings() {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            loadCurrentSettings()
        }
        .toast(message: toastMessage, style: toastStyle)
    }

    private func showToast(_ message: String, style: ToastStyle = .success) {
        let token = UUID()
        toastToken = token
        toastStyle = style
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }

    /// Removes one IP Address Book entry (trash icon on its row). Deliberately does NOT touch
    /// the node selection: deleting the entry for the currently-pinned node keeps the pin (the
    /// picker then shows it as a custom address), matching the existing rule that the picker
    /// always reflects the real connection state - the toast tells the user which case they hit.
    private func deleteSavedNodeAddress(_ entry: SavedNodeAddress) {
        let entryAddress = entry.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let pinnedAddress = settingsViewModel.settings.trustedNodeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsViewModel.settings.savedNodeAddresses.removeAll { $0.id == entry.id }
        settingsViewModel.saveSettings()
        Haptics.success()
        if !pinnedAddress.isEmpty && pinnedAddress == entryAddress {
            showToast("Removed from address book. Still connected to this node.")
        } else {
            showToast("Address removed.")
        }
    }

    private func addSavedNodeAddress() {
        let trimmedAddress = newSavedNodeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else { return }
        guard Endpoint(url: trimmedAddress) != nil else {
            savedNodeAddressError = "Enter as host:port or grpcs://host"
            return
        }
        savedNodeAddressError = nil
        let trimmedLabel = newSavedNodeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsViewModel.settings.savedNodeAddresses.append(
            SavedNodeAddress(label: trimmedLabel, address: trimmedAddress)
        )
        settingsViewModel.saveSettings()
        newSavedNodeLabel = ""
        newSavedNodeAddress = ""
    }

    private func loadCurrentSettings() {
        indexerURL = settingsViewModel.settings.indexerURL
        pushIndexerURL = settingsViewModel.settings.pushIndexerURL
        kaspaRestAPIURL = settingsViewModel.settings.kaspaRestAPIURL
    }

    /// Persists the endpoint fields, or returns false without saving anything when any field
    /// still holds an http:// value (its inline error is already visible; a toast repeats the
    /// reason so the refusal can't be missed). Non-empty scheme-less values are normalized to
    /// A blank field means "use the default", never an empty URL.
    private func normalizedOrDefault(_ value: String, _ fallback: String) -> String {
        let normalized = normalizedHTTPSURL(value)
        return normalized.isEmpty ? fallback : normalized
    }

    /// https:// (Decision 3A).
    @discardableResult
    private func saveSettings() -> Bool {
        let allFields = [indexerURL, pushIndexerURL, kaspaRestAPIURL]
        guard !allFields.contains(where: isCleartextHTTP) else {
            showToast(Self.httpsRequiredError, style: .error)
            return false
        }
        // Every field falls back to its default when left blank. Two of these already did; the
        // rest wrote "" straight through, and an empty base URL builds a scheme-less URL that
        // URLSession rejects with -1002 - which is exactly how the KNS endpoint got wiped, with
        // no error anywhere pointing at the setting that caused it.
        // Blank falls back to the network's default rather than being written through - an
        // empty base URL builds a request that fails as "unsupported URL" and reads as the
        // server being down, which is exactly how the KNS field broke.
        let defaults = ConnectionProfile.defaults(for: settingsViewModel.settings.networkType)
        let previousIndexer = settingsViewModel.settings.indexerURL
        settingsViewModel.settings.indexerURL = normalizedOrDefault(indexerURL, defaults.indexerURL)
        settingsViewModel.settings.pushIndexerURL = normalizedOrDefault(pushIndexerURL, defaults.pushIndexerURL)
        settingsViewModel.settings.kaspaRestAPIURL = normalizedOrDefault(kaspaRestAPIURL, defaults.kaspaRestAPIURL)
        settingsViewModel.saveSettings()
        // A new .kachat indexer: check it at once (the refresh re-chooses the source) instead of
        // on the next scheduled refresh.
        if settingsViewModel.settings.indexerURL != previousIndexer {
            Task { await KachatNamesRegistry.shared.refresh() }
        }
        return true
    }

    private enum NodeChoice: Hashable {
        case automatic
        case defaultNode
        case saved(String)
        /// A trusted node address that's currently active but matches neither the default nor any
        /// saved address book entry (e.g. a one-off address typed into the field below) - shown so
        /// the picker always reflects the real current state instead of misrepresenting it.
        case custom(String)
    }

    private var normalizedDefaultAddress: String {
        AppSettings.defaultTrustedNodeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nodeChoiceSelection: NodeChoice {
        let normalizedTrustedAddress = settingsViewModel.settings.trustedNodeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedTrustedAddress.isEmpty {
            return .automatic
        }
        if normalizedTrustedAddress == normalizedDefaultAddress {
            return .defaultNode
        }
        if let match = settingsViewModel.settings.savedNodeAddresses.first(where: {
            $0.address.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedTrustedAddress
        }) {
            return .saved(match.address)
        }
        return .custom(normalizedTrustedAddress)
    }

    private func applyNodeChoice(_ choice: NodeChoice) {
        let address: String
        switch choice {
        case .automatic: address = ""
        case .defaultNode: address = AppSettings.defaultTrustedNodeAddress
        case .saved(let addr): address = addr
        case .custom(let addr): address = addr
        }
        trustedNodeValidationError = settingsViewModel.applyTrustedNode(address)
    }
}

// MARK: - Kaspa Node (quick access from Connection Status)

/// A single dropdown for picking which node to connect to, right from the connection status
/// sheet (tap the status dot) without navigating to Settings > Connection Settings: the default
/// node (recommended), automatic discovery, or any address already saved in the IP Address Book
/// there. Managing the address book itself (adding/removing/labeling entries) still lives in
/// `ConnectionSettingsView` - this is a quick-select surface over that same underlying list, not
/// a duplicate of it.
struct KaspaNodeQuickAccessSections: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    var onToast: (String, ToastStyle) -> Void

    private enum NodeChoice: Hashable {
        case automatic
        case defaultNode
        case saved(String)
        /// A trusted node address that's currently active but matches neither the default nor any
        /// saved address book entry (e.g. entered as free text in Settings > Connection Settings) -
        /// shown so the picker always reflects the real current state instead of silently
        /// misrepresenting it as "Automatic Scan".
        case custom(String)
    }

    private var normalizedTrustedAddress: String {
        settingsViewModel.settings.trustedNodeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedDefaultAddress: String {
        AppSettings.defaultTrustedNodeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selection: NodeChoice {
        if normalizedTrustedAddress.isEmpty {
            return .automatic
        }
        if normalizedTrustedAddress == normalizedDefaultAddress {
            return .defaultNode
        }
        if let match = settingsViewModel.settings.savedNodeAddresses.first(where: {
            $0.address.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedTrustedAddress
        }) {
            return .saved(match.address)
        }
        return .custom(normalizedTrustedAddress)
    }

    var body: some View {
        Section {
            Picker(
                "Kaspa Node",
                selection: Binding(get: { selection }, set: { apply($0) })
            ) {
                // The shipped default node is a mainnet node.
                if settingsViewModel.settings.networkType == .mainnet || selection == .defaultNode {
                    Text("Default (Recommended)").tag(NodeChoice.defaultNode)
                }
                Text("Automatic Scan").tag(NodeChoice.automatic)
                ForEach(settingsViewModel.settings.savedNodeAddresses) { entry in
                    Text(entry.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? entry.address : entry.label)
                        .tag(NodeChoice.saved(entry.address))
                }
                if case .custom(let address) = selection {
                    Text(address)
                        .tag(NodeChoice.custom(address))
                }
            }

            if case .automatic = selection {
                // No extra row - automatic discovery is the default connection mode.
            } else {
                HStack {
                    Text("Connected only to this node")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                    Spacer()
                }
            }
        } header: {
            Text("Kaspa Node")
        }
    }

    private func apply(_ choice: NodeChoice) {
        let address: String
        switch choice {
        case .automatic: address = ""
        case .defaultNode: address = AppSettings.defaultTrustedNodeAddress
        case .saved(let addr): address = addr
        case .custom(let addr): address = addr
        }
        if let error = settingsViewModel.applyTrustedNode(address) {
            onToast(error, .error)
        } else {
            onToast(choice == .automatic ? "Automatic scan enabled." : "Node updated.", .success)
        }
    }
}

// MARK: - Connection Status Indicator

struct ConnectionStatusIndicator: View {
    @EnvironmentObject var walletService: WalletService
    @State private var showDetail = false
    /// Red is reserved for SUSTAINED disconnection. `.disconnected` is also what the status
    /// reads at cold start before the first subscribe and in the gaps between reconnect
    /// attempts, and flashing red there tells the user they're offline when they aren't -
    /// those windows show orange until the state has persisted for the grace period.
    @State private var disconnectedSince: Date?
    @State private var disconnectGraceElapsed = false
    private static let disconnectGrace: TimeInterval = 8

    var body: some View {
        Button {
            showDetail = true
        } label: {
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)
                .overlay(
                    Circle()
                        .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                )
        }
        .sheet(isPresented: $showDetail) {
            // A full-height sheet, not a detented one: this is a page. It is still an OVERLAY
            // over whatever you were reading rather than a push, so Done puts you back exactly
            // where you were, from any of the fourteen places the dot appears.
            ConnectionStatusDetailView()
        }
        .onAppear { syncDisconnectedAnchor() }
        .onChange(of: walletService.connectionStatus) { _ in syncDisconnectedAnchor() }
        .task(id: disconnectedSince) {
            disconnectGraceElapsed = false
            guard let since = disconnectedSince else { return }
            let remaining = Self.disconnectGrace - Date().timeIntervalSince(since)
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            if !Task.isCancelled, walletService.connectionStatus == .disconnected {
                disconnectGraceElapsed = true
            }
        }
    }

    private func syncDisconnectedAnchor() {
        if walletService.connectionStatus == .disconnected {
            if disconnectedSince == nil { disconnectedSince = Date() }
        } else {
            disconnectedSince = nil
        }
    }

    private var statusColor: Color {
        switch walletService.connectionStatus {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected:
            return disconnectGraceElapsed ? .red : .orange
        }
    }
}

/// Kaspa-logo balance of the whole hot wallet (`HotWalletBalance`) for navigation bars - shared by
/// the main pages (Cold Storage, Portfolio, Address Book, .kachat) so the centered header reads
/// identically across tabs.
struct BalanceToolbarLabel: View {
    @EnvironmentObject var walletManager: WalletManager
    @ObservedObject private var hotWallet = HotWalletBalance.shared

    private var amountText: String {
        hotWallet.totalSompi(for: walletManager.currentWallet)
            .map { String(format: "%.8f", Double($0) / 100_000_000.0) } ?? "--"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image("KaspaLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 15, height: 15)
            Text(verbatim: "\(amountText) \(KaspaUnit.symbol)")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
        .task {
            _ = try? await walletManager.refreshBalance()
        }
        .task(id: walletManager.currentWallet?.publicAddress) {
            await hotWallet.refreshUntilKnown()
        }
    }
}

// MARK: - Connection Status Detail View

struct ConnectionStatusDetailView: View {
    @EnvironmentObject var walletService: WalletService
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @StateObject private var nodePool = NodePoolService.shared
    // Node + latency moved off WalletService to stop 2s ticks re-rendering the whole app;
    // this screen watches them directly so it still updates live.
    @ObservedObject private var nodeInfo = NodeConnectionInfo.shared
    @Environment(\.dismiss) private var dismiss

    @State private var isReconnecting: Bool = false
    @State private var nodeRecords: [NodeRecord] = []
    @State private var showClearPoolConfirm: Bool = false
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success

    var body: some View {
        NavigationStack {
            // Each section is its own expression. As one Form the body was 330 lines the
            // type checker solved in a single go, and it stopped finishing ("unable to
            // type-check this expression in reasonable time").
            Form {
                statusSection
                poolStatisticsSection
                actionsSection
                KaspaNodeQuickAccessSections(onToast: showToast)
                nodeListSections
            }
            .alert("Clear connection pool?", isPresented: $showClearPoolConfirm) {
                Button("Clear", role: .destructive) {
                    Task {
                        await nodePool.clearConnectionPool()
                        await reconnect()
                        await reloadNodeRecords()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes discovered nodes, disconnects current sessions, and restarts discovery.")
            }
            .toast(message: toastMessage, style: toastStyle)
            .navigationTitle("Connection Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
                .task {
                    await refreshNodeRecordsContinuously()
                }
        }
    }

    /// Status, protocol, and the warnings that qualify them.
    @ViewBuilder
    private var statusSection: some View {
        // Status Section
        Section {
            HStack {
                Text("Status")
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    Text(walletService.connectionStatus.description)
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Text("Protocol")
                Spacer()
                Text("\(nodePool.activeProtocol) (\(nodePool.activeProtocolSecurity))")
                    .foregroundColor(.secondary)
            }

            if nodePool.nodeNetworkBlockedSuspected {
                HStack {
                    Text("Node Network")
                    Spacer()
                    Text("Blocked")
                        .foregroundColor(.orange)
                }
                Text("Node connections appear blocked on this network. Balances and history still load through the Kaspa REST API, but sending needs a node connection.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let node = nodeInfo.currentConnectedNode {
                HStack {
                    Text("Connected Node")
                    Spacer()
                    Text(extractHost(from: node))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            if let latency = nodeInfo.currentNodeLatencyMs {
                HStack {
                    Text("Latency")
                    Spacer()
                    Text("\(latency) ms")
                        .foregroundColor(latencyColor(latency))
                }
            }

            // Connected node geo info
            if let record = connectedNodeRecord {
                if let distKm = record.profile.geoDistanceKm {
                    HStack {
                        Text("Distance")
                        Spacer()
                        Text(formatDistance(distKm))
                            .foregroundColor(.secondary)
                    }
                }
                if let cc = record.profile.countryCode {
                    HStack {
                        Text("Country")
                        Spacer()
                        Text(cc)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Indexer endpoint
            HStack {
                Text("Indexer")
                Spacer()
                Text(extractHost(from: settingsViewModel.settings.indexerURL))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            // Push register endpoint (only if different from indexer)
            if settingsViewModel.settings.pushIndexerURL != settingsViewModel.settings.indexerURL {
                HStack {
                    Text("Push Register")
                    Spacer()
                    Text(extractHost(from: settingsViewModel.settings.pushIndexerURL))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            HStack {
                Text("Last Sync")
                Spacer()
                Text(lastSyncText)
                    .foregroundColor(lastSyncColor)
            }
        } header: {
            Text("Connection Status")
        }
    }

    /// Only meaningful under automatic node selection - see the note inside.
    @ViewBuilder
    private var poolStatisticsSection: some View {

        // Pool Statistics Section - only meaningful under automatic node
        // selection, where the gRPC pool is actually picking nodes. When the
        // user is pinned to the default or a custom node, the registry holds
        // just that one node and pool health/counters are noise, so hide them.
        if isAutomaticNodeSelection {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("Active")
                            .font(.caption)
                    }
                    Text("\(nodePool.activeCount)")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.green)
                }
                Spacer()
                VStack(alignment: .center, spacing: 2) {
                    HStack(spacing: 4) {
                        Circle().fill(.blue).frame(width: 8, height: 8)
                        Text("Verified")
                            .font(.caption)
                    }
                    Text("\(nodePool.verifiedCount)")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.blue)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Circle().fill(.gray).frame(width: 8, height: 8)
                        Text("Total")
                            .font(.caption)
                    }
                    Text("\(nodePool.totalNodeCount)")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)

            HStack {
                Text("Pool Health")
                Spacer()
                Text(poolHealthDescription)
                    .foregroundColor(poolHealthColor)
            }
        } header: {
            Text("Pool Status")
        }
        }
    }

    /// Refresh Pool, Clear Pool, Reconnect, and the way into Connection Settings.
    @ViewBuilder
    private var actionsSection: some View {
        // Actions Section (pool refresh/clear only apply in automatic mode;
        // Reconnect is useful in every mode)
        Section {
            if isAutomaticNodeSelection {
                Button {
                    Task {
                        await nodePool.refreshPool()
                    }
                } label: {
                    HStack {
                        Text("Refresh Pool")
                        Spacer()
                        if nodePool.isRefreshing {
                            ProgressView()
                        }
                    }
                }
                .disabled(nodePool.isRefreshing || isReconnecting)

                Button(role: .destructive) {
                    showClearPoolConfirm = true
                } label: {
                    Text("Clear Connection Pool")
                }
                .disabled(nodePool.isRefreshing || isReconnecting)
            }

            Button {
                Task {
                    await reconnect()
                }
            } label: {
                HStack {
                    Text("Reconnect")
                    Spacer()
                    if isReconnecting {
                        ProgressView()
                    }
                }
            }
            .disabled(nodePool.isRefreshing || isReconnecting)

            NavigationLink {
                ConnectionSettingsView()
            } label: {
                Text("Connection Settings")
            }
        } header: {
            Text("Actions")
        } footer: {
            if let endpoint = nodePool.primaryEndpoint {
                Text("Primary: \(endpoint.host)")
            }
        }
    }

    /// Active Nodes and All Nodes, automatic mode only.
    @ViewBuilder
    private var nodeListSections: some View {
        // Node lists only make sense when the pool is discovering nodes;
        // in pinned mode there is nothing here but the pinned node itself.
        if isAutomaticNodeSelection {
        // Active Nodes Section
        Section {
            let activeNodes = nodeRecords.filter { $0.state == .active }
            if activeNodes.isEmpty {
                Text("No active nodes")
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                ForEach(activeNodes) { record in
                    ConnectionNodeRow(
                        record: record,
                        isConnected: record.endpoint.url == nodeInfo.currentConnectedNode
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        UIPasteboard.general.string = record.endpoint.key
                        Haptics.success()
                        showToast("Node endpoint copied.")
                    }
                }
            }
        } header: {
            HStack {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Active Nodes")
                Spacer()
                Text("\(nodePool.activeCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }

        // All Nodes Section
        Section {
            let sortedNodes = nodeRecords.sorted { a, b in
                // Sort by state priority: active > verified > profiled > candidate > suspect > quarantined
                if a.state.rawValue != b.state.rawValue {
                    return a.state.rawValue > b.state.rawValue
                }
                // Then by latency (lower is better)
                let aLatency = a.health.latencyMs.value ?? a.health.globalLatencyMs.value ?? 9999
                let bLatency = b.health.latencyMs.value ?? b.health.globalLatencyMs.value ?? 9999
                return aLatency < bLatency
            }

            if sortedNodes.isEmpty {
                Text("No nodes discovered")
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                ForEach(sortedNodes) { record in
                    AllNodesRow(record: record)
                }
            }
        } header: {
            HStack {
                Image(systemName: "server.rack")
                    .font(.caption)
                Text("All Nodes")
                Spacer()
                Text("\(nodeRecords.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        }
    }

    /// True when node selection is Automatic Scan (empty trusted node address), i.e. the
    /// gRPC node pool is actually discovering and picking nodes. A non-empty address
    /// (default recommended node, a saved entry, or free-text custom) pins the app to
    /// that single node via NodeRegistry.setTrustedNode, so pool status is meaningless.
    private var isAutomaticNodeSelection: Bool {
        settingsViewModel.settings.trustedNodeAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private var poolHealthDescription: String {
        switch nodePool.poolHealth {
        case .healthy: return "Healthy"
        case .degraded: return "Degraded"
        case .critical: return "Critical"
        case .failed: return "Failed"
        }
    }

    private var poolHealthColor: Color {
        switch nodePool.poolHealth {
        case .healthy: return .green
        case .degraded: return .orange
        case .critical: return .red
        case .failed: return .red
        }
    }

    private var statusColor: Color {
        switch walletService.connectionStatus {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected:
            return .red
        }
    }

    private var connectedNodeRecord: NodeRecord? {
        guard let primary = nodePool.primaryEndpoint else { return nil }
        return nodeRecords.first { $0.endpoint.key == primary.key }
    }

    private var lastSyncText: String {
        if let lastSync = walletService.lastSuccessfulSyncDate {
            return formatDate(lastSync)
        }
        return "Never"
    }

    private var lastSyncColor: Color { .secondary }

    private func extractHost(from url: String) -> String {
        if url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "None" }
        guard let urlComponents = URLComponents(string: url),
              let host = urlComponents.host else {
            return url
        }
        return host
    }

    private func latencyColor(_ latency: Int) -> Color {
        if latency < 100 {
            return .green
        } else if latency < 200 {
            return .primary
        } else if latency < 500 {
            return .orange
        } else {
            return .red
        }
    }

    private func formatDistance(_ km: Double) -> String {
        if km < 100 {
            return "\(Int(km)) km"
        } else {
            let thousands = km / 1000
            return String(format: "%.1fk km", thousands)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func showToast(_ message: String, style: ToastStyle = .success) {
        let token = UUID()
        toastToken = token
        toastStyle = style
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }

    private func reconnect() async {
        isReconnecting = true
        defer { isReconnecting = false }

        let settings = AppSettings.load()

        AppLog.log("[ConnectionStatus] Starting reconnect via NodePoolService...")

        // Disconnect current subscription
        nodePool.disconnect()

        // Small delay to ensure clean disconnect
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Reconnect via node pool
        do {
            try await nodePool.connect(network: settings.networkType)
            AppLog.log("[ConnectionStatus] Connected via NodePool, activeNodes=%d",
                  nodePool.activeNodeCount)

            // Small delay to let connections stabilize
            try? await Task.sleep(nanoseconds: 200_000_000)

            // Re-setup subscriptions
            AppLog.log("[ConnectionStatus] Setting up subscriptions...")
            await walletService.setupUtxoSubscriptionAfterReconnect()
            AppLog.log("[ConnectionStatus] Subscription setup complete, isSubscribed=%@",
                  walletService.isRpcSubscribed ? "true" : "false")

            // Refresh node list
            await reloadNodeRecords()
        } catch {
            AppLog.log("[ConnectionStatus] Reconnect failed: %@", error.localizedDescription)
        }
    }

    private func reloadNodeRecords() async {
        nodeRecords = await nodePool.allNodeRecords()
    }

    private func refreshNodeRecordsContinuously() async {
        await reloadNodeRecords()

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { break }
            await reloadNodeRecords()
        }
    }
}

// MARK: - Connection Node Row (POOLS_v2)

private struct ConnectionNodeRow: View {
    let record: NodeRecord
    let isConnected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // Connection indicator
                if isConnected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                }

                // Origin indicator
                switch record.origin {
                case .userAdded:
                    Image(systemName: "star.fill")
                        .foregroundColor(.yellow)
                        .font(.caption)
                case .seed:
                    Image(systemName: "shield.fill")
                        .foregroundColor(.blue)
                        .font(.caption)
                case .discovered:
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }

                Text(verbatim: record.endpoint.key)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)

                Spacer()

                Text(record.state.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(stateColor.opacity(0.2))
                    .foregroundColor(stateColor)
                    .clipShape(Capsule())
            }

            HStack(spacing: 8) {
                // Origin label
                Text(record.origin.displayName)
                    .font(.caption2)
                    .foregroundColor(originColor)

                // Latency
                if let latency = record.health.latencyMs.value ?? record.health.globalLatencyMs.value {
                    Text("\(Int(latency))ms")
                        .font(.caption)
                        .foregroundColor(latencyColor(Int(latency)))
                }

                // Geo distance
                if let distKm = record.profile.geoDistanceKm {
                    Text(formatDistance(distKm))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Country code
                if let cc = record.profile.countryCode {
                    Text(cc)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // DPI check failed
                if record.profile.peerInfoOk == false {
                    HStack(spacing: 2) {
                        Image(systemName: "network.slash")
                            .font(.caption2)
                        Text("DPI")
                            .font(.caption2)
                    }
                    .foregroundColor(.red)
                }

                // Success/failure counts
                if record.health.consecutiveSuccesses > 0 {
                    Text("\(record.health.consecutiveSuccesses)✓")
                        .font(.caption)
                        .foregroundColor(.green)
                }
                if record.health.consecutiveFailures > 0 {
                    Text("\(record.health.consecutiveFailures)✗")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                Spacer()

                // DAA score (if available)
                if let daa = record.profile.virtualDaaScore {
                    Text("DAA: \(formatDaa(daa))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var stateColor: Color {
        switch record.state {
        case .active: return .green
        case .verified: return .blue
        case .profiled: return .orange
        case .candidate: return .gray
        case .suspect: return .red
        case .quarantined: return .red
        }
    }

    private var originColor: Color {
        switch record.origin {
        case .userAdded: return .yellow
        case .seed: return .blue
        case .discovered: return .secondary
        }
    }

    private func latencyColor(_ latency: Int) -> Color {
        if latency < 100 {
            return .green
        } else if latency < 200 {
            return .primary
        } else if latency < 500 {
            return .orange
        } else {
            return .red
        }
    }

    private func formatDaa(_ daa: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: daa)) ?? "\(daa)"
    }

    private func formatDistance(_ km: Double) -> String {
        if km < 100 {
            return "\(Int(km))km"
        } else {
            let thousands = km / 1000
            return String(format: "%.1fk km", thousands)
        }
    }
}

// MARK: - All Nodes Row (Compact)

private struct AllNodesRow: View {
    let record: NodeRecord

    var body: some View {
        HStack(spacing: 8) {
            // State indicator
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)

            // Origin indicator
            switch record.origin {
            case .userAdded:
                Image(systemName: "star.fill")
                    .foregroundColor(.yellow)
                    .font(.caption2)
            case .seed:
                Image(systemName: "shield.fill")
                    .foregroundColor(.blue)
                    .font(.caption2)
            case .discovered:
                EmptyView()
            }

            // Host:port
            Text(verbatim: "\(record.endpoint.host):\(record.endpoint.port)")
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)

            Spacer()

            // Country code
            if let cc = record.profile.countryCode {
                Text(cc)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Geo distance
            if let distKm = record.profile.geoDistanceKm {
                Text(formatDistance(distKm))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // DPI check failed
            if record.profile.peerInfoOk == false {
                Image(systemName: "network.slash")
                    .font(.caption2)
                    .foregroundColor(.red)
            }

            // Latency
            if let latency = record.health.latencyMs.value ?? record.health.globalLatencyMs.value {
                Text("\(Int(latency))ms")
                    .font(.caption2)
                    .foregroundColor(latencyColor(Int(latency)))
            }

            // State badge
            Text(record.state.displayName)
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(stateColor.opacity(0.2))
                .foregroundColor(stateColor)
                .clipShape(Capsule())
        }
        .padding(.vertical, 2)
    }

    private var stateColor: Color {
        switch record.state {
        case .active: return .green
        case .verified: return .blue
        case .profiled: return .orange
        case .candidate: return .gray
        case .suspect: return .red
        case .quarantined: return .red
        }
    }

    private func latencyColor(_ latency: Int) -> Color {
        if latency < 100 {
            return .green
        } else if latency < 200 {
            return .primary
        } else if latency < 500 {
            return .orange
        } else {
            return .red
        }
    }

    private func formatDistance(_ km: Double) -> String {
        if km < 100 {
            return "\(Int(km))km"
        } else {
            let thousands = km / 1000
            return String(format: "%.1fk km", thousands)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(WalletManager.shared)
        .environmentObject(SettingsViewModel())
        .environmentObject(PushNotificationManager.shared)
        .environmentObject(WalletService.shared)
}

/// Settings > Storage > Nextcloud: connect the user's own Nextcloud server, and back Contacts and
/// the Portfolio up to it. Credentials are verified against the OCS user endpoint before
/// being stored in the Keychain (see NextcloudService).
struct NextcloudSettingsView: View {
    @ObservedObject private var service = NextcloudService.shared

    @State private var serverInput = ""
    @State private var usernameInput = ""
    @State private var appPasswordInput = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var showDisconnectConfirm = false
    @State private var backupInfo = NextcloudService.BackupInfo()
    @State private var isBackingUp = false
    @State private var showBackupFolderPicker = false
    @State private var backupStatusMessage: String?
    @State private var backupErrorMessage: String?

    private var canConnect: Bool {
        !serverInput.trimmingCharacters(in: .whitespaces).isEmpty
            && !usernameInput.trimmingCharacters(in: .whitespaces).isEmpty
            && !appPasswordInput.trimmingCharacters(in: .whitespaces).isEmpty
            && !isConnecting
    }

    var body: some View {
        if service.isOffForTestnet {
            // Mainnet-only (see NextcloudService.isOffForTestnet): nothing to set up here, and
            // the mainnet connection is waiting, untouched, for the next mainnet launch.
            Form {
                Section {
                    Label("Nextcloud is off while Testnet is on.", systemImage: "icloud.slash")
                }
            }
        } else {
            nextcloudForm
        }
    }

    private var nextcloudForm: some View {
        // One concrete container (NOT a Group): the presentation modifiers below must attach to
        // a single view. On a Group they replicate onto every child Section.
        Form {
            if let account = service.account {
                Section("Connected Account") {
                    HStack {
                        Text("Server")
                        Spacer()
                        Text(account.serverURL?.host ?? account.serverURLString)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack {
                        Text("Username")
                        Spacer()
                        Text(account.username)
                            .foregroundColor(.secondary)
                    }
                }
                if service.needsReconnect {
                    Section {
                        Text("Nextcloud refused this login. Disconnect, then connect again with a new app password.")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                Section {
                    Toggle("Automatic Sync", isOn: Binding(
                        get: { service.autoBackupEnabled },
                        set: { service.setAutoBackupEnabled($0) }
                    ))

                    if let lastSynced = service.lastAutoSyncAt {
                        HStack {
                            Text("Last synced")
                            Spacer()
                            Text(lastSynced.formatted(date: .abbreviated, time: .shortened))
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }

                    Button {
                        showBackupFolderPicker = true
                    } label: {
                        HStack {
                            Text("Backup Folder")
                                .foregroundColor(.primary)
                            Spacer()
                            Text(account.backupFolder.map { $0.isEmpty ? AppLocalization.string("All Files") : $0 }
                                 ?? "\(NextcloudService.backupFolderName) (default)")
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }

                    Button {
                        backUp(success: "Contacts backed up.") {
                            try await NextcloudService.shared.runContactsBackup()
                        }
                    } label: {
                        HStack {
                            Label("Back Up Contacts Now", systemImage: "arrow.up.doc")
                            Spacer()
                            if isBackingUp { ProgressView() }
                        }
                    }
                    .disabled(isBackingUp)

                    lastBackupRow(backupInfo.contacts)
                } header: {
                    Text("Contact Backup")
                } footer: {
                    Text("Your contacts are backed up here, encrypted, in the same file KaChat uses.")
                }

                Section {
                    Button {
                        backUp(success: "Portfolio backed up.") {
                            try await NextcloudService.shared.runPortfolioBackup()
                        }
                    } label: {
                        HStack {
                            Label("Back Up Portfolio Now", systemImage: "arrow.up.doc")
                            Spacer()
                            if isBackingUp { ProgressView() }
                        }
                    }
                    .disabled(isBackingUp)

                    lastBackupRow(backupInfo.portfolio)
                } header: {
                    Text("Portfolio Backup")
                } footer: {
                    Text("Each portfolio has its own file, named after it, encrypted with this account's key.")
                }

                if backupStatusMessage != nil || backupErrorMessage != nil {
                    Section {
                        if let backupStatusMessage {
                            Text(backupStatusMessage)
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                        if let backupErrorMessage {
                            Text(backupErrorMessage)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }

                Section {
                    Button("Disconnect", role: .destructive) {
                        showDisconnectConfirm = true
                    }
                }
            } else {
                Section {
                    TextField("cloud.example.com", text: $serverInput)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    // https-only. Bare hostnames are fine (normalizedServerURL defaults them to
                    // https); an explicit http:// is rejected inline here and again in connect().
                    if serverInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://") {
                        Text("Use https. Unencrypted connections are not supported.")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    TextField("Username", text: $usernameInput)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    RevealableSecureField("App password", text: $appPasswordInput)
                } header: {
                    Text("Server")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                Section {
                    Button {
                        connect()
                    } label: {
                        HStack {
                            Spacer()
                            if isConnecting {
                                ProgressView()
                            } else {
                                Text("Connect")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canConnect)
                }
            }
        }
        .alert("Disconnect Nextcloud", isPresented: $showDisconnectConfirm) {
            Button("Disconnect", role: .destructive) {
                service.disconnect()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This revokes the app password on your Nextcloud and removes it from this device. Reconnecting needs a new one, and KaChat will too if it uses the same one.")
        }
        .sheet(isPresented: $showBackupFolderPicker) {
            NextcloudFolderSelectView { path in
                service.setBackupFolder(path)
                // The contacts file lives per folder: re-check what exists at the new destination.
                Task { backupInfo = await NextcloudService.shared.fetchBackupInfo() }
            }
        }
        .task(id: service.account?.serverURLString) {
            guard service.isConnected else { return }
            backupInfo = await NextcloudService.shared.fetchBackupInfo()
        }
    }

    /// Merge-on-upload: both read the server's copy first, so a manual backup can never undo another
    /// device's newer change, and it brings those changes in here.
    private func backUp(success: String, _ work: @escaping () async throws -> Void) {
        guard !isBackingUp else { return }
        isBackingUp = true
        backupStatusMessage = nil
        backupErrorMessage = nil
        Task {
            do {
                try await work()
                backupInfo = await NextcloudService.shared.fetchBackupInfo()
                backupStatusMessage = AppLocalization.string(success)
            } catch {
                backupErrorMessage = UserFacingError.message(for: error)
            }
            isBackingUp = false
        }
    }

    /// One backup file's last upload, or that it isn't on the server yet.
    @ViewBuilder
    private func lastBackupRow(_ file: NextcloudFile?) -> some View {
        if let file, let modified = file.modified {
            HStack {
                Text("Last backup")
                Spacer()
                Text("\(modified.formatted(date: .abbreviated, time: .shortened))\(file.size.map { " · \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))" } ?? "")")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        } else if file == nil {
            Text("No backup on this server yet.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func connect() {
        guard !isConnecting else { return }
        // Refuse cleartext servers outright instead of attempting a connection.
        if serverInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://") {
            errorMessage = "Use https. Unencrypted connections are not supported."
            return
        }
        isConnecting = true
        errorMessage = nil
        Task {
            do {
                try await NextcloudService.shared.connect(
                    serverInput: serverInput,
                    username: usernameInput,
                    appPassword: appPasswordInput
                )
                appPasswordInput = ""
            } catch {
                errorMessage = UserFacingError.message(for: error)
            }
            isConnecting = false
        }
    }
}

// MARK: - Cache

/// What the app is holding that it could fetch again, with a way to drop any of it.
///
/// Kept apart from the rest of Storage on purpose: the Address Book and its backup are things you
/// would miss, and this page decides what happens to things you would not.
/// Nothing here is user data - see `CacheManager` for why each category qualifies.
struct CacheSettingsPage: View {
    @StateObject private var cache = CacheManager.shared
    @State private var pendingClear: CacheManager.Category?
    @State private var showClearAllConfirm = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Total")
                        .font(.headline)
                    Spacer()
                    if cache.isMeasuring && cache.totalBytes == 0 {
                        ProgressView()
                    } else {
                        Text(CacheManager.formatted(cache.totalBytes))
                            .font(.headline)
                            .monospacedDigit()
                    }
                }
            }

            Section("What's Cached") {
                ForEach(CacheManager.Category.allCases) { category in
                    Button {
                        pendingClear = category
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: category.systemImage)
                                .font(.scaled(size: 16, weight: .semibold))
                                .foregroundColor(.accentColor)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.title)
                                    .foregroundColor(.primary)
                                Text(category.detail)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Text(CacheManager.formatted(cache.sizes[category] ?? 0))
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Nothing to clear reads better as a disabled row than as a button that
                    // opens a sheet to delete zero bytes.
                    .disabled((cache.sizes[category] ?? 0) <= 0)
                }
            }

            Section {
                Button(role: .destructive) {
                    showClearAllConfirm = true
                } label: {
                    Text("Clear All Cache")
                        .foregroundColor(.red)
                }
                .disabled(cache.totalBytes <= 0)
            }
        }
        .navigationTitle("Cache")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await cache.refreshSizes() }
        .task { await cache.refreshSizes() }
        .sheet(item: $pendingClear) { category in
            ConfirmActionSheet(
                title: "Clear \(category.title)?",
                confirmTitle: "Clear",
                confirmSubtitle: "\(CacheManager.formatted(cache.sizes[category] ?? 0)) freed. \(category.detail)",
                confirmSystemImage: "trash"
            ) {
                Task { await cache.clear(category) }
            }
        }
        .sheet(isPresented: $showClearAllConfirm) {
            ConfirmActionSheet(
                title: "Clear All Cache?",
                confirmTitle: "Clear All",
                confirmSubtitle: "Frees \(CacheManager.formatted(cache.totalBytes)). Your contacts and keys are not touched.",
                confirmSystemImage: "trash"
            ) {
                Task { await cache.clearAll() }
            }
        }
    }
}
