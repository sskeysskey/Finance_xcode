import SwiftUI

@main
struct FristradeAppApp: App { // 确保这里的名字和你的项目名一致
    var body: some Scene {
        WindowGroup {
            LoginView() // 或者 ContentView() 如果你没改名
        }
    }
}
