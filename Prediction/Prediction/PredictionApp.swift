import SwiftUI

@main
struct PredictionApp: App {
    @StateObject private var syncManager = SyncManager()
    @StateObject private var authManager = AuthManager()
    @StateObject private var prefManager = PreferenceManager()
    
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    
    var body: some Scene {
        WindowGroup {
            Group {
                if syncManager.showForceUpdate {
                    ForceUpdateView(storeURL: syncManager.appStoreURL)
                } else if !hasCompletedOnboarding {
                    WelcomeView(hasCompletedOnboarding: $hasCompletedOnboarding)
                } else {
                    MainContainerView()
                }
            }
            .environmentObject(syncManager)
            .environmentObject(authManager)
            .environmentObject(prefManager)
            .preferredColorScheme(.dark)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                authManager.handleAppDidBecomeActive()
            }
        }
    }
}