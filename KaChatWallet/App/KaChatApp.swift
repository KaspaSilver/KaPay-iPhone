import SwiftUI
import UserNotifications
import UIKit

@main
struct KaChatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var walletManager = WalletManager.shared
    @StateObject private var walletService = WalletService.shared
    @StateObject private var settingsViewModel = SettingsViewModel()
    @StateObject private var pushManager = PushNotificationManager.shared
    /// The blur over the app in the App Switcher and behind system prompts: balances and the
    /// seed screen used to sit in iOS's snapshot of the app in plain view.
    @State private var lastActiveResyncAt: Date?
    @State private var hasCompletedFirstActiveTransition = false
    @Environment(\.scenePhase) private var scenePhase

    /// Below this, becoming active again skips the heavier resync work (node pool reconnect
    /// sweep, receive catch-up) - only what must run every time still does.
    private let activeResyncDebounce: TimeInterval = 15

    init() {
        // A Testnet/Mainnet switch chosen in Settings takes effect here, before any service
        // reads the settings, so the whole app starts on one network (IOS-002).
        PendingNetworkSwitch.applyAtLaunch()
        KeychainService.shared.deleteRetiredSimpleModePasswordIfNeeded()
        // Touch the (lazy) Nextcloud singleton so its lifecycle observers - the Address Book's
        // on-background backup and the launch catch-up - are registered from the first launch.
        _ = NextcloudService.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(walletManager)
                .environmentObject(walletService)
                .environmentObject(settingsViewModel)
                .environmentObject(pushManager)
                .onAppear {
                    WalletService.shared.settingsViewModel = settingsViewModel
                    applyWindowAppearanceOverride()
                }
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL {
                        handleIncomingURL(url)
                    }
                }
                .preferredColorScheme(settingsViewModel.settings.appearance.colorScheme)
                .onChange(of: settingsViewModel.settings.appearance) { _ in
                    applyWindowAppearanceOverride()
                }
                .environment(\.locale, settingsViewModel.settings.language.locale ?? .autoupdatingCurrent)
        }
        .onChange(of: scenePhase) { newPhase in
            handleScenePhaseChange(to: newPhase)
        }
    }

    /// `.preferredColorScheme` only themes SwiftUI content — the UIKit layer underneath (the
    /// window background visible around sheet-presentation edges, the keyboard, share sheets,
    /// UIKit pickers) still follows the DEVICE appearance. Overriding the windows' interface
    /// style makes the whole window chrome match.
    private func applyWindowAppearanceOverride() {
        let style: UIUserInterfaceStyle
        switch settingsViewModel.settings.appearance {
        case .system: style = .unspecified
        case .light: style = .light
        case .dark: style = .dark
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
                // The tab bar kept the OLD theme's colours after a switch until relaunch: UIKit
                // caches its resolved appearance, so re-applying it forces the repaint.
                Self.refreshTabBars(in: window.rootViewController)
            }
        }
    }

    private static func refreshTabBars(in root: UIViewController?) {
        guard let root else { return }
        var queue: [UIViewController] = [root]
        while let controller = queue.popLast() {
            if let tabs = controller as? UITabBarController {
                let appearance = UITabBarAppearance()
                appearance.configureWithDefaultBackground()
                tabs.tabBar.standardAppearance = appearance
                tabs.tabBar.scrollEdgeAppearance = appearance
                tabs.tabBar.setNeedsLayout()
                tabs.tabBar.layoutIfNeeded()
            }
            queue.append(contentsOf: controller.children)
            if let presented = controller.presentedViewController { queue.append(presented) }
        }
    }

    @MainActor
    private func handleScenePhaseChange(to newPhase: ScenePhase) {
        // Covered the moment the app stops being the thing in front (the switcher, a system
        // prompt, a call), uncovered when it is again.
        if newPhase == .active {
            PrivacyCoverWindow.hide()
        } else {
            PrivacyCoverWindow.show()
        }
        switch newPhase {
        case .background:
            if settingsViewModel.settings.backgroundFetchEnabled {
                BackgroundTaskManager.shared.scheduleBackgroundFetch()
            }
            if settingsViewModel.settings.notificationMode == .remotePush {
                WalletService.shared.pauseUtxoSubscriptionForRemotePush()
            }
        case .active:
            LaunchTrace.mark("scene active")
            BackgroundTaskManager.shared.cancelBackgroundFetch()
            // .kachat registrations in flight (testnet only; no-op on mainnet) resume after a
            // relaunch: commit -> wait -> register continues by itself.
            KachatNamesActions.shared.resume()
            // .kachat news for the bell (offers, sales, renewal, expiry). Testnet only until
            // names launch on mainnet.
            Task { @MainActor in await KachatNamesRegistry.shared.refreshIfStale() }
            // a .kas commit whose reveal never went out
            Task { @MainActor in await KNSRevealRecovery.resume() }
            // keys that couldn't be read at a locked launch may be readable now
            Task { @MainActor in await WalletManager.shared.retryKeyRecoveryIfNeeded() }

            let isFirstActiveTransition = !hasCompletedFirstActiveTransition
            hasCompletedFirstActiveTransition = true
            // On a cold launch, let the first render settle before the resync work below starts
            // contending for the main actor.
            let coldStartGraceNanos: UInt64 = isFirstActiveTransition ? 2_000_000_000 : 0

            let shouldRunHeavyResync = lastActiveResyncAt.map {
                Date().timeIntervalSince($0) > activeResyncDebounce
            } ?? true
            if shouldRunHeavyResync {
                lastActiveResyncAt = Date()
                // gRPC connections can die silently while backgrounded - reconnect any that are
                // dead now instead of waiting for the next request to find out.
                Task {
                    if coldStartGraceNanos > 0 {
                        try? await Task.sleep(nanoseconds: coldStartGraceNanos)
                    }
                    await NodePoolService.shared.reconnectStaleConnections()
                }
                // Receives that landed while away: diff the own addresses' balances against the
                // persisted baseline (internally debounced; the first run only seeds it).
                Task {
                    if coldStartGraceNanos > 0 {
                        try? await Task.sleep(nanoseconds: coldStartGraceNanos)
                    }
                    await AddressActivityNotifier.shared.runCatchUpIfNeeded()
                }
            }
            // Bring the live subscription to the wallet's own addresses back if it dropped while
            // away (no-op while it is up).
            WalletService.shared.startPolling()
            if settingsViewModel.settings.notificationMode == .remotePush {
                Task {
                    await WalletService.shared.resumeUtxoSubscriptionForRemotePush()
                }
                pushManager.refreshRegistrationIfNeeded()
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    /// A payment request link (`kachat://pay/...` or `https://kachat.app/pay/...`) opens Send
    /// Kaspa with it filled in. Nothing else is routed.
    private func handleIncomingURL(_ url: URL) {
        if KaChatInternalLink.isMarketLink(url) {
            KaChatLinkRouter.openMarketplace()
        } else if let link = KaChatInternalLink.parse(url) {
            KaChatLinkRouter.open(link)
        }
    }
}

// MARK: - App Delegate for Notification and Background Task Handling
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Orientation policy per device: iPhone is hard-locked to portrait; iPad may rotate to any
    /// orientation. This overrides the Info.plist keys.
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }

    /// No third-party keyboards anywhere in the app: the passphrase and the card PIN are typed on the
    /// system keyboard, so a keyboard with Full Access never sees them. They're offered the system's.
    func application(_ application: UIApplication, shouldAllowExtensionPointIdentifier extensionPointIdentifier: UIApplication.ExtensionPointIdentifier) -> Bool {
        extensionPointIdentifier != .keyboard
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Task.detached(priority: .utility) { CacheManager.sweepStaleTempFiles() }
        // Set notification delegate to handle foreground notifications
        UNUserNotificationCenter.current().delegate = self

        // Register background task handler
        BackgroundTaskManager.shared.registerBackgroundTasks()

        // Warm up keyboard in background to avoid first-tap delay
        // Delay slightly to ensure scene is ready (prevents "UIScene accessed before set" warning)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Self.warmUpKeyboard()
        }

        return true
    }

    // MARK: - APNs Token Handling

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            PushNotificationManager.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            PushNotificationManager.shared.didFailToRegisterForRemoteNotifications(error: error)
        }
    }

