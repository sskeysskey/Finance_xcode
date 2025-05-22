import SwiftUI

@main
struct FristradeAppApp: App {
    // ① 全局状态
    @StateObject private var session = SessionStore()

    var body: some Scene {
        WindowGroup {
            // ② 根据登录状态切换
            if session.isLoggedIn {
                MainTabView()
                    .environmentObject(session)
            } else {
                LoginView()
                    .environmentObject(session)
            }
        }
    }
}
