import Foundation
import LocalAuthentication
import UIKit

/// Gates sensitive actions (viewing the seed phrase, unlocking a saved account, sending Kaspa,
/// deleting an account) behind whatever
/// the device's own lock screen is set to — Face ID/Touch ID, falling back to the device passcode
/// — mirroring Android's `authenticateWithDeviceCredential`.
///
/// A device with no passcode at all used to fall straight through to `onSuccess`: the "gate"
/// on the recovery phrase was then no gate, and anyone holding the unlocked phone could read
/// it. Now it refuses, says why, and calls `onFailure`.
enum DeviceAuth {
    static func authenticate(
        reason: String,
        onSuccess: @escaping () -> Void,
        onFailure: @escaping () -> Void = {}
    ) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            presentPasscodeRequired()
            onFailure()
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            DispatchQueue.main.async {
                if success {
                    onSuccess()
                } else {
                    onFailure()
                }
            }
        }
    }

    /// The window the alert below is shown in, while it's up.
    private static var passcodeAlertWindow: UIWindow?

    /// One alert, from wherever the reveal was asked: the callers are spread over several
    /// screens that have no shared message surface.
    ///
    /// In a window of its own, above the app: several callers close a sheet and ask straight
    /// after (Delete Account's `dismiss(); onConfirm()`, the Wallet's View Private Key), and an
    /// alert presented from that sheet went away with it, or was refused while it was closing.
    private static func presentPasscodeRequired() {
        guard passcodeAlertWindow == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert
        // the app's appearance (Settings' choice), which its own windows carry
        window.overrideUserInterfaceStyle = scene.windows.first?.overrideUserInterfaceStyle ?? .unspecified
        let host = UIViewController()
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        passcodeAlertWindow = window

        let alert = UIAlertController(
            title: "Passcode Required",
            message: "Set a passcode on this iPhone (Settings > Face ID & Passcode) to send Kaspa, delete an account, or view secret keys in KaPay.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            passcodeAlertWindow?.isHidden = true
            passcodeAlertWindow = nil
        })
        // A turn later, once the new window is on screen and can present.
        DispatchQueue.main.async {
            host.present(alert, animated: true)
        }
    }
}
