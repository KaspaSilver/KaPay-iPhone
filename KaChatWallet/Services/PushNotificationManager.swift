import Foundation
import Combine
import UserNotifications
import UIKit
import DeviceCheck
import CryptoKit
import Security
import P256K

/// Registers this device with KaChat's push service for the wallet's two pushes: "Received KAS"
/// on its own addresses (`watch_only_addresses`) and .kachat name events (`primary_address`),
/// sent on the wallet's APNs topic. Every request is signed by the wallet key (see
/// `buildPushAuth`); the chat fields the service also knows are always sent empty.
@MainActor
final class PushNotificationManager: ObservableObject {
    static let shared = PushNotificationManager()

    // MARK: - Published State

    @Published private(set) var isRegistered = false
    @Published private(set) var permissionStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var lastError: String?

    /// Number of own addresses being watched for "Received" pushes
    var watchedAddressesCount: Int? {
        guard isRegistered else { return nil }
        return collectWatchOnlyAddresses().count
    }

    // MARK: - Private State

    private let tokenDefaultsKey = "push_device_token"
    private let registeredDefaultsKey = "push_registered"
    /// Base URL of the service the device last successfully registered with - lets a push-URL
    /// change unregister from the OLD service (both kept pushing = duplicate notifications).
    private let registeredBaseURLDefaultsKey = "push_registered_base_url"
    /// APNs environment ("development"/"production") the device last successfully registered
    /// with. A token minted for one environment is rejected by the other (`BadDeviceToken`), so
    /// installing a TestFlight build over an Xcode build must force a FULL re-registration
    /// rather than reusing the stale server record.
    private let registeredApnsEnvironmentDefaultsKey = "push_registered_apns_environment"
    /// App build the device last successfully registered from. A new build gets one FULL
    /// registration (POST) instead of trusting the persisted "registered" flag - installing a
    /// beta over the previous one left users with no pushes until they toggled notifications
    /// off and on, which is exactly the unregister + register this now does by itself.
    private let registeredBuildDefaultsKey = "push_registered_build"
    private let legacyKasiaUnregisterDoneKey = "push_legacy_kasia_unregister_done"
    private let deviceAuthCounterDefaultsKey = "push_device_auth_counter"

    private var deviceToken: String?
    private var pendingRegistration = false
    private var registrationInFlight = false
    private var lastDeviceTokenHandledAt: Date?
    private var registrationContinuation: CheckedContinuation<Void, Error>?
    private var registrationTimeoutTask: Task<Void, Never>?
    private var updateWatchedInFlight = false
    private var updateWatchedPending = false
    private var updateWatchedTask: Task<Void, Never>?
    private var lastWatchedUpdateAt: Date?
    private var lastWatchedUpdateSuccessAt: Date?
    private var lastWatchedSignature: String?
    private var pendingWatchedSignature: String?
    private var inFlightWatchedSignature: String?
    // Backoff retry for failed watched-set updates - without it, a dropped update left the
    // service's watch list stale until an unrelated later trigger.
    private var watchedUpdateRetryTask: Task<Void, Never>?
    private var watchedUpdateRetryAttempt = 0
    private var walletBindingConflictFingerprint: String?
    private var walletBindingConflictUntil: Date?
    private var lastWalletBindingConflictLogAt: Date?
    private let updateWatchedDebounce: TimeInterval = 1.0
    private let updateWatchedSuccessCooldown: TimeInterval = 10.0
    private let walletBindingConflictCooldown: TimeInterval = 15 * 60
    private let walletBindingConflictLogCooldown: TimeInterval = 60
    private var settingsObserver: NSObjectProtocol?

    // MARK: - Constants

    private let registrationEndpoint = "/v1/push/register"
    private let updateEndpoint = "/v1/push/update"
    private let unregisterEndpoint = "/v1/push/unregister"
    private let challengeEndpoint = "/v1/push/challenge"
    private let pushAuthDomain = "kchat-push-auth:v1"
    private let pushDeviceAuthDomain = "kchat-push-device-auth:v1"
    private let pushDeviceAuthScheme = "device_key_v1"

    // MARK: - Initialization

    private init() {
        loadPersistedState()
        observeSettingsChanges()
        Task {
            await checkPermissionStatus()
        }
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    // MARK: - Public API

    /// Request notification permission and register with APNs
    func requestPermissionAndRegister() async throws {
        let center = UNUserNotificationCenter.current()

        // Request permission
        let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])

        await MainActor.run {
            permissionStatus = granted ? .authorized : .denied
        }

        guard granted else {
            throw PushError.permissionDenied
        }

        // Register with APNs - this will trigger didRegisterForRemoteNotifications
        pendingRegistration = true
        UIApplication.shared.registerForRemoteNotifications()