#if targetEnvironment(macCatalyst)
    func applicationShouldTerminateAfterLastWindowClosed(_ application: UIApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        ensureMainWindow(application)
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }

        // Replace Close Window (Cmd+W) with Hide Window to keep the scene alive.
        // This avoids a full scene rebuild when the user clicks the dock icon.
        let hideCommand = UIKeyCommand(
            title: "Hide Window",
            action: #selector(hideActiveWindow),
            input: "W",
            modifierFlags: .command
        )
        let menu = UIMenu(title: "", options: .displayInline, children: [hideCommand])
        builder.replace(menu: .close, with: menu)
    }

    @objc func hideActiveWindow() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.isHidden = true
            }
        }
    }

    private func ensureMainWindow(_ application: UIApplication) {
        // First: try to unhide any hidden windows in connected scenes (instant)
        for scene in application.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            let hiddenWindows = windowScene.windows.filter { $0.isHidden }
            if !hiddenWindows.isEmpty {
                for window in hiddenWindows {
                    window.isHidden = false
                    window.makeKeyAndVisible()
                }
                return
            }
            // Scene is connected and has visible windows — nothing to do
            if !windowScene.windows.isEmpty { return }
        }

        // No connected scene with windows — reactivate an existing session
        // (faster than creating a brand new one with nil)
        UIApplication.shared.requestSceneSessionActivation(
            application.openSessions.first,
            userActivity: nil,
            options: nil,
            errorHandler: nil
        )
    }
