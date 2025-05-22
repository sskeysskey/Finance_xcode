import SwiftUI
import Foundation

struct Credentials: Codable {
    let username: String
    let password: String
}

struct LoginView: View {
    // @State 属性用于存储用户输入和界面状态
    @State private var usernameInput: String = ""
    @State private var passwordInput: String = ""
    @State private var rememberUsername: Bool = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var isLoggedIn = false // 用于导航到成功页面

    // UserDefaults key
    private let rememberedUsernameKey = "rememberedUsernameKey"

    var body: some View {
        NavigationView {
            if isLoggedIn {
                // 成功登录后显示的视图
                MainTabView(username: usernameInput)
            } else {
                // 登录表单
                ZStack {
                    // 背景颜色，模仿截图的深色背景
                    Color(red: 25/255, green: 30/255, blue: 39/255)
                        .ignoresSafeArea()

                    VStack(spacing: 20) {
                        Spacer().frame(height: 30) // 顶部留白

                        Text("Firstrade 欢迎您")
                            .font(.title2)
                            .foregroundColor(.white)

                        Spacer().frame(height: 30)

                        // 用户名输入框
                        VStack(alignment: .leading, spacing: 5) {
                            Text("登录用户名")
                                .font(.caption)
                                .foregroundColor(.gray)
                            TextField("", text: $usernameInput) // Placeholder 由外部 Text 实现
                                .padding(12)
                                .background(Color(red: 40/255, green: 45/255, blue: 55/255))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                                )
                        }
                        .padding(.horizontal, 30)

                        // 密码输入框
                        VStack(alignment: .leading, spacing: 5) {
                            Text("密码")
                                .font(.caption)
                                .foregroundColor(.gray)
                            HStack {
                                SecureField("", text: $passwordInput) // Placeholder 由外部 Text 实现
                                    .padding(12)
                                    .background(Color(red: 40/255, green: 45/255, blue: 55/255))
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                                    )
                                // 仿照图片中的面容ID图标，这里用一个系统图标代替
                                Image(systemName: "faceid")
                                    .foregroundColor(.gray)
                                    .padding(.trailing, 10)
                            }
                        }
                        .padding(.horizontal, 30)


                        // 记住用户名
                        Toggle(isOn: $rememberUsername) {
                            Text("记住我的用户名")
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 30)
                        .tint(Color(red: 70/255, green: 130/255, blue: 220/255)) // 设置Toggle的颜色

                        // 登录按钮
                        Button(action: login) {
                            Text("登入")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color(red: 70/255, green: 130/255, blue: 220/255))
                                .cornerRadius(8)
                        }
                        .padding(.horizontal, 30)

                        // 忘记密码链接
                        Button(action: forgotPassword) {
                            Text("忘记登入用户名或密码")
                                .font(.footnote)
                                .foregroundColor(Color(red: 70/255, green: 130/255, blue: 220/255))
                        }

                        Spacer() // 将内容推向顶部

                        Text("v3.15.1-3003860")
                            .font(.caption2)
                            .foregroundColor(.gray)
                            .padding(.bottom, 20)
                    }
                }
                .navigationTitle("登入") // 导航栏标题
                .navigationBarTitleDisplayMode(.inline) // 标题居中
                .toolbar { // 添加返回按钮 (虽然在根视图可能不直接显示，但结构上是好的)
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(action: {
                            // 通常用于返回操作，但在此根登录视图中可能不需要
                            // 如果这是从其他地方导航过来的，这里可以 dismiss
                            print("Back button tapped")
                        }) {
                            Image(systemName: "chevron.left")
                                .foregroundColor(Color(red: 70/255, green: 130/255, blue: 220/255))
                        }
                    }
                }
                .alert(isPresented: $showingAlert) { // 登录失败时的弹窗
                    Alert(title: Text("登录失败"), message: Text(alertMessage), dismissButton: .default(Text("好的")))
                }
                .onAppear(perform: loadRememberedUsername) // 视图出现时加载记住的用户名
            }
        }
        .accentColor(Color(red: 70/255, green: 130/255, blue: 220/255)) // 设置 NavigationView 的强调色，影响返回按钮等
    }

    // MARK: - Functions

    func loadCredentials() -> Credentials? {
        // 从 Bundle 中获取 password.json 文件的 URL
        guard let url = Bundle.main.url(forResource: "Password", withExtension: "json") else {
            print("Error: password.json not found.")
            alertMessage = "配置文件丢失。"
            showingAlert = true
            return nil
        }

        do {
            // 读取文件数据
            let data = try Data(contentsOf: url)
            // 解码 JSON 数据到 Credentials 结构体
            let decoder = JSONDecoder()
            let credentials = try decoder.decode(Credentials.self, from: data)
            return credentials
        } catch {
            print("Error decoding password.json: \(error)")
            alertMessage = "无法读取配置：\(error.localizedDescription)"
            showingAlert = true
            return nil
        }
    }

    func login() {
        guard let storedCredentials = loadCredentials() else {
            return // 错误已在 loadCredentials 中处理
        }

        // 验证用户名和密码
        if usernameInput == storedCredentials.username && passwordInput == storedCredentials.password {
            print("Login successful!")
            alertMessage = "登录成功！" // 可以不显示，直接导航
            // showingAlert = true // 如果想显示成功信息

            // 处理“记住用户名”
            if rememberUsername {
                UserDefaults.standard.set(usernameInput, forKey: rememberedUsernameKey)
            } else {
                UserDefaults.standard.removeObject(forKey: rememberedUsernameKey)
            }

            isLoggedIn = true // 触发导航
        } else {
            print("Login failed: Invalid username or password.")
            alertMessage = "用户名或密码错误。"
            showingAlert = true
            passwordInput = "" // 清空密码输入框
        }
    }

    func forgotPassword() {
        print("Forgot password tapped.")
        alertMessage = "“忘记密码”功能尚未实现。"
        showingAlert = true
    }

    func loadRememberedUsername() {
        if let rememberedUser = UserDefaults.standard.string(forKey: rememberedUsernameKey) {
            usernameInput = rememberedUser
            rememberUsername = true // 如果加载了用户名，也应该勾选记住我
        }
    }
}