        AppLog.log("[Push] Requested APNs registration")
    }

    /// Request permission, register with APNs, and wait for indexer registration.
    func requestPermissionAndRegisterAndWaitForIndexer() async throws {
        let center = UNUserNotificationCenter.current()

        let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])

        await MainActor.run {
            permissionStatus = granted ? .authorized : .denied
        }

        guard granted else {
            throw PushError.permissionDenied
        }

        guard registrationContinuation == nil else {
            throw PushError.registrationInProgress
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            registrationContinuation = continuation
            pendingRegistration = true

            registrationTimeoutTask?.cancel()
            registrationTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await MainActor.run {
                    self?.completeRegistration(with: PushError.registrationTimedOut)
                }
            }

            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// False when this network has no usable push service address (testnet until its indexer
    /// is published). Every push-service call is skipped then: a blank base would otherwise
    /// produce path-only requests that iOS rejects as "unsupported URL".
    private var hasPushService: Bool {
        Self.isUsableBaseURL(AppSettings.load().pushIndexerURL)
    }

    static func isUsableBaseURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return false }
        return true
    }

    func refreshRegistrationIfNeeded() {
        let settings = AppSettings.load()
        guard settings.notificationMode == .remotePush else { return }
        // No push service on this network (testnet has none yet). The service this device
        // registered with on the other network would keep pushing that network's messages
        // here, so tell it to stop, and stay unregistered.
        if !hasPushService {
            Task { await leavePushServiceOfOtherNetworkIfNeeded() }
            return
        }
        guard permissionStatus == .authorized || permissionStatus == .provisional else { return }
        guard registrationContinuation == nil else { return }

        if deviceToken == nil {
            pendingRegistration = true
            UIApplication.shared.registerForRemoteNotifications()
            return
        }

        // Ask iOS for the current token on every refresh too (Apple's advice: once per launch).
        // A saved token can be stale - reissued with a reinstall or an environment switch - and
        // `didRegisterForRemoteNotifications` re-registers in full when the answer differs.
        UIApplication.shared.registerForRemoteNotifications()

        if shouldDeferRegistrationForWalletBindingConflict() {
            return
        }

        if isRegistered {
            Task {
                await updateWatchedAddresses()
            }
            return
        }

        guard hasPushSubscriptions() else { return }

        Task {
            do {
                try await registerWithIndexer()
            } catch {
                lastError = error.localizedDescription
                AppLog.log("[Push] Refresh registration failed: %@", error.localizedDescription)
                if registrationContinuation != nil {
                    completeRegistration(with: error)
                }
            }
        }
    }

    /// Called from AppDelegate when APNs token received
    func didRegisterForRemoteNotifications(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        let previousToken = self.deviceToken
        if token == self.deviceToken,
           let last = lastDeviceTokenHandledAt,
           Date().timeIntervalSince(last) < 5 {
            return
        }
        lastDeviceTokenHandledAt = Date()
        self.deviceToken = token
        if previousToken != token {
            clearWalletBindingConflictCooldown()
        }
        persistDeviceToken(token)

        AppLog.log("[Push] Received APNs token: %@...%@",
              String(token.prefix(8)), String(token.suffix(8)))

        // APNs handed out a DIFFERENT token while the service still holds the old one (a
        // reinstall or an update can reissue it). Nothing else re-registers in that state -
        // the persisted "registered" flag steered every later refresh into a PUT for the old
        // token - so every push went to a token this device no longer has. Full register now.
        if let previousToken, previousToken != token, isRegistered, !pendingRegistration {
            AppLog.log("[Push] APNs token changed - re-registering with the new token")
            isRegistered = false
            persistRegistrationStatus(false)
            guard !registrationInFlight else { return }
            Task {
                do {
                    try await registerWithIndexer()
                } catch {
                    lastError = error.localizedDescription
                    AppLog.log("[Push] Re-registration after token change failed: %@", error.localizedDescription)
                }
            }
            return
        }

        // If we were waiting for registration, complete it
        if pendingRegistration {
            pendingRegistration = false
            if registrationInFlight {
                Task {
                    await self.waitForInFlightRegistrationIfNeeded()
                }
                return
            }
            Task {
                do {
                    try await registerWithIndexer()
                    await MainActor.run {
                        self.completeRegistration()
                    }
                } catch {
                    AppLog.log("[Push] Failed to register with indexer: %@", error.localizedDescription)
                    lastError = error.localizedDescription
                    await MainActor.run {
                        self.completeRegistration(with: error)
                    }
                }
            }
        }
    }

    /// Called from AppDelegate when APNs registration fails
    func didFailToRegisterForRemoteNotifications(error: Error) {
        AppLog.log("[Push] APNs registration failed: %@", error.localizedDescription)
        pendingRegistration = false
        lastError = error.localizedDescription
        completeRegistration(with: error)
    }

    /// Register device with indexer, including watched addresses
    func registerWithIndexer() async throws {
        guard hasPushService else {
            await leavePushServiceOfOtherNetworkIfNeeded()
            throw PushError.noPushService
        }
        await unregisterFromSupersededServiceIfNeeded()
        guard let token = deviceToken else {
            throw PushError.noDeviceToken
        }
        guard !registrationInFlight else {
            return
        }
        registrationInFlight = true
        defer { registrationInFlight = false }

        let settings = AppSettings.load()
        let primaryAddress = collectPrimaryAddress()
        let watchOnlyAddresses = collectWatchOnlyAddresses()

        // Its own addresses (watch-only) and its chatting address (.kachat name events) are the
        // wallet's whole registration.
        guard hasPushSubscriptions(watchOnlyAddresses: watchOnlyAddresses, primaryAddress: primaryAddress) else {
            throw PushError.noWatchedAddresses
        }

        for attempt in 0..<2 {
            let (statusCode, reason) = try await submitRegistrationRequest(
                settings: settings,
                token: token,
                primaryAddress: primaryAddress,
                watchOnlyAddresses: watchOnlyAddresses
            )
            if statusCode == 200 {
                applySuccessfulRegistration(primaryAddress: primaryAddress, watchOnlyAddresses: watchOnlyAddresses)
                return
            }
            if isWalletBindingConflict(statusCode: statusCode, reason: reason), attempt == 0 {
                let recovered = await attemptWalletBindingRecoveryUnregister(token: token)
                if recovered {
                    continue
                }
            }
            if isWalletBindingConflict(statusCode: statusCode, reason: reason) {
                activateWalletBindingConflictCooldown(reason: reason)
            }
            throw PushError.registrationFailed(statusCode: statusCode, reason: reason)
        }
    }

    private func submitRegistrationRequest(
        settings: AppSettings,
        token: String,
        primaryAddress: String?,
        watchOnlyAddresses: [String]
    ) async throws -> (Int, String?) {
        guard let url = URL(string: "\(settings.pushIndexerURL)\(registrationEndpoint)") else {
            AppLog.log("[Push] Invalid push service URL: %@", settings.pushIndexerURL)
            throw PushError.invalidResponse
        }
        let auth = try await buildPushAuth(
            method: "POST",
            path: registrationEndpoint,
            deviceToken: token,
            primaryAddress: primaryAddress
        )

        #if targetEnvironment(macCatalyst)
        let platform = "macos"
        #else
        let platform = "ios"
        #endif

        let request = PushRegistrationRequest(
            deviceToken: token,
            platform: platform,
            primaryAddress: primaryAddress,
            apnsEnvironment: ApnsEnvironment.current.rawValue,
            watchOnlyAddresses: watchOnlyAddresses,
            apnsTopic: Self.apnsTopic,
            auth: auth
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        urlRequest.timeoutInterval = 30

        let (responseData, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PushError.invalidResponse
        }
        let reason = parseIndexerError(from: responseData)
        return (httpResponse.statusCode, reason)
    }

    private func applySuccessfulRegistration(primaryAddress: String?, watchOnlyAddresses: [String]) {
        isRegistered = true
        lastError = nil
        persistRegistrationStatus(true)
        UserDefaults.standard.set(AppSettings.load().pushIndexerURL, forKey: registeredBaseURLDefaultsKey)
        UserDefaults.standard.set(ApnsEnvironment.current.rawValue, forKey: registeredApnsEnvironmentDefaultsKey)
        UserDefaults.standard.set(Self.currentBuildIdentifier, forKey: registeredBuildDefaultsKey)
        clearWalletBindingConflictCooldown()
        lastWatchedSignature = buildWatchedSignature(primaryAddress: primaryAddress)
        lastWatchedUpdateSuccessAt = Date()
        pendingWatchedSignature = nil
        inFlightWatchedSignature = nil

        AppLog.log("[Push] Registered with indexer, watching %d own addresses", watchOnlyAddresses.count)
        if registrationContinuation != nil {
            completeRegistration()
        }
    }

    private func attemptWalletBindingRecoveryUnregister(token: String) async -> Bool {
        let settings = AppSettings.load()
        guard hasPushService,
              let url = URL(string: "\(settings.pushIndexerURL)\(unregisterEndpoint)") else {
            return false
        }

        let auth: PushAuthRequest?
        do {
            auth = try await buildPushAuth(
                method: "DELETE",
                path: unregisterEndpoint,
                deviceToken: token,
                primaryAddress: nil
            )
        } catch {
            AppLog.log("[Push] Recovery unregister auth build failed: %@", error.localizedDescription)
            return false
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "DELETE"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try? JSONEncoder().encode(
            PushUnregisterRequest(deviceToken: token, auth: auth)
        )
        urlRequest.timeoutInterval = 30

        do {
            let (responseData, response) = try await URLSession.shared.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            if httpResponse.statusCode == 200 {
                isRegistered = false
                persistRegistrationStatus(false)
                AppLog.log("[Push] Recovery unregister succeeded, retrying register")
                return true
            }
            let reason = parseIndexerError(from: responseData) ?? "unknown"
            AppLog.log("[Push] Recovery unregister failed: status=%d reason=%@", httpResponse.statusCode, reason)
            return false
        } catch {
            AppLog.log("[Push] Recovery unregister error: %@", error.localizedDescription)
            return false
        }
    }

    private func waitForInFlightRegistrationIfNeeded() async {
        // Another registration attempt is already in-flight. Wait for it to settle so the
        // explicit "register and wait" path doesn't falsely time out.
        for _ in 0..<120 {
            if !registrationInFlight {
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard registrationContinuation != nil else { return }
        if registrationInFlight {
            return
        }
        if isRegistered {
            completeRegistration()
            return
        }
        if let lastError {
            completeRegistration(with: PushError.authFailed(reason: lastError))
        }
    }

    private func completeRegistration(with error: Error? = nil) {
        pendingRegistration = false
        registrationTimeoutTask?.cancel()
        registrationTimeoutTask = nil

        guard let continuation = registrationContinuation else { return }
        registrationContinuation = nil

        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    /// Update the watched addresses (call when the own address set or the switches change)
    func updateWatchedAddresses() async {
        guard deviceToken != nil else { return }
        guard hasPushService else { return }

        if !isRegistered {
            guard hasPushSubscriptions() else { return }
            if shouldDeferRegistrationForWalletBindingConflict() {
                return
            }
            do {
                try await registerWithIndexer()
            } catch {
                lastError = error.localizedDescription
                AppLog.log("[Push] Failed to register with indexer while updating watched addresses: %@",
                      error.localizedDescription)
                if registrationContinuation != nil {
                    completeRegistration(with: error)
                }
            }
            return
        }

        if updateWatchedInFlight || updateWatchedTask != nil {
            updateWatchedPending = true
            pendingWatchedSignature = buildWatchedSignature()
            return
        }

        let now = Date()
        if let last = lastWatchedUpdateAt,
           now.timeIntervalSince(last) < updateWatchedDebounce {
            updateWatchedPending = true
            pendingWatchedSignature = buildWatchedSignature()
            if updateWatchedTask == nil {
                let delay = updateWatchedDebounce - now.timeIntervalSince(last)
                updateWatchedTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    await self?.runWatchedUpdate(fromDebounceTask: true)
                }
            }
            return
        }
        let signature = buildWatchedSignature()
        if let lastSig = lastWatchedSignature,
           signature == lastSig,
           let lastSuccess = lastWatchedUpdateSuccessAt,
           now.timeIntervalSince(lastSuccess) < updateWatchedSuccessCooldown {
            return
        }

        lastWatchedUpdateAt = now
        pendingWatchedSignature = signature
        await runWatchedUpdate()
    }

    private func runWatchedUpdate(fromDebounceTask: Bool = false) async {
        guard let token = deviceToken, isRegistered else {
            updateWatchedPending = false
            // or every later update would see a task "still running" and wait behind it for good
            if fromDebounceTask { updateWatchedTask = nil }
            return
        }
        // CRITICAL: when running INSIDE the debounce task, do NOT cancel it - cancelling the very
        // task this code executes in poisons the subsequent URLSession call (it throws .cancelled),
        // which silently dropped every debounced update. Roster changes emit in bursts, so group
        // watch-list updates were routinely lost this way (members missing pushes per-sender).
        if fromDebounceTask {
            updateWatchedTask = nil
        } else {
            updateWatchedTask?.cancel()
            updateWatchedTask = nil
        }
        if updateWatchedInFlight {
            updateWatchedPending = true
            return
        }
        updateWatchedInFlight = true
        defer {
            updateWatchedInFlight = false
        }

        let settings = AppSettings.load()
        let primaryAddress = collectPrimaryAddress()
        let watchOnlyAddresses = collectWatchOnlyAddresses()
        // Only unregister when there is NOTHING left to watch. The chatting address alone (.kachat
        // name events, with Address Activity off) is a registration.
        if !hasPushSubscriptions(watchOnlyAddresses: watchOnlyAddresses, primaryAddress: primaryAddress) {
            AppLog.log("[Push] Nothing to watch, unregistering device from indexer")
            await unregister()
            lastWatchedSignature = ""
            lastWatchedUpdateSuccessAt = Date()
            pendingWatchedSignature = nil
            inFlightWatchedSignature = nil
            updateWatchedPending = false
            return
        }
        let signature = buildWatchedSignature(primaryAddress: primaryAddress)
        inFlightWatchedSignature = signature

        let auth: PushAuthRequest
        do {
            auth = try await buildPushAuth(
                method: "PUT",
                path: updateEndpoint,
                deviceToken: token,
                primaryAddress: primaryAddress
            )
        } catch {
            lastError = error.localizedDescription
            AppLog.log("[Push] Failed to build auth for watched update: %@", error.localizedDescription)
            inFlightWatchedSignature = nil
            scheduleWatchedUpdateRetry()
            return
        }

        let request = PushUpdateRequest(
            deviceToken: token,
            primaryAddress: primaryAddress,
            apnsEnvironment: ApnsEnvironment.current.rawValue,
            watchOnlyAddresses: watchOnlyAddresses,
            apnsTopic: Self.apnsTopic,
            auth: auth
        )

        guard let url = URL(string: "\(settings.pushIndexerURL)\(updateEndpoint)") else {
            AppLog.log("[Push] Invalid push service URL: %@", settings.pushIndexerURL)
            inFlightWatchedSignature = nil
            return
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "PUT"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try? JSONEncoder().encode(request)
        urlRequest.timeoutInterval = 30

        do {
            let (responseData, response) = try await URLSession.shared.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                AppLog.log("[Push] Failed to update watched addresses: invalid response")
                inFlightWatchedSignature = nil
                scheduleWatchedUpdateRetry()
                return
            }
            guard httpResponse.statusCode == 200 else {
                let reason = parseIndexerError(from: responseData) ?? "unknown"
                if isWalletBindingConflict(statusCode: httpResponse.statusCode, reason: reason) {
                    let recovered = await attemptWalletBindingRecoveryUnregister(token: token)
                    if recovered {
                        do {
                            try await registerWithIndexer()
                        } catch {
                            lastError = error.localizedDescription
                        }
                        return
                    }
                    activateWalletBindingConflictCooldown(reason: reason)
                    return
                }
                if httpResponse.statusCode == 404 {
                    // The service does not know this device any more - a PUT can never fix
                    // that, and retrying it on a backoff only kept the pushes dead. Register
                    // from scratch.
                    AppLog.log("[Push] Watched update answered 404 - device unknown to the service, re-registering")
                    inFlightWatchedSignature = nil
                    isRegistered = false
                    persistRegistrationStatus(false)
                    do {
                        try await registerWithIndexer()
                    } catch {
                        lastError = error.localizedDescription
                        AppLog.log("[Push] Re-registration after 404 failed: %@", error.localizedDescription)
                    }
                    return
                }
                AppLog.log("[Push] Failed to update watched addresses: status=%d reason=%@", httpResponse.statusCode, reason)
                inFlightWatchedSignature = nil
                scheduleWatchedUpdateRetry()
                return
            }

            lastWatchedSignature = signature
            lastWatchedUpdateSuccessAt = Date()
            // Success - reset the failure backoff.
            watchedUpdateRetryAttempt = 0
            watchedUpdateRetryTask?.cancel()
            watchedUpdateRetryTask = nil
            AppLog.log("[Push] Updated watched addresses: %d own", watchOnlyAddresses.count)
        } catch {
            AppLog.log("[Push] Error updating addresses: %@", error.localizedDescription)
            inFlightWatchedSignature = nil
            scheduleWatchedUpdateRetry()
        }

        if updateWatchedPending {
            updateWatchedPending = false
            lastWatchedUpdateAt = Date()
            let nextSignature = pendingWatchedSignature
            pendingWatchedSignature = nil
            if let nextSignature,
               nextSignature != lastWatchedSignature,
               nextSignature != inFlightWatchedSignature {
                await runWatchedUpdate()
            }
        }
    }

    /// Backoff retry (5s / 30s / 2min, capped) for a failed watched-set update. Previously a failed
    /// update was never retried - the drain block only re-runs on a DIFFERENT pending signature - so
    /// one network hiccup left the indexer's watch list stale until an unrelated trigger.
    private func scheduleWatchedUpdateRetry() {
        updateWatchedPending = false
        watchedUpdateRetryTask?.cancel()
        let delays: [TimeInterval] = [5, 30, 120]
        let delay = delays[min(watchedUpdateRetryAttempt, delays.count - 1)]
        watchedUpdateRetryAttempt += 1
        AppLog.log("[Push] Scheduling watched-update retry #%d in %.0fs", watchedUpdateRetryAttempt, delay)
        watchedUpdateRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.runWatchedUpdate()
        }
    }

    /// What the service holds for this device: a change to any of it is worth an update.
    private func buildWatchedSignature(primaryAddress: String? = nil) -> String {
        let primary = primaryAddress ?? collectPrimaryAddress() ?? ""
        let watchOnly = collectWatchOnlyAddresses().joined(separator: "+")
        return [primary, ApnsEnvironment.current.rawValue, watchOnly, Self.apnsTopic ?? ""].joined(separator: "|")
    }

    /// Unregister device (call on logout/wallet delete)
    /// The push URL changed (e.g. the kachat.duckdns.org -> indexer.kachat.app default migration) but
    /// the OLD service still has this device registered and keeps pushing - the source of
    /// duplicated notifications. One best-effort DELETE against the old base before
    /// registering with the new one; unsigned (legacy backends accept it), single attempt.
    private func unregisterFromSupersededServiceIfNeeded() async {
        guard let token = deviceToken else { return }
        let currentBase = AppSettings.load().pushIndexerURL
        var storedOldBase = UserDefaults.standard.string(forKey: registeredBaseURLDefaultsKey)
        // Devices that migrated BEFORE base-URL tracking existed (the kasia.wtf ->
        // kachat.duckdns.org default flip) have no stored value - sweep the known legacy
        // host once so it stops double-pushing.
        if storedOldBase == nil,
           !UserDefaults.standard.bool(forKey: legacyKasiaUnregisterDoneKey),
           UserDefaults.standard.bool(forKey: registeredDefaultsKey) {
            storedOldBase = "https://indexer.kasia.wtf"
        }
        UserDefaults.standard.set(true, forKey: legacyKasiaUnregisterDoneKey)
        guard let oldBase = storedOldBase,
              !oldBase.isEmpty,
              oldBase != currentBase,
              let url = URL(string: "\(oldBase)\(unregisterEndpoint)") else { return }
        // Clear first - one attempt per supersession, a dead old host must not retry forever.
        UserDefaults.standard.removeObject(forKey: registeredBaseURLDefaultsKey)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "DELETE"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try? JSONEncoder().encode(PushUnregisterRequest(deviceToken: token, auth: nil))
        urlRequest.timeoutInterval = 20
        _ = try? await URLSession.shared.data(for: urlRequest)
        AppLog.log("[Push] Sent unregister to superseded push service: %@", oldBase)
    }

    /// On a network with no push service: one DELETE to the service the device last registered
    /// with (unsigned - the signed form binds the address of the network being left, and this
    /// one is the other encoding), then the device counts as unregistered. Messages that still
    /// arrive from it are dropped by the network check in the extension and the app.
    private func leavePushServiceOfOtherNetworkIfNeeded() async {
        let defaults = UserDefaults.standard
        let registeredBase = defaults.string(forKey: registeredBaseURLDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isRegistered || defaults.bool(forKey: registeredDefaultsKey) {
            isRegistered = false
            persistRegistrationStatus(false)
        }
        guard !registeredBase.isEmpty else { return }
        defaults.removeObject(forKey: registeredBaseURLDefaultsKey)
        guard let token = deviceToken,
              let url = URL(string: "\(registeredBase)\(unregisterEndpoint)") else { return }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "DELETE"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try? JSONEncoder().encode(PushUnregisterRequest(deviceToken: token, auth: nil))
        urlRequest.timeoutInterval = 20
        _ = try? await URLSession.shared.data(for: urlRequest)
        AppLog.log("[Push] No push service on this network; sent unregister to %@", registeredBase)
    }

    func unregister() async {
        guard let token = deviceToken else { return }
        guard hasPushService else {
            await leavePushServiceOfOtherNetworkIfNeeded()
            return
        }

        let settings = AppSettings.load()

        guard let url = URL(string: "\(settings.pushIndexerURL)\(unregisterEndpoint)") else {
            AppLog.log("[Push] Invalid push service URL: %@", settings.pushIndexerURL)
            return
        }

        do {
            let auth: PushAuthRequest?
            do {
                auth = try await buildPushAuth(
                    method: "DELETE",
                    path: unregisterEndpoint,
                    deviceToken: token,
                    primaryAddress: nil
                )
            } catch {
                // Best-effort fallback for mixed/legacy backend mode.
                AppLog.log("[Push] Failed to build auth for unregister, trying unsigned request: %@", error.localizedDescription)
                auth = nil
            }

            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "DELETE"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONEncoder().encode(
                PushUnregisterRequest(deviceToken: token, auth: auth)
            )
            urlRequest.timeoutInterval = 30

            let (responseData, response) = try await URLSession.shared.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                AppLog.log("[Push] Error unregistering: invalid response")
                return
            }
            if httpResponse.statusCode == 200 {
                isRegistered = false
                persistRegistrationStatus(false)
                lastError = nil
                clearWalletBindingConflictCooldown()
                AppLog.log("[Push] Unregistered from indexer")
                return
            }

            let reason = parseIndexerError(from: responseData) ?? "unknown"
            if isWalletBindingConflict(statusCode: httpResponse.statusCode, reason: reason) {
                activateWalletBindingConflictCooldown(reason: reason)
            }
            if (400...499).contains(httpResponse.statusCode) {
                // Local token/state is stale or invalid for this backend; stop retry loops.
                isRegistered = false
                persistRegistrationStatus(false)
            }
            AppLog.log("[Push] Failed to unregister: status=%d reason=%@", httpResponse.statusCode, reason)
        } catch {
            AppLog.log("[Push] Error unregistering: %@", error.localizedDescription)
        }
    }

    // MARK: - Private Helpers

    private func loadPersistedState() {
        // Try Keychain first, then migrate from UserDefaults if needed
        if let keychainToken = loadTokenFromKeychain() {
            deviceToken = keychainToken
        } else {
            // Migration: check UserDefaults for legacy token
            let defaults = UserDefaults.standard
            if let legacyToken = defaults.string(forKey: tokenDefaultsKey) {
                deviceToken = legacyToken
                saveTokenToKeychain(legacyToken)
                defaults.removeObject(forKey: tokenDefaultsKey)
            }
        }
        let storedRegistered = UserDefaults.standard.bool(forKey: registeredDefaultsKey)
        isRegistered = storedRegistered && deviceToken != nil

        // A device that crossed APNs environments (developer installs a TestFlight build over an
        // Xcode build, or vice versa) holds a server record pinned to the OLD environment and a
        // token the old endpoint will reject. `refreshRegistrationIfNeeded()` would only PUT an
        // update in that state; invalidate the cached status so it performs a FULL re-register.
        let storedEnvironment = UserDefaults.standard.string(forKey: registeredApnsEnvironmentDefaultsKey)
        if isRegistered,
           let storedEnvironment,
           storedEnvironment != ApnsEnvironment.current.rawValue {
            AppLog.log("[Push] APNs environment changed (%@ -> %@) - forcing re-registration",
                       storedEnvironment,
                       ApnsEnvironment.current.rawValue)
            isRegistered = false
            persistRegistrationStatus(false)
            // The saved token belongs to the OTHER environment - it lives in the Keychain, which
            // survives installing an Xcode build over TestFlight (or back). Registering it again
            // labelled with the new environment sent every push to the wrong APNs host with a
            // token that host rejects. Drop it, so the next refresh asks iOS for this build's
            // token and registers that.
            deviceToken = nil
        }

        // Same on a new build. The "registered" flag survives an app update, but whether the
        // service still holds a working record for this device does not always (a token
        // reissued with the install, a server that dropped the row); a beta that stopped
        // pinging until notifications were toggled off and on was this. One full register per
        // build is cheap insurance.
        let storedBuild = UserDefaults.standard.string(forKey: registeredBuildDefaultsKey)
        if isRegistered, storedBuild != Self.currentBuildIdentifier {
            AppLog.log("[Push] App build changed (%@ -> %@) - forcing re-registration",
                       storedBuild ?? "none", Self.currentBuildIdentifier)
            isRegistered = false
            persistRegistrationStatus(false)
        }
    }

    /// "version (build)" of the running app, the unit a beta install changes.
    private static var currentBuildIdentifier: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func persistDeviceToken(_ token: String) {
        saveTokenToKeychain(token)
    }

    // MARK: - Keychain Helpers (Push Token)

    private static let keychainService = "com.kachat.wallet"
    private static let keychainAccount = "push_device_token"
    private static let deviceAuthKeychainAccount = "push_device_auth_private_key"

    private func saveTokenToKeychain(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount
        ]
        // Delete existing item first
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecAttrSynchronizable as String] = kCFBooleanFalse!
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func loadTokenFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func saveDeviceAuthPrivateKeyToKeychain(_ keyData: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.deviceAuthKeychainAccount
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = keyData
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecAttrSynchronizable as String] = kCFBooleanFalse!
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func loadDeviceAuthPrivateKeyFromKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.deviceAuthKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    private func nextDeviceAuthCounter() -> UInt64 {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: deviceAuthCounterDefaultsKey) as? NSNumber
        let next = previous?.uint64Value ?? 0
        let advanced = next &+ 1
        defaults.set(NSNumber(value: advanced), forKey: deviceAuthCounterDefaultsKey)
        return advanced
    }

    private func persistRegistrationStatus(_ isRegistered: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(isRegistered, forKey: registeredDefaultsKey)
    }

    private func checkPermissionStatus() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        permissionStatus = settings.authorizationStatus
        refreshRegistrationIfNeeded()
    }

    private func observeSettingsChanges() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshRegistrationIfNeeded()
            }
        }
    }

    /// The wallet's own addresses for "Received" pushes (see
    /// `AddressActivityNotifier.pushWatchOnlyAddresses`).
    private func collectWatchOnlyAddresses() -> [String] {
        AddressActivityNotifier.shared.pushWatchOnlyAddresses()
    }

    /// The APNs topic this build's device token belongs to - its bundle id. Sent at register and
    /// update so a push service shared by several apps (KaChat, KaPay, ...) sends
    /// with the right `apns-topic` (PUSH_SERVICE.md).
    static let apnsTopic: String? = Bundle.main.bundleIdentifier

    private func collectPrimaryAddress() -> String? {
        WalletManager.shared.currentWallet?.publicAddress
    }

    /// Whether this device has anything to register for. The chatting address alone is enough -
    /// .kachat name events go to `primary_address` whether or not Address Activity (the
    /// watch-only list) is on, so switching that off must not unregister the device.
    private func hasPushSubscriptions(watchOnlyAddresses: [String]? = nil, primaryAddress: String? = nil) -> Bool {
        if !(watchOnlyAddresses ?? collectWatchOnlyAddresses()).isEmpty { return true }
        return (primaryAddress ?? collectPrimaryAddress()) != nil
    }

    private func buildPushAuth(
        method: String,
        path: String,
        deviceToken: String,
        primaryAddress: String?
    ) async throws -> PushAuthRequest {
        guard let wallet = WalletManager.shared.currentWallet else {
            throw PushError.authFailed(reason: "No active wallet")
        }

        guard let privateKey = try KeychainService.shared.loadPrivateKey() else {
            throw PushError.authFailed(reason: "Wallet private key is missing")
        }

        let settings = AppSettings.load()
        let challenge = try await fetchPushChallenge(baseURL: settings.pushIndexerURL)

        let walletPubkey = wallet.publicKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard walletPubkey.count == 64, isHexString(walletPubkey) else {
            throw PushError.authFailed(reason: "Wallet public key must be 32-byte hex")
        }

        guard let walletAddress = canonicalAddressForAuth(wallet.publicAddress, network: settings.networkType) else {
            throw PushError.authFailed(reason: "Wallet address is invalid")
        }

        let normalizedDeviceToken = try normalizeDeviceTokenForAuth(deviceToken)
        let normalizedPrimaryAddress = canonicalAddressForAuth(primaryAddress, network: settings.networkType) ?? ""
        let localTimestampMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let timestampMs = min(
            max(localTimestampMs, challenge.issuedAtMs),
            challenge.expiresAtMs
        )

        let preimage = buildAuthPreimage(
            nonce: challenge.nonce,
            method: method,
            path: path,
            deviceToken: normalizedDeviceToken,
            primaryAddress: normalizedPrimaryAddress,
            walletPubkey: walletPubkey,
            walletAddress: walletAddress,
            timestampMs: timestampMs,
            expiresAtMs: challenge.expiresAtMs
        )

        var signingMaterial = privateKey
        defer { signingMaterial.zeroOut() }
        let signingKey = try P256K.Schnorr.PrivateKey(dataRepresentation: signingMaterial)

        let digest = Data(CryptoKit.SHA256.hash(data: Data(preimage.utf8)))
        var message = [UInt8](digest)
        defer {
            for index in message.indices {
                message[index] = 0
            }
        }
        let signature = try signingKey.signature(message: &message, auxiliaryRand: nil)
        let deviceAuth = try buildDeviceAuthProof(
            nonce: challenge.nonce,
            method: method,
            path: path,
            normalizedDeviceToken: normalizedDeviceToken,
            timestampMs: timestampMs,
            expiresAtMs: challenge.expiresAtMs
        )
        let deviceCheckToken = await generateDeviceCheckToken()

        return PushAuthRequest(
            walletPubkey: walletPubkey,
            walletAddress: walletAddress,
            nonce: challenge.nonce,
            timestampMs: timestampMs,
            expiresAtMs: challenge.expiresAtMs,
            signature: Data(signature.bytes).hexString,
            devicecheckToken: deviceCheckToken,
            deviceAuth: PushDeviceAuthRequest(
                scheme: deviceAuth.scheme,
                keyId: deviceAuth.keyId,
                pubkey: deviceAuth.pubkey,
                counter: deviceAuth.counter,
                signature: deviceAuth.signature
            )
        )
    }

    private func fetchPushChallenge(baseURL: String) async throws -> PushChallengeResponse {
        guard let url = URL(string: "\(baseURL)\(challengeEndpoint)") else {
            AppLog.log("[Push] Invalid push service URL: %@", baseURL)
            throw PushError.invalidResponse
        }
        for attempt in 0..<3 {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15

            do {
                let (responseData, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw PushError.invalidResponse
                }

                guard httpResponse.statusCode == 200 else {
                    let reason = parseIndexerError(from: responseData) ?? "unknown"
                    throw PushError.authFailed(
                        reason: "Challenge failed (status: \(httpResponse.statusCode)): \(reason)"
                    )
                }

                do {
                    return try JSONDecoder().decode(PushChallengeResponse.self, from: responseData)
                } catch {
                    throw PushError.authFailed(reason: "Invalid challenge response")
                }
            } catch let urlError as URLError where isTransientChallengeNetworkError(urlError) && attempt < 2 {
                let delayNs = UInt64((attempt + 1) * 300_000_000)
                try? await Task.sleep(nanoseconds: delayNs)
                continue
            }
        }
        throw PushError.authFailed(reason: "Failed to fetch challenge")
    }

    private func isTransientChallengeNetworkError(_ error: URLError) -> Bool {
        switch error.code {
        case .networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    /// The signed preimage the service checks. The chat fields (watched addresses, group ids,
    /// aliases) are part of it and are always empty here: their hashes are of the empty list.
    private func buildAuthPreimage(
        nonce: String,
        method: String,
        path: String,
        deviceToken: String,
        primaryAddress: String,
        walletPubkey: String,
        walletAddress: String,
        timestampMs: UInt64,
        expiresAtMs: UInt64
    ) -> String {
        let emptyListHash = sha256Hex("")
        let deviceTokenHash = sha256Hex(deviceToken)
        return [
            "domain=\(pushAuthDomain)",
            "nonce=\(nonce.trimmingCharacters(in: .whitespacesAndNewlines))",
            "method=\(method)",
            "path=\(path)",
            "device_token_hash=\(deviceTokenHash)",
            "watched_addresses_hash=\(emptyListHash)",
            "watched_group_ids_hash=\(emptyListHash)",
            "primary_address=\(primaryAddress)",
            "aliases_hash=\(emptyListHash)",
            "wallet_pubkey=\(walletPubkey)",
            "wallet_address=\(walletAddress)",
            "timestamp_ms=\(timestampMs)",
            "expires_at_ms=\(expiresAtMs)"
        ].joined(separator: "\n")
    }

    private struct DeviceKeyMaterial {
        let privateKey: P256.Signing.PrivateKey
        let publicKeyData: Data
        let keyId: String
    }

    private struct DeviceAuthProof {
        let scheme: String
        let keyId: String
        let pubkey: String
        let counter: UInt64
        let signature: String
    }

    private func loadOrCreateDeviceKeyMaterial() throws -> DeviceKeyMaterial {
        if let keyData = loadDeviceAuthPrivateKeyFromKeychain(),
           let privateKey = try? P256.Signing.PrivateKey(rawRepresentation: keyData) {
            let publicKeyData = privateKey.publicKey.x963Representation
            let keyId = Data(CryptoKit.SHA256.hash(data: publicKeyData)).hexString
            return DeviceKeyMaterial(privateKey: privateKey, publicKeyData: publicKeyData, keyId: keyId)
        }

        let privateKey = P256.Signing.PrivateKey()
        let keyData = privateKey.rawRepresentation
        saveDeviceAuthPrivateKeyToKeychain(keyData)
        let publicKeyData = privateKey.publicKey.x963Representation
        let keyId = Data(CryptoKit.SHA256.hash(data: publicKeyData)).hexString
        return DeviceKeyMaterial(privateKey: privateKey, publicKeyData: publicKeyData, keyId: keyId)
    }

    private func buildDeviceAuthPreimage(
        nonce: String,
        method: String,
        path: String,
        deviceToken: String,
        keyId: String,
        counter: UInt64,
        timestampMs: UInt64,
        expiresAtMs: UInt64
    ) -> String {
        let deviceTokenHash = sha256Hex(deviceToken)
        return [
            "domain=\(pushDeviceAuthDomain)",
            "nonce=\(nonce.trimmingCharacters(in: .whitespacesAndNewlines))",
            "method=\(method)",
            "path=\(path)",
            "device_token_hash=\(deviceTokenHash)",
            "key_id=\(keyId)",
            "counter=\(counter)",
            "timestamp_ms=\(timestampMs)",
            "expires_at_ms=\(expiresAtMs)"
        ].joined(separator: "\n")
    }

    private func buildDeviceAuthProof(
        nonce: String,
        method: String,
        path: String,
        normalizedDeviceToken: String,
        timestampMs: UInt64,
        expiresAtMs: UInt64
    ) throws -> DeviceAuthProof {
        let material = try loadOrCreateDeviceKeyMaterial()
        let counter = nextDeviceAuthCounter()
        let preimage = buildDeviceAuthPreimage(
            nonce: nonce,
            method: method,
            path: path,
            deviceToken: normalizedDeviceToken,
            keyId: material.keyId,
            counter: counter,
            timestampMs: timestampMs,
            expiresAtMs: expiresAtMs
        )
        let signature = try material.privateKey.signature(for: Data(preimage.utf8))
        return DeviceAuthProof(
            scheme: pushDeviceAuthScheme,
            keyId: material.keyId,
            pubkey: material.publicKeyData.base64EncodedString(),
            counter: counter,
            signature: signature.derRepresentation.base64EncodedString()
        )
    }

    private func generateDeviceCheckToken() async -> String? {
        #if targetEnvironment(simulator)
        return nil
        #else
        guard DCDevice.current.isSupported else {
            return nil
        }
        do {
            return try await DCDevice.current.generateToken().base64EncodedString()
        } catch {
            return nil
        }
        #endif
    }

    private func normalizeDeviceTokenForAuth(_ token: String) throws -> String {
        let cleaned = token.filter { $0.isHexDigit }.lowercased()
        if cleaned.count < 64 || cleaned.count > 512 || cleaned.count % 2 != 0 {
            throw PushError.authFailed(reason: "Invalid device token length")
        }
        return cleaned
    }

    private func canonicalAddressForAuth(_ address: String?, network: NetworkType) -> String? {
        guard var normalized = address?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return nil
        }

        if !normalized.contains(":") {
            let prefix = network == .mainnet ? "kaspa" : "kaspatest"
            normalized = "\(prefix):\(normalized)"
        }

        normalized = normalized.lowercased()
        guard let parsed = KaspaAddress(address: normalized) else {
            return nil
        }
        return parsed.address
    }

    private func sha256Hex(_ value: String) -> String {
        Data(CryptoKit.SHA256.hash(data: Data(value.utf8))).hexString
    }

    private func isHexString(_ value: String) -> Bool {
        let charset = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        return !value.isEmpty && value.unicodeScalars.allSatisfy { charset.contains($0) }
    }

    private func isWalletBindingConflict(statusCode: Int, reason: String?) -> Bool {
        guard statusCode == 401, let reason else { return false }
        return reason.lowercased().contains("bound to another wallet")
    }

    private func currentWalletBindingFingerprint() -> String? {
        guard let token = deviceToken else { return nil }
        guard let walletPubkey = WalletManager.shared.currentWallet?.publicKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !walletPubkey.isEmpty else {
            return nil
        }
        return "\(token)|\(walletPubkey)"
    }

    private func shouldDeferRegistrationForWalletBindingConflict() -> Bool {
        guard let blockedFingerprint = walletBindingConflictFingerprint,
              let blockedUntil = walletBindingConflictUntil else {
            return false
        }
        guard let currentFingerprint = currentWalletBindingFingerprint(),
              currentFingerprint == blockedFingerprint else {
            clearWalletBindingConflictCooldown()
            return false
        }
        let now = Date()
        if now >= blockedUntil {
            clearWalletBindingConflictCooldown()
            return false
        }
        if let lastLog = lastWalletBindingConflictLogAt,
           now.timeIntervalSince(lastLog) < walletBindingConflictLogCooldown {
            return true
        }
        let remainingSeconds = Int(ceil(blockedUntil.timeIntervalSince(now)))
        AppLog.log("[Push] Skipping push registration for %ds due to wallet binding conflict", max(1, remainingSeconds))
        lastWalletBindingConflictLogAt = now
        return true
    }

    private func activateWalletBindingConflictCooldown(reason: String?) {
        guard let fingerprint = currentWalletBindingFingerprint() else { return }
        walletBindingConflictFingerprint = fingerprint
        walletBindingConflictUntil = Date().addingTimeInterval(walletBindingConflictCooldown)
        isRegistered = false
        persistRegistrationStatus(false)

        let now = Date()
        if let lastLog = lastWalletBindingConflictLogAt,
           now.timeIntervalSince(lastLog) < walletBindingConflictLogCooldown {
            return
        }
        lastWalletBindingConflictLogAt = now
        let normalizedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedReason, !normalizedReason.isEmpty {
            AppLog.log("[Push] Token-wallet binding conflict: %@. Deferring retries for %.0f seconds.",
                  normalizedReason,
                  walletBindingConflictCooldown)
        } else {
            AppLog.log("[Push] Token-wallet binding conflict. Deferring retries for %.0f seconds.",
                  walletBindingConflictCooldown)
        }
    }

    private func clearWalletBindingConflictCooldown() {
        walletBindingConflictFingerprint = nil
        walletBindingConflictUntil = nil
        lastWalletBindingConflictLogAt = nil
    }

    private func parseIndexerError(from data: Data) -> String? {
        if let decoded = try? JSONDecoder().decode(PushIndexerErrorResponse.self, from: data) {
            let message = decoded.error.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? nil : message
        }
        if let fallback = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !fallback.isEmpty {
            return fallback
        }
        return nil
    }

}

