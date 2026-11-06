import SwiftUI
import Combine
import UserNotifications
import UIKit

struct MainTabView: View {
    @State private var selectedTab = AppTab.home.tag
    /// Debounces the off-home-tab discovery pause/resume so rapid tab-flipping can't thrash it.
    @State private var tabWorkTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    /// Not observed. This view only CALLS into these two (start polling, pending routes) and
    /// renders nothing from them; as @EnvironmentObjects every balance write would re-run the
    /// root TabView underneath whatever screen was open.
    private var walletService: WalletService { WalletService.shared }
    private var walletManager: WalletManager { WalletManager.shared }
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    /// The address a tapped "Received" notification opened (its history, in a sheet).
    @State private var ownAddressSheet: OwnAddressSheetTarget?
    // Red dot on the Wallet tab while the bell (which lives on the Wallet screen) holds unread
    // notifications.
    @ObservedObject private var notifCenter = GlobalNotificationCenter.shared
    // Surfaces the Address Book's Nextcloud backup result as a toast over whatever tab is showing.
    @ObservedObject private var nextcloudService = NextcloudService.shared

    /// The dock's TabView on its own, so `body` stays small enough for the type checker.
    private var dockTabView: some View {
        TabView(selection: tabSelection) {
            ForEach(AppTab.dock) { tab in
                tabContent(for: tab)
                    .tabItem {
                        // Single Label whose VALUES vary (no structural if) - conditional tabItem
                        // content churns the tab bar's identity on every render.
                        Label {
                            Text(tab.label)
                        } icon: {
                            // Values vary, structure does not - the comment above is why this is
                            // one Label with a varying image rather than two Labels behind an if.
                            if tab == .kachatNames {
                                // A domains logo (name tag with an "@") over the ".kachat" label.
                                Image(uiImage: KachatTabIcon.domainsImage(side: 30))
                            } else {
                                Image(systemName: tab.icon)
                            }
                        }
                    }
                    // The Wallet tab hosts the notification bell.
                    .badge(dockBadge(for: tab))
                    .tag(tab.tag)
            }
        }
        .tint(.accentColor)
    }