#endif

    /// Pre-load keyboard to avoid first-use delay
    private static func warmUpKeyboard() {
        // Guard against accessing scene before it's ready
        guard !UIApplication.shared.connectedScenes.isEmpty else {
            return
        }

        let textField = UITextField()
        textField.autocorrectionType = .no
        textField.inputAssistantItem.leadingBarButtonGroups = []
        textField.inputAssistantItem.trailingBarButtonGroups = []

        // Add to window hierarchy temporarily
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            textField.frame = CGRect(x: -100, y: -100, width: 10, height: 10)
            window.addSubview(textField)
            textField.becomeFirstResponder()

            // Remove after brief delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                textField.resignFirstResponder()
                textField.removeFromSuperview()
            }
        }
    }

    // Show notifications even when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let threadId = notification.request.content.threadIdentifier
        Task { @MainActor in
            // The push service's "Received" push (thread "funds:<address>") gets no banner while
            // the app is open - the app's own Address Activity notification already announces
            // that receive, and both would show.
            if threadId.hasPrefix("funds:") {
                completionHandler([])
                return
            }
            let settings = AppSettings.load()
            var options: UNNotificationPresentationOptions = [.banner, .list]
            if settings.incomingNotificationSoundEnabled {
                options.insert(.sound)
            } else if settings.incomingNotificationVibrationEnabled {
                Haptics.impact(.light)
            }
            completionHandler(options)
        }
    }

    // Handle notification tap
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let threadIdentifier = content.threadIdentifier

        // A .kachat name event (offer, sale, accepted offer, renewal reminder): open that name.
        // The phone's own reminders carry thread "kachat-names"; the service's push carries
        // `type: name_event` and no thread.
        let isNameEvent = content.userInfo["type"] as? String == "name_event"
        if threadIdentifier == "kachat-names" || isNameEvent {
            let name = content.userInfo["name"] as? String
            Task { @MainActor in
                KachatDeepLink.pendingName = name.map { KachatNames.Codec.normalize($0) }
                PendingTabRoute.pending = .kachatNames
                NotificationCenter.default.post(name: .openKachatName, object: nil)
            }
            completionHandler()
            return
        }

        // The push service's "Received" push carries only its thread id, "funds:<address>" -
        // open that address's history, as the local notification does.
        if threadIdentifier.hasPrefix("funds:") {
            let address = String(threadIdentifier.dropFirst("funds:".count))
            if !address.isEmpty {
                OwnAddressRoute.pending = address
                NotificationCenter.default.post(name: .openOwnAddress, object: nil)
            } else {
                PendingTabRoute.pending = .portfolio
                NotificationCenter.default.post(name: .openPortfolio, object: nil)
            }
            completionHandler()
            return
        }

        // The app's own "Received" notification: open the address that got the Kaspa (main,
        // spending or cold storage - MainTabView works out which). `PendingTabRoute` and
        // `OwnAddressRoute` cover the cold start, where the post has no observer yet.
        if threadIdentifier == AddressActivityNotifier.notificationThreadIdentifier {
            let kind = content.userInfo["kind"] as? String
            if let address = content.userInfo["address"] as? String, !address.isEmpty {
                OwnAddressRoute.pending = address
                NotificationCenter.default.post(name: .openOwnAddress, object: nil)
            } else if kind == "cold" {
                PendingTabRoute.pending = .coldStorage
                NotificationCenter.default.post(name: .openColdStorage, object: nil)
            } else {
                PendingTabRoute.pending = .portfolio
                NotificationCenter.default.post(name: .openPortfolio, object: nil)
            }
            completionHandler()
            return
        }

        completionHandler()
    }
}

/// Cold-start handoff for a notification tap whose whole destination IS a dock tab (wallet
/// receipts, cold-storage activity). The posts those taps make are delivered synchronously to
/// whoever is listening RIGHT THEN - on a cold start that is nobody, since `MainTabView` hasn't
/// mounted. It consumes this on mount instead (`consumePendingNotificationRoute`).
enum PendingTabRoute {
    static var pending: AppTab?
}