// MARK: - APNs Environment

/// Which APNs endpoint the device token issued to THIS build belongs to.
///
/// APNs tokens are environment-scoped. A build installed from Xcode gets a *sandbox* token
/// (`api.sandbox.push.apple.com`); TestFlight and App Store builds get a *production* token
/// (`api.push.apple.com`). Sending a token to the wrong endpoint fails silently per device -
/// Apple answers `BadDeviceToken` and nothing is delivered - which is exactly how TestFlight
/// installs ended up receiving no pushes at all while a dev build on the same phone worked.
/// A single global server setting cannot serve both populations, so the app reports its own
/// environment at registration and the server routes per device.
enum ApnsEnvironment: String {
    case development
    case production

    /// Resolved once per process - the answer cannot change without a reinstall.
    static let current: ApnsEnvironment = resolve()

    private static func resolve() -> ApnsEnvironment {
        switch apsEnvironmentEntitlement() {
        case "development": return .development
        case "production": return .production
        default:
            // No embedded profile (or an unexpected value): fall back to the build config.
            #if DEBUG
            return .development
            #else
            return .production
            #endif
        }
    }

    /// Reads `aps-environment` out of the embedded provisioning profile - the accurate runtime
    /// signal for how this binary was signed. (`SecTaskCopyValueForEntitlement` is not public
    /// API on iOS, so the profile is the only supported way to read our own entitlements.)
    ///
    /// `embedded.mobileprovision` is a CMS blob with the profile plist stored as plain XML
    /// inside it, so the plist is sliced out between the XML prologue and the final `</plist>`.
    private static func apsEnvironmentEntitlement() -> String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), options: [.backwards]),
              start.lowerBound < end.upperBound else {
            return nil
        }
        let plistData = Data(data[start.lowerBound..<end.upperBound])
        guard let plist = try? PropertyListSerialization.propertyList(
                from: plistData,
                options: [],
                format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let apsEnvironment = entitlements["aps-environment"] as? String else {
            return nil
        }
        return apsEnvironment
    }
}

