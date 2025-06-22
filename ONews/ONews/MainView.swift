import SwiftUI

struct MainAppView: View {
    // 使用 @State 来管理是否已认证的状态
    @State private var isAuthenticated = false

    var body: some View {
        if isAuthenticated {
            // 如果已认证，显示主新闻阅读器界面
            // fullScreenCover 会全屏展示，并允许用户通过下拉手势返回（如果需要）
            SourceListView(isAuthenticated: $isAuthenticated)
        } else {
            // 否则，显示一个简单的登录界面
            LoginView(isAuthenticated: $isAuthenticated)
        }
    }
}

// 登录界面
struct LoginView: View {
    // 使用 @Binding 来接收和修改父视图的 isAuthenticated 状态
    @Binding var isAuthenticated: Bool

    var body: some View {
        VStack(spacing: 20) {
            Text("登录/验证")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Button(action: {
                // 点击按钮时，将状态设置为 true，从而切换到主界面
                isAuthenticated = true
            }) {
                Text("登录")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .frame(width: 200, height: 50)
                    .background(Color.blue)
                    .cornerRadius(10)
            }
        }
    }
}
