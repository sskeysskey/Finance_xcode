import SwiftUI
import AuthenticationServices
import Security

// 定义 Keychain 操作的错误类型
enum KeychainError: Error {
    case duplicateItem
    case unknown(OSStatus)
    case dataConversionError
    case itemNotFound
}

@MainActor
class AuthManager: NSObject, ObservableObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    
    @Published var isLoggedIn: Bool = false
    @Published var isLoggingIn: Bool = false
    @Published var errorMessage: String?

    // 存储从 Apple 获取的用户唯一标识符
    private(set) var userIdentifier: String?
    
    private let userIdentifierKey = "com.yourapp.onews.userIdentifier"
    private let serverURL = URL(string: "http://106.15.183.158:5001/api/ONews/auth/apple")!

    override init() {
        super.init()
        // 应用启动时检查钥匙串中是否已有登录凭证
        checkUserInKeychain()
    }

    // 检查钥匙串中的用户状态
    private func checkUserInKeychain() {
        do {
            if let userId = try loadUserIdentifierFromKeychain() {
                self.userIdentifier = userId
                self.isLoggedIn = true
                print("AuthManager: 用户已登录，User ID: \(userId)")
            } else {
                self.isLoggedIn = false
                print("AuthManager: 未找到本地登录凭证，用户为登出状态。")
            }
        } catch {
            self.isLoggedIn = false
            print("AuthManager: 检查钥匙串时出错: \(error.localizedDescription)")
        }
    }

    // 触发 Apple 登录流程
    func signInWithApple() {
        guard !isLoggingIn else { return }
        isLoggingIn = true
        errorMessage = nil
        
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email] // 请求获取用户全名和邮箱

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }
    
    // 登出
    func signOut() {
        do {
            try deleteUserIdentifierFromKeychain()
            self.userIdentifier = nil
            self.isLoggedIn = false
            print("AuthManager: 用户已成功登出。")
        } catch {
            // 即使删除失败，也在 UI 上表现为登出
            self.userIdentifier = nil
            self.isLoggedIn = false
            print("AuthManager: 从钥匙串删除用户凭证时出错: \(error.localizedDescription)")
        }
    }

    // MARK: - ASAuthorizationControllerDelegate

    // 授权成功回调
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        if let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential {
            guard let identityTokenData = appleIDCredential.identityToken,
                  let identityToken = String(data: identityTokenData, encoding: .utf8) else {
                handleSignInError("无法获取 Identity Token。")
                return
            }
            
            let userId = appleIDCredential.user
            
            // 发送 Token 和 UserID 到服务器进行验证和注册
            Task {
                do {
                    try await sendTokenToServer(token: identityToken, userId: userId)
                    // 服务器验证成功后，在本地保存用户凭证
                    try saveUserIdentifierToKeychain(userId)
                    
                    // 更新 UI 状态
                    await MainActor.run {
                        self.userIdentifier = userId
                        self.isLoggedIn = true
                        self.isLoggingIn = false
                        print("AuthManager: Apple 登录成功并已在服务器注册。")
                    }
                } catch {
                    handleSignInError("服务器验证失败: \(error.localizedDescription)")
                }
            }
        } else {
            handleSignInError("获取 Apple ID 凭证失败。")
        }
    }

    // 授权失败回调
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        // 用户取消登录操作不算作错误
        if (error as? ASAuthorizationError)?.code == .canceled {
            print("AuthManager: 用户取消了 Apple 登录。")
            handleSignInError(nil) // nil 表示是用户主动取消，不显示错误信息
        } else {
            print("AuthManager: Apple 登录授权失败: \(error.localizedDescription)")
            handleSignInError("登录失败，请稍后重试。")
        }
    }
    
    private func handleSignInError(_ message: String?) {
        DispatchQueue.main.async {
            self.isLoggingIn = false
            self.errorMessage = message
        }
    }

    // MARK: - ASAuthorizationControllerPresentationContextProviding

    // 告诉控制器在哪个窗口上显示登录界面
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        return UIApplication.shared.connectedScenes
            .filter { $0.activationState == .foregroundActive }
            .compactMap { $0 as? UIWindowScene }
            .first?
            .windows
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
    
    // MARK: - Server Communication
    
    private func sendTokenToServer(token: String, userId: String) async throws {
        var request = URLRequest(url: serverURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = ["identity_token": token, "user_id": userId]
        request.httpBody = try JSONEncoder().encode(body)
        
        print("AuthManager: 正在向服务器发送验证请求...")
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        
        print("AuthManager: 服务器验证成功。")
    }
    
    // MARK: - Keychain Helpers
    
    private func saveUserIdentifierToKeychain(_ identifier: String) throws {
        guard let data = identifier.data(using: .utf8) else {
            throw KeychainError.dataConversionError
        }
        
        // 先尝试删除旧的，避免重复项错误
        try? deleteUserIdentifierFromKeychain()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: userIdentifierKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            if status == errSecDuplicateItem {
                throw KeychainError.duplicateItem
            }
            throw KeychainError.unknown(status)
        }
        print("AuthManager: 用户 ID 已保存到钥匙串。")
    }

    private func loadUserIdentifierFromKeychain() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: userIdentifierKey,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        if status == errSecSuccess {
            guard let data = dataTypeRef as? Data,
                  let identifier = String(data: data, encoding: .utf8) else {
                return nil
            }
            return identifier
        } else if status == errSecItemNotFound {
            return nil // 找不到是正常情况
        } else {
            throw KeychainError.unknown(status)
        }
    }

    private func deleteUserIdentifierFromKeychain() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: userIdentifierKey
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unknown(status)
        }
    }
}

struct LoginView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            // 背景
            Image("welcome_background")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .ignoresSafeArea()
                .overlay(Color.black.opacity(0.6).ignoresSafeArea())

            VStack(spacing: 30) {
                Spacer()

                // Logo 和标题
                VStack(spacing: 15) {
                    Image(systemName: "newspaper.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.white)
                    
                    Text("解锁全部内容")
                        .font(.largeTitle.bold())
                        .foregroundColor(.white)
                    
                    Text("登录后可查看最新文章并同步阅读进度")
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()

                // 登录按钮区域
                VStack(spacing: 20) {
                    if authManager.isLoggingIn {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.5)
                    } else {
                        // Apple 登录按钮
                        SignInWithAppleButton(
                            .signIn,
                            onRequest: { request in
                                // 可以在这里配置请求，但 AuthManager 中已配置
                            },
                            onCompletion: { result in
                                // AuthManager 会通过代理处理结果，这里不需要代码
                            }
                        )
                        .onTapGesture {
                            // 实际的逻辑由 AuthManager 触发
                            authManager.signInWithApple()
                        }
                        .signInWithAppleButtonStyle(.white) // 按钮样式
                        .frame(height: 50)
                        .cornerRadius(10)
                    }

                    // 错误信息
                    if let errorMessage = authManager.errorMessage {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 40)

                Spacer()
                
                // 关闭按钮
                Button("稍后再说") {
                    dismiss()
                }
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
                .padding(.bottom, 20)
            }
        }
        .preferredColorScheme(.dark)
    }
}