// MARK: - Request Models

/// `POST /v1/push/register`. `watched_addresses` (the service requires it) and
/// `watched_group_ids` are KaChat's chat fields, always empty here.
struct PushRegistrationRequest: Encodable {
    let deviceToken: String
    let platform: String
    let primaryAddress: String?
    /// "development" | "production" - which APNs endpoint this device's token is valid for.
    let apnsEnvironment: String
    /// Own addresses to push "Received" for (server "Address Activity").
    let watchOnlyAddresses: [String]
    /// This build's bundle id, the APNs topic its token is valid for.
    let apnsTopic: String?
    let auth: PushAuthRequest?

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
        case platform
        case watchedAddresses = "watched_addresses"
        case watchedGroupIds = "watched_group_ids"
        case primaryAddress = "primary_address"
        case apnsEnvironment = "apns_environment"
        case watchOnlyAddresses = "watch_only_addresses"
        case apnsTopic = "apns_topic"
        case auth
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceToken, forKey: .deviceToken)
        try container.encode(platform, forKey: .platform)
        try container.encode([String](), forKey: .watchedAddresses)
        try container.encode([String](), forKey: .watchedGroupIds)
        try container.encodeIfPresent(primaryAddress, forKey: .primaryAddress)
        try container.encode(apnsEnvironment, forKey: .apnsEnvironment)
        try container.encode(watchOnlyAddresses, forKey: .watchOnlyAddresses)
        try container.encodeIfPresent(apnsTopic, forKey: .apnsTopic)
        try container.encodeIfPresent(auth, forKey: .auth)
    }
}

