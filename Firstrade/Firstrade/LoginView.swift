import Foundation
import LocalAuthentication
import Security
import SwiftUI
import Combine

struct Credentials: Codable {
    let username: String
    let password: String
}

final class SessionStore: ObservableObject {
    @Published var isLoggedIn: Bool = false
    @Published var username: String = ""
}

//—————————————————————————————
// 简易 Keychain Helper
//—————————————————————————————
final class KeychainHelper {
    static let shared = KeychainHelper()
    private init() {}

    func save(_ string: String, service: String, account: String) {
        let data = Data(string.utf8)
        delete(service: service, account: account)  // 先删
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
            let data = item as? Data,
            let str = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return str
    }

    func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

//—————————————————————————————
// LoginView.swift
//—————————————————————————————
struct LoginView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var usernameInput: String = ""
    @State private var passwordInput: String = ""
    @State private var isPasswordPlaceholder: Bool = false
    @State private var actualPassword: String = ""
    @State private var rememberAll: Bool = false

    @State private var showingAlert = false
    @State private var alertMessage = ""

    private let userKey = "rememberedUsernameKey"
    private let pwdAccount = "rememberedPasswordKey"
    private let keychainService = Bundle.main.bundleIdentifier ?? "com.myapp.login"

    var body: some View {
        NavigationView {
            if session.isLoggedIn {
                MainTabView()
            } else {
                ZStack {
                    Color(red: 25 / 255, green: 30 / 255, blue: 39 / 255)
                        .ignoresSafeArea()
                    VStack(spacing: 20) {
                        Spacer().frame(height: 30)
                        Text("Welcome")
                            .font(.title2).foregroundColor(.white)
                        Spacer().frame(height: 30)

                        // 用户名
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Username")
                                .font(.caption).foregroundColor(.gray)
                            TextField("", text: $usernameInput)
                                .padding(12)
                                .background(Color(red: 40 / 255, green: 45 / 255, blue: 55 / 255))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.gray.opacity(0.5), lineWidth: 1))
                        }
                        .padding(.horizontal, 30)

                        // 密码 + Face ID 按钮
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Passowrd")
                                .font(.caption).foregroundColor(.gray)
                            HStack {
                                if isPasswordPlaceholder {
                                    Text("******")
                                        .padding(12)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(
                                            Color(red: 40 / 255, green: 45 / 255, blue: 55 / 255)
                                        )
                                        .foregroundColor(.white.opacity(0.7))
                                        .cornerRadius(8)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                                        )
                                        .onTapGesture {
                                            isPasswordPlaceholder = false
                                            passwordInput = ""
                                        }
                                } else {
                                    SecureField("", text: $passwordInput)
                                        .padding(12)
                                        .background(
                                            Color(red: 40 / 255, green: 45 / 255, blue: 55 / 255)
                                        )
                                        .foregroundColor(.white)
                                        .cornerRadius(8)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.gray.opacity(0.5), lineWidth: 1))
                                }

                                // ← 把 Image 换成 Button
                                Button(action: authenticateWithBiometrics) {
                                    Image(systemName: "Face ID")
                                        .font(.system(size: 24))
                                        .foregroundColor(.gray)
                                        .padding(.trailing, 10)
                                }
                            }
                        }
                        .padding(.horizontal, 30)

                        Toggle(isOn: $rememberAll) {
                            Text("Remember me")
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 30)
                        .tint(Color(red: 70 / 255, green: 130 / 255, blue: 220 / 255))

                        Button(action: login) {
                            Text("Log In")
                                .font(.headline).foregroundColor(.white)
                                .frame(maxWidth: .infinity).padding()
                                .background(Color(red: 70 / 255, green: 130 / 255, blue: 220 / 255))
                                .cornerRadius(8)
                        }
                        .padding(.horizontal, 30)

                        Button(action: {
                            alertMessage = "Error Code 466"
                            showingAlert = true
                        }) {
                            Text("Forgot username&password")
                                .font(.footnote)
                                .foregroundColor(
                                    Color(red: 70 / 255, green: 130 / 255, blue: 220 / 255))
                        }

                        Spacer()
                        Text("v3.15.1-3003860")
                            .font(.caption2).foregroundColor(.gray)
                            .padding(.bottom, 20)
                    }
                }
                .navigationTitle("Login")
                .navigationBarTitleDisplayMode(.inline)
                .alert(isPresented: $showingAlert) {
                    Alert(
                        title: Text("Tips"),
                        message: Text(alertMessage),
                        dismissButton: .default(Text("OK")))
                }
                .onAppear(perform: loadRemembered)
                .alert(isPresented: $showingAlert) {
                    Alert(title: Text("Tips"),
                          message: Text(alertMessage),
                          dismissButton: .default(Text("OK")))
                }
            }
        }
        .accentColor(Color(red: 70 / 255, green: 130 / 255, blue: 220 / 255))
    }

    // MARK: ———————— 生物识别认证 ————————
    private func authenticateWithBiometrics() {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        // 1. 检查设备是否支持
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            let reason = "Use Face ID"
            context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            ) { success, evalError in
                DispatchQueue.main.async {
                    if success {
                        // 2. 读取 Keychain 密码
                        guard
                            let pw = KeychainHelper.shared.read(
                                service: keychainService,
                                account: pwdAccount)
                        else {
                            alertMessage = "no password, check 'remember me' first."
                            showingAlert = true
                            return
                        }
                        // 填回界面
                        actualPassword = pw
                        isPasswordPlaceholder = true
                        passwordInput = pw
                        // 3. 自动触发登录
                        login()
                    } else {
                        alertMessage = "Verified failed."
                        showingAlert = true
                    }
                }
            }
        } else {
            alertMessage = "Not Support Face ID"
            showingAlert = true
        }
    }

    // MARK: ———————— 原有加载/登录流程 ————————
    private func loadRemembered() {
        if let u = UserDefaults.standard.string(forKey: userKey),
            let pw = KeychainHelper.shared.read(service: keychainService, account: pwdAccount)
        {
            usernameInput = u
            actualPassword = pw
            passwordInput = pw
            isPasswordPlaceholder = true
            rememberAll = true
        }
    }

    private func login() {
        // 从 JSON 里加载正确凭证
        guard let stored = loadCredentials() else { return }
        // 如果在“占位”态，则用 actualPassword，否则用用户新输入的 passwordInput
        let attemptPwd = isPasswordPlaceholder ? actualPassword : passwordInput
        if usernameInput == stored.username && attemptPwd == stored.password {
            // 记住凭证
            if rememberAll {
                UserDefaults.standard.set(usernameInput, forKey: userKey)
                KeychainHelper.shared.save(
                    stored.password,
                    service: keychainService,
                    account: pwdAccount)
            } else {
                UserDefaults.standard.removeObject(forKey: userKey)
                KeychainHelper.shared.delete(
                    service: keychainService,
                    account: pwdAccount)
            }
            // ← 登录成功，写入全局 Session
            session.username = usernameInput
            session.isLoggedIn = true

        } else {
            alertMessage = "Name&Password Wrong"
            showingAlert = true
            isPasswordPlaceholder = false
            passwordInput = ""
        }
    }

    // … 生物识别逻辑保持不变，只要最终调用 login() 即可 …
    private func loadCredentials() -> Credentials? {
        guard
            let url = Bundle.main.url(forResource: "Password", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let creds = try? JSONDecoder().decode(Credentials.self, from: data)
        else {
            alertMessage = "profile lost or Setting Wrong"
            showingAlert = true
            return nil
        }
        return creds
    }
}