/// The own address a tapped "Received" notification points at, for MainTabView to open (its
/// History tab). Survives a cold start, where the post below has no observer yet.
enum OwnAddressRoute {
    static var pending: String?
}

/// The single place an already-validated `KaChatInternalLink` becomes navigation.
enum KaChatLinkRouter {

    /// The .kachat Marketplace page. The pending routes survive a cold start and sign-in, where
    /// the post below has no observer yet.
    @MainActor
    static func openMarketplace() {
        KachatDeepLink.pendingMarketplace = true
        PendingTabRoute.pending = .kachatNames
        NotificationCenter.default.post(name: .openKachatName, object: nil)
    }

    @MainActor
    static func open(_ link: KaChatInternalLink) {
        switch link {
        case .paymentRequest(let request):
            openPaymentRequest(request)
        case .profile:
            // A KaChat profile has no screen in the wallet.
            break
        }
    }

    /// A payment request: someone else's opens Send Kaspa with it filled in, your own shows it
    /// (amount, memo, the address it pays into) with its link to copy or share again
    /// (`PaymentRequestSheetPresenter`, in `MainTabView`).
    @MainActor
    static func openPaymentRequest(_ request: PaymentRequest) {
        PaymentRequestRouter.shared.pending = request
    }
}

extension Notification.Name {
    static let openPortfolio = Notification.Name("openPortfolio")
    /// A `.kachat` name notification was tapped: the name is in `KachatDeepLink.pendingName`.
    static let openKachatName = Notification.Name("openKachatName")
    static let openColdStorage = Notification.Name("openColdStorage")
    /// A "Received" notification for one of your addresses was tapped: `OwnAddressRoute.pending`.
    static let openOwnAddress = Notification.Name("openOwnAddress")
}

/// Puts `PrivacyCoverView` in a window of its own above the app. An overlay on the root view sat
/// underneath presented sheets, which is where the 12 or 24 words and private keys are shown.
@MainActor
private enum PrivacyCoverWindow {
    /// One cover per window scene: on iPad and Mac the app can have several windows open, and
    /// each one is snapshotted (as KaChat).
    private static var windows: [UIWindow] = []
    private static var sceneObservers: [NSObjectProtocol] = []

    /// The app's `scenePhase` stays active while any window is, so a window that goes to the
    /// background beside an active one is only heard about from its own scene.
    static func observeScenes() {
        guard sceneObservers.isEmpty else { return }
        let center = NotificationCenter.default
        sceneObservers = [
            center.addObserver(forName: UIScene.willDeactivateNotification, object: nil, queue: .main) { note in
                guard let scene = note.object as? UIWindowScene else { return }
                MainActor.assumeIsolated { cover(scene) }
            },
            center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { note in
                guard let scene = note.object as? UIWindowScene else { return }
                MainActor.assumeIsolated { uncover(scene) }
            },
        ]
    }

    private static func cover(_ scene: UIWindowScene) {
        guard !windows.contains(where: { $0.windowScene === scene }) else { return }
        let cover = UIWindow(windowScene: scene)
        cover.windowLevel = .alert + 1
        // the app's appearance (Settings' choice), which its own windows carry
        cover.overrideUserInterfaceStyle = scene.windows.first?.overrideUserInterfaceStyle ?? .unspecified
        cover.rootViewController = UIHostingController(rootView: PrivacyCoverView())
        cover.isHidden = false
        windows.append(cover)
    }

    private static func uncover(_ scene: UIWindowScene) {
        windows.filter { $0.windowScene === scene }.forEach { $0.isHidden = true }
        windows.removeAll { $0.windowScene === scene }
    }

    static func show() {
        observeScenes()
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.forEach(cover)
    }

    /// Only the windows that are in front again: another may still be in the background.
    static func hide() {
        observeScenes()
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .forEach(uncover)
    }
}

/// What the App Switcher and a system prompt see instead of the app's contents.
private struct PrivacyCoverView: View {
    /// The app's appearance (Settings' choice, or the system's): the logo follows it.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // Solid: large words can still be read through a light blur.
            Color(.systemBackground)
            // The wallet's own logo, rounded like its app icon: the dark-mode icon (near-black
            // tile, `tools/make_logo.py ... dark`) when the app is dark, the white one otherwise.
            Image(colorScheme == .dark ? "KaChatWalletLogoDark" : "KaChatWalletLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .ignoresSafeArea()
    }
}