/// `PUT /v1/push/update`: a full replace of what `PushRegistrationRequest` registered.
struct PushUpdateRequest: Encodable {
    let deviceToken: String
    let primaryAddress: String?
    let apnsEnvironment: String
    let watchOnlyAddresses: [String]
    let apnsTopic: String?
    let auth: PushAuthRequest?

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
        case watchedAddresses = "watched_addresses"
        case watchedGroupIds = "watched_group_ids"
        case primaryAddress = "primary_address"
        case apnsEnvironment = "apns_environment"
        case watchOnlyAddresses = "watch_only_addresses"
        case apnsTopic = "apns_topic"
        case auth
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceToken, forKey: .deviceToken)
        try container.encode([String](), forKey: .watchedAddresses)
        try container.encode([String](), forKey: .watchedGroupIds)
        try container.encodeIfPresent(primaryAddress, forKey: .primaryAddress)
        try container.encode(apnsEnvironment, forKey: .apnsEnvironment)
        try container.encode(watchOnlyAddresses, forKey: .watchOnlyAddresses)
        try container.encodeIfPresent(apnsTopic, forKey: .apnsTopic)
        try container.encodeIfPresent(auth, forKey: .auth)
    }
}

struct PushUnregisterRequest: Codable {
    let deviceToken: String
    let auth: PushAuthRequest?

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
        case auth
    }
}