// MARK: - Success View (Placeholder)
// 成功登录后跳转的视图
struct SuccessView: View {
    @Environment(\.presentationMode) var presentationMode // 用于返回

    var body: some View {
        ZStack {
            Color(red: 25/255, green: 30/255, blue: 39/255)
                .ignoresSafeArea()
            VStack {
                Text("登录成功!")
                    .font(.largeTitle)
                    .foregroundColor(.white)
                Text("欢迎来到 Fristrade!")
                    .font(.title2)
                    .foregroundColor(.gray)
                Spacer().frame(height: 50)
                Button("登出") {
                    // 在实际应用中，这里会清除登录状态并返回到LoginView
                    // 对于这个简单的例子，我们可能需要一种方式来重置 LoginView 的 isLoggedIn 状态
                    // 但由于 isLoggedIn 是 LoginView 的 @State，直接返回并不能重置它
                    // 一个更健壮的解决方案会使用 @EnvironmentObject 或其他状态管理技术
                    // 这里我们简单地关闭这个视图，但它不会自动将 LoginView 的 isLoggedIn 设回 false
                    // 最好的做法是在 App 主结构体中管理登录状态
                    print("Logout tapped - this example doesn't fully reset LoginView's state easily.")
                    // presentationMode.wrappedValue.dismiss() // 这会返回，但 LoginView 仍会认为已登录
                    // 要真正登出并返回登录页，通常需要更改 App 级别的状态
                }
                .padding()
                .foregroundColor(.white)
                .background(Color.red)
                .cornerRadius(8)
            }
        }
        .navigationTitle("主页")
        .navigationBarBackButtonHidden(true) // 隐藏默认返回按钮，因为我们是在导航栈的顶层
    }
}


// MARK: - Preview
struct LoginView_Previews: PreviewProvider {
    static var previews: some View {
        LoginView()
    }
}
