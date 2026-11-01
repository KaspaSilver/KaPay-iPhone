import SwiftUI

struct ContentView: View {
    @EnvironmentObject var walletManager: WalletManager
    /// Bumped on every sign-out, so the next account gets new tabs. Without it SwiftUI brought the
    /// old tabs back as they were: on Settings (where Log Out is), without an onAppear to start
    /// polling for the new account.
    @State private var signInSession = 0

    var body: some View {
        Group {
            switch LaunchRouter.route(
                isWalletMetadataLoading: walletManager.isLoading,
                hasCurrentWallet: walletManager.currentWallet != nil,
                isPendingSeedPhraseConfirmation: walletManager.isAwaitingSeedPhraseConfirmation,
                needsKeyRecovery: walletManager.walletNeedingKeyRecovery != nil
            ) {
            case .loading:
                LoadingView()
            case .mainApp:
                MainTabView()
                    .id(signInSession)
            case .onboarding:
                OnboardingView()
            case .recovery:
                if let wallet = walletManager.walletNeedingKeyRecovery {
                    WalletRecoveryView(wallet: wallet)
                } else {
                    OnboardingView()
                }
            }
        }
        .animation(
            .easeInOut,
            value: walletManager.currentWallet != nil && !walletManager.isAwaitingSeedPhraseConfirmation
        )
        .onChange(of: walletManager.currentWallet == nil) { signedOut in
            if signedOut { signInSession += 1 }
        }
        .onAppear { LaunchTrace.mark("first screen on") }
    }
}

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading...")
                .font(.headline)
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(WalletManager.shared)
        .environmentObject(WalletService.shared)
        .environmentObject(SettingsViewModel())
}
