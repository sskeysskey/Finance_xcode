import SwiftUI

struct MyView: View {
    @EnvironmentObject private var session: SessionStore

    // 与 LoginView 保持一致
    private let userKey = "rememberedUsernameKey"
    private let pwdAccount = "rememberedPasswordKey"
    private let keychainService = Bundle.main.bundleIdentifier ?? "com.myapp.login"

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        Image(systemName: "person.circle.fill")
                            .resizable()
                            .frame(width: 60, height: 60)
                            .foregroundColor(.gray)
                        VStack(alignment: .leading) {
                            Text(session.username)
                                .font(.title2)
                                .foregroundColor(.white)
                            Text("欢迎您")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    .listRowBackground(Color(red: 25/255, green: 30/255, blue: 39/255))
                }

                Section {
                    NavigationLink("个人资料", destination: Text("个人资料页面"))
                    NavigationLink("安全设置", destination: Text("安全设置页面"))
                    NavigationLink("关于我们", destination: Text("关于我们页面"))
                }

                Section {
                    Button(role: .destructive, action: logout) {
                        Text("登出")
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())
            .background(Color(red: 25/255, green: 30/255, blue: 39/255).ignoresSafeArea())
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func logout() {
        // 清除本地记忆
//        UserDefaults.standard.removeObject(forKey: userKey)
//        KeychainHelper.shared.delete(service: keychainService,
//                                     account: pwdAccount)
        // 回到登录页
        session.isLoggedIn = false
        session.username = ""
    }
}