    var body: some View {
        dockTabView
        // the bell has something unread: Profile's dock dot, from whichever tab is showing. Its
        // own modifier: inline, these pushed the body past what the type checker can solve.
        .modifier(ProfileDockDotSync(selectedTab: selectedTab, dockTabs: AppTab.dock))
        // a .kachat registration in flight: its progress half sheet, back up after a relaunch
        .modifier(KachatRegistrationPresenter())
        .toast(message: nextcloudService.syncStatusToast)
        .onAppear {
            LaunchTrace.mark("main tabs on screen")
            walletService.startPolling()
            preloadProfileResources()
            // A notification tapped from a cold start routed before this view existed - replay
            // its tab switch now that there's something to switch.
            consumePendingNotificationRoute()
            // Warm the portfolio view model: its init fetches the price.
            _ = PortfolioViewModel.shared
            // Clears a badge an earlier build left on the icon.
            UNUserNotificationCenter.current().setBadgeCount(0)
            requestNotificationPermissionIfNeeded()
        }
        // The one thing here that reacts to the wallet: a switch of address. Subscribed to that
        // alone, rather than observing all of WalletManager for it. Uses the address the
        // publisher delivers: @Published emits before the property changes, so reading
        // `currentWallet` here would still see the previous wallet.
        .onReceive(
            WalletManager.shared.$currentWallet
                .map { $0?.publicAddress }
                .removeDuplicates()
                .dropFirst()
        ) { address in
            if let address { ProfileView.preloadQRCode(for: address) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPortfolio)) { _ in
            // Spending-address receipts: land on Portfolio.
            PendingTabRoute.pending = nil
            routeToWalletTab(.portfolio)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openKachatName)) { _ in
            // A .kachat name notification: the .kachat screen opens the name.
            PendingTabRoute.pending = nil
            routeToFeature(.kachatNames)
        }
        // Its own modifier: added to this chain inline, it pushed the body past what the type
        // checker can solve in reasonable time.
        .modifier(OwnAddressSheetPresenter(target: $ownAddressSheet, onRequest: takeOwnAddressRoute))
        // A payment request tapped or pasted anywhere: Send Kaspa with it filled in.
        .modifier(PaymentRequestSheetPresenter())
        .onReceive(NotificationCenter.default.publisher(for: .openColdStorage)) { _ in
            // Cold-storage address-activity notification tapped: the Storage tab, or the next
            // best wallet surface when it's hidden.
            PendingTabRoute.pending = nil
            routeToWalletTab(.coldStorage)
        }
    }

    /// The unread COUNT on the tabs that own one, and nothing on the rest.
    ///
    /// A bare dot said only "something happened". The number is the difference between
    /// deciding to look now and deciding to look later, and the dock is where that decision
    /// gets made - a badge with a space in it was the dot, and the space was the whole design.
    private func dockBadge(for tab: AppTab) -> Text? {
        AppTabBadge.dockLabel(for: tab).map { Text(verbatim: $0) }
    }


    @ViewBuilder
    private func tabContent(for tab: AppTab) -> some View {
        switch tab {
        case .portfolio:
            PortfolioView()
        case .coldStorage:
            NavigationStack {
                ColdStorageListView()
            }
        case .profile:
            ProfileView()
        case .kachatNames:
            KachatMarketView()
        case .settings:
            SettingsView(isDockTab: true)
        }
    }

    private var tabSelection: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                handleTabSelectionChange(newValue)
            }
        )
    }

    private func handleTabSelectionChange(_ newValue: Int) {
        selectedTab = newValue

        // Off-home-tab power saving, DEBOUNCED so rapidly flipping tabs can't thrash it. Only the
        // settled tab - after a short quiet period - pauses or resumes the node pool's discovery
        // and probe loops. The pool and the UTXO subscription stay live, so sending, balances,
        // history and push keep working; only background scanning stops.
        tabWorkTask?.cancel()
        tabWorkTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            if newValue == AppTab.home.tag {
                await NodePoolService.shared.resumeDiscovery()
            } else {
                await NodePoolService.shared.pauseDiscovery()
            }
        }
    }

    // MARK: - Notification routing

    /// Asks once, the first time the tabs show, for permission to notify. Granted (with push on,
    /// the default), the device registers with the push service for "Received" pushes on its own
    /// addresses; denied, notifications are switched off.
    private func requestNotificationPermissionIfNeeded() {
        guard !settingsViewModel.settings.notificationPermissionRequested else { return }
        settingsViewModel.settings.notificationPermissionRequested = true
        settingsViewModel.saveSettings()
        Task { @MainActor in
            do {
                if settingsViewModel.settings.notificationMode == .remotePush {
                    try await PushNotificationManager.shared.requestPermissionAndRegister()
                } else {
                    let granted = try await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .sound, .badge])
                    if !granted { throw PushError.permissionDenied }
                }
            } catch {
                settingsViewModel.settings.notificationsEnabled = false
                settingsViewModel.saveSettings()
                AppLog.log("[MainTabView] Notification permission not granted: %@", error.localizedDescription)
            }
        }
    }

    private func routeToFeature(_ feature: AppTab) {
        selectedTab = feature.tag
    }

    /// Wallet-event notifications (address activity): the tab that shows them.
    private func routeToWalletTab(_ tab: AppTab) {
        handleTabSelectionChange(tab.tag)
    }

    /// Cold-start replay of a notification tap's tab switch: the tap's NotificationCenter post
    /// is delivered before this view exists (the app is still on the loading/onboarding route),
    /// so its tab switch is lost while the pending target survives. The destination screens
    /// consume the target itself; this only puts the user on the tab that mounts them.
    /// Opens the address a tapped "Received" notification named, over whatever tab is showing.
    private func takeOwnAddressRoute() {
        guard let address = OwnAddressRoute.pending else { return }
        OwnAddressRoute.pending = nil
        ownAddressSheet = OwnAddressSheetTarget(address: address)
    }

    private func consumePendingNotificationRoute() {
        if OwnAddressRoute.pending != nil {
            takeOwnAddressRoute()
            return
        }
        if let tab = PendingTabRoute.pending {
            PendingTabRoute.pending = nil
            if tab == .kachatNames {
                routeToFeature(.kachatNames)
            } else {
                routeToWalletTab(tab)
            }
        }
    }

    private func preloadProfileResources() {
        guard let address = walletManager.currentWallet?.publicAddress else { return }
        ProfileView.preloadQRCode(for: address)
    }

}

#Preview {
    MainTabView()
        .environmentObject(WalletManager.shared)
        .environmentObject(WalletService.shared)
        .environmentObject(SettingsViewModel())
}