struct PushAuthRequest: Codable {
    let walletPubkey: String
    let walletAddress: String
    let nonce: String
    let timestampMs: UInt64
    let expiresAtMs: UInt64
    let signature: String
    let devicecheckToken: String?
    let deviceAuth: PushDeviceAuthRequest?

    enum CodingKeys: String, CodingKey {
        case walletPubkey = "wallet_pubkey"
        case walletAddress = "wallet_address"
        case nonce
        case timestampMs = "timestamp_ms"
        case expiresAtMs = "expires_at_ms"
        case signature
        case devicecheckToken = "devicecheck_token"
        case deviceAuth = "device_auth"
    }
}

struct PushDeviceAuthRequest: Codable {
    let scheme: String
    let keyId: String
    let pubkey: String
    let counter: UInt64
    let signature: String

    enum CodingKeys: String, CodingKey {
        case scheme
        case keyId = "key_id"
        case pubkey
        case counter
        case signature
    }
}

private struct PushChallengeResponse: Decodable {
    let nonce: String
    let issuedAtMs: UInt64
    let expiresAtMs: UInt64

    enum CodingKeys: String, CodingKey {
        case nonce
        case issuedAtMs = "issued_at_ms"
        case expiresAtMs = "expires_at_ms"
    }
}

private struct PushIndexerErrorResponse: Decodable {
    let error: String
}

// MARK: - Errors

enum PushError: LocalizedError {
    case permissionDenied
    case noDeviceToken
    case invalidResponse
    case registrationFailed(statusCode: Int, reason: String?)
    case updateFailed
    case registrationTimedOut
    case registrationInProgress
    case noWatchedAddresses
    case authFailed(reason: String)
    case noPushService

    var errorDescription: String? {
        switch self {
        case .noPushService:
            return NSLocalizedString("This network has no push service yet.", comment: "Push error: the current network has no push service address")
        case .permissionDenied:
            return "Notification permission denied"
        case .noDeviceToken:
            return "No device token available. Please enable notifications."
        case .invalidResponse:
            return "Invalid response from server"
        case .registrationFailed(let statusCode, let reason):
            if let reason,
               !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Registration failed (status: \(statusCode)): \(reason)"
            }
            return "Registration failed (status: \(statusCode))"
        case .updateFailed:
            return "Failed to update push registration"
        case .registrationTimedOut:
            return "Push registration timed out"
        case .registrationInProgress:
            return "Push registration already in progress"
        case .noWatchedAddresses:
            return "No addresses available for push notifications"
        case .authFailed(let reason):
            return "Push auth failed: \(reason)"
        }
    }
}
