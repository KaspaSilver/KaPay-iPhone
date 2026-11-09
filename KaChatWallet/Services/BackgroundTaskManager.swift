import Foundation
import BackgroundTasks
import UserNotifications

/// Manages the background fetch task that refreshes the balance while the app is in the background
@MainActor
final class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()

    /// Background task identifier - must match Info.plist entry
    static let backgroundFetchTaskIdentifier = "com.kachat.wallet.messageFetch"

    /// Requested refresh interval (iOS may adjust based on battery/usage patterns)
    private let refreshInterval: TimeInterval = 60

    private init() {}

    /// Register the background task handler - call once at app launch
    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundFetchTaskIdentifier,
            using: nil
        ) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                await self.handleBackgroundFetch(task: refresh)
            }
        }
        AppLog.log("%@", "[BackgroundTaskManager] Registered background fetch task")
    }

    /// Schedule the next background fetch - call when app goes to background
    func scheduleBackgroundFetch() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundFetchTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: refreshInterval)

        do {
            try BGTaskScheduler.shared.submit(request)
            AppLog.log("%@", "[BackgroundTaskManager] Scheduled background fetch for ~\(Int(refreshInterval))s from now")
        } catch {
            AppLog.log("%@", "[BackgroundTaskManager] Failed to schedule background fetch: \(error.localizedDescription)")
        }
    }

    /// Cancel any pending background fetch tasks
    func cancelBackgroundFetch() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundFetchTaskIdentifier)
        AppLog.log("%@", "[BackgroundTaskManager] Cancelled background fetch")
    }

    /// Handle the background fetch task.
    ///
    /// The work runs in its own `Task` so the expiration handler can cancel it: iOS grants a
    /// short window, and an app still working after that window closes is what gets it fewer
    /// windows later. The task is completed exactly once, whichever side gets there first.
    private func handleBackgroundFetch(task: BGAppRefreshTask) async {
        AppLog.log("%@", "[BackgroundTaskManager] Background fetch started")

        // Schedule the next fetch before doing work
        scheduleBackgroundFetch()

        let completion = OnceCompletion(task: task)
        let work = Task { @MainActor in
            // Check if background fetch is enabled in settings
            guard WalletService.shared.settingsViewModel?.settings.backgroundFetchEnabled == true else {
                AppLog.log("%@", "[BackgroundTaskManager] Background fetch disabled, skipping fetch")
                return true
            }

            // Refresh the balance and catch up any receive to the wallet's own addresses that
            // landed while it was closed.
            _ = try? await WalletManager.shared.refreshBalance(force: true)
            await AddressActivityNotifier.shared.runCatchUpIfNeeded()
            guard !Task.isCancelled else { return false }
            AppLog.log("%@", "[BackgroundTaskManager] Background fetch completed successfully")
            return true
        }

        task.expirationHandler = {
            AppLog.log("%@", "[BackgroundTaskManager] Background fetch expired; stopping")
            work.cancel()
            completion.complete(success: false)
        }

        let success = await work.value
        completion.complete(success: success)
    }

    /// `BGTask.setTaskCompleted` may be called once; the expiration handler and the finished
    /// work can race for it, from different threads.
    private final class OnceCompletion: @unchecked Sendable {
        private let task: BGAppRefreshTask
        private let lock = NSLock()
        private var done = false

        init(task: BGAppRefreshTask) { self.task = task }

        func complete(success: Bool) {
            lock.lock()
            let already = done
            done = true
            lock.unlock()
            guard !already else { return }
            task.setTaskCompleted(success: success)
        }
    }
}