struct OwnAddressSheetTarget: Identifiable {
    let address: String
    var id: String { address }
}

/// One of your own addresses, opened from a tapped "Received" notification on its History tab:
/// the chatting address, a spending address or a cold-storage address, each on the same screen
/// you'd reach it through (Wallet, Manage Addresses, Cold Storage).
struct OwnAddressHistorySheet: View {
    let address: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var walletManager: WalletManager

    private enum Resolved {
        case chatting
        case spending(SpendingAddressEntry)
        case cold(ColdStorageAddressEntry)
        case unknown
        /// Its balance couldn't be read: a screen showing 0 would say it's empty, and its Send
        /// would be off.
        case unreadable
    }

    @State private var resolved: Resolved?

    var body: some View {
        NavigationStack {
            Group {
                switch resolved {
                case nil:
                    ProgressView()
                case .chatting?:
                    ChattingAddressManageView(address: address)
                case .spending(let entry)?:
                    SpendingAddressTransactionHistoryView(entry: entry)
                case .cold(let entry)?:
                    ColdStorageAddressTransactionHistoryView(entry: entry)
                case .unreadable?:
                    VStack(spacing: 14) {
                        Text("Couldn't load the coins at this address")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Try Again") {
                            resolved = nil
                            Task { resolved = await resolve() }
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    .padding()
                case .unknown?:
                    Text("This address isn't in this wallet any more.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { resolved = await resolve() }
    }

    /// Which of your addresses it is, with its balance for the screen's header.
    private func resolve() async -> Resolved {
        let target = address.lowercased()
        if walletManager.currentWallet?.publicAddress.lowercased() == target { return .chatting }
        let utxos: [UTXO]
        do {
            utxos = try await NodePoolService.shared.getUtxosByAddresses([address])
        } catch {
            return .unreadable
        }
        let balance = utxos.reduce(UInt64(0)) { $0 + $1.amount }
        var spending = walletManager.spendingAddresses(inRange: 0..<(max(0, walletManager.maxSpendingAddressIndex) + 1))
        if walletManager.maxQuantumAddressIndex >= 0 {
            let base = WalletManager.quantumIndexBase
            spending.merge(walletManager.spendingAddresses(inRange: base..<(base + walletManager.maxQuantumAddressIndex + 1))) { a, _ in a }
        }
        if let match = spending.first(where: { $0.value.lowercased() == target }) {
            return .spending(SpendingAddressEntry(
                index: match.key,
                address: match.value,
                balanceSompi: balance,
                isCurrent: match.key == walletManager.currentSpendingAddressIndex
            ))
        }
        let cold = ColdStorageManager.shared
        for account in cold.accounts {
            for index in 0...max(0, account.maxAddressIndex) {
                if let candidate = cold.address(for: account, at: index), candidate.lowercased() == target {
                    return .cold(ColdStorageAddressEntry(index: index, address: candidate, balanceSompi: balance))
                }
            }
        }
        return .unknown
    }
}

/// Presents a tapped "Received" notification's address (`OwnAddressHistorySheet`) over the tabs.
private struct OwnAddressSheetPresenter: ViewModifier {
    @Binding var target: OwnAddressSheetTarget?
    let onRequest: () -> Void
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .openOwnAddress)) { _ in
                onRequest()
            }
            .sheet(item: $target) { target in
                OwnAddressHistorySheet(address: target.address)
                    .environmentObject(WalletService.shared)
                    .environmentObject(settingsViewModel)
                    .environmentObject(WalletManager.shared)
            }
    }
}

/// Keeps the Wallet tab's dock dot in step with the bell (`AppTabBadge.syncProfileDot`): when the feed
/// changes, the tab changes, the dock is rearranged, and on appear - set after the render that
/// triggered it, so it lands on the bar SwiftUI just updated.
private struct ProfileDockDotSync: ViewModifier {
    @ObservedObject private var notifCenter = GlobalNotificationCenter.shared
    let selectedTab: Int
    let dockTabs: [AppTab]

    func body(content: Content) -> some View {
        content
            .onReceive(notifCenter.objectWillChange) { _ in sync() }
            .onChange(of: selectedTab) { _ in sync() }
            .onChange(of: dockTabs) { _ in sync() }
            .onAppear { sync() }
    }

    private func sync() {
        let tabs = dockTabs
        DispatchQueue.main.async { AppTabBadge.syncProfileDot(dockTabs: tabs) }
    }
}
