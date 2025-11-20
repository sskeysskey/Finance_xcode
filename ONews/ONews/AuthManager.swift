import SwiftUI
import AuthenticationServices
import Security
import StoreKit // 【新增】引入 StoreKit

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
    // 【新增】订阅状态
    @Published var isSubscribed: Bool = false
    @Published var subscriptionExpiryDate: String?
    
    @Published var errorMessage: String?
    @Published var showSubscriptionSheet: Bool = false // 控制是否显示订阅页

    // 存储从 Apple 获取的用户唯一标识符
    private(set) var userIdentifier: String?
    
    private let userIdentifierKey = "zhangyan.ONews"
    
    // 【重要】这里必须替换为你 App Store Connect 里设置的 Product ID
    private let subscriptionProductID = "com.zhangyan.onews.subscription.monthly"
    
    // 服务器地址
    private let serverBaseURL = "http://106.15.183.158:5001/api/ONews"
    
    // 【新增】用于监听交易更新的任务
    private var updateListenerTask: Task<Void, Error>?

    override init() {
        super.init()
        // 应用启动时检查钥匙串中是否已有登录凭证
        checkUserInKeychain()
        
        // 【新增】启动交易监听器（处理应用外购买或自动续费）
        updateListenerTask = listenForTransactions()
    }
    
    deinit {
        updateListenerTask?.cancel()
    }

    // 检查钥匙串中的用户状态
    private func checkUserInKeychain() {
        do {
            if let userId = try loadUserIdentifierFromKeychain() {
                self.userIdentifier = userId
                self.isLoggedIn = true
                print("AuthManager: 本地已登录，User ID: \(userId)")
                // 【新增】启动时校验服务器状态，防止本地篡改或过期
                Task {
                    await checkServerSubscriptionStatus()
                }
            } else {
                self.isLoggedIn = false
                self.isSubscribed = false
            }
        } catch {
            self.isLoggedIn = false
            self.isSubscribed = false
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
            self.isSubscribed = false // 登出后取消订阅状态
            self.subscriptionExpiryDate = nil
            print("AuthManager: 用户已成功登出。")
        } catch {
            // 即使删除失败，也在 UI 上表现为登出
            self.userIdentifier = nil
            self.isLoggedIn = false
            self.isSubscribed = false
            print("AuthManager: 登出错误: \(error.localizedDescription)")
        }
    }

    // MARK: - StoreKit 2 Payment Logic (核心修改)

    // 【新增】监听交易流
    func listenForTransactions() -> Task<Void, Error> {
        return Task.detached {
            for await result in Transaction.updates {
                do {
                    // 修复点：这里调用的是实例方法 checkVerified
                    let transaction = try await self.checkVerified(result)
                    // 交易验证成功，更新 UI 或同步服务器
                    await self.updateSubscriptionStatus()
                    await transaction.finish() // 告诉苹果交易已处理
                } catch {
                    print("Transaction verification failed")
                }
            }
        }
    }
    
    // 【修改】购买订阅
    func purchaseSubscription() async throws {
        guard let userId = userIdentifier else { throw URLError(.userAuthenticationRequired) }
        
        // 1. 获取商品信息
        let products = try await Product.products(for: [subscriptionProductID])
        guard let product = products.first else {
            throw NSError(domain: "StoreError", code: 404, userInfo: [NSLocalizedDescriptionKey: "未找到商品信息，请检查 App Store Connect 配置"])
        }
        
        // 2. 发起购买
        let result = try await product.purchase()
        
        switch result {
        case .success(let verification):
            // 3. 验证交易
            // 修复点：调用实例方法 checkVerified
            let transaction = try checkVerified(verification)
            
            // 4. 购买成功，更新本地状态
            await updateSubscriptionStatus()
            
            // 5. (可选) 将收据或状态同步给 Python 服务器
            // 注意：StoreKit 2 推荐在本地验证，但为了多端同步，你可以告诉服务器“我买了”
            // 服务器端最好也做 receipt 验证，但这里为了简单，我们复用你之前的逻辑，
            // 只是现在是在 Apple 扣费成功后才调用。
            try await syncPurchaseToServer(userId: userId)
            
            // 6. 完成交易
            await transaction.finish()
            
            await MainActor.run {
                self.showSubscriptionSheet = false
            }
            
        case .userCancelled:
            print("用户取消支付")
        case .pending:
            print("交易挂起（如家长控制）")
        @unknown default:
            print("未知状态")
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
                    // 验证并获取订阅状态
                    try await sendTokenToServer(token: identityToken, userId: userId)
                    // 服务器验证成功后，在本地保存用户凭证
                    try saveUserIdentifierToKeychain(userId)
                    
                    // 更新 UI 状态
                    await MainActor.run {
                        self.userIdentifier = userId
                        self.isLoggedIn = true
                        self.isLoggingIn = false
                        
                        // 【核心逻辑】如果未订阅，则触发显示订阅页面
                        if !self.isSubscribed {
                            self.showSubscriptionSheet = true
                        }
                        print("AuthManager: 登录成功。订阅状态: \(self.isSubscribed)")
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
        let url = URL(string: "\(serverBaseURL)/auth/apple")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = ["identity_token": token, "user_id": userId]
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        
        // 【修改】解析服务器返回的订阅状态
        struct AuthResponse: Codable {
            let is_subscribed: Bool
            let subscription_expires_at: String?
        }
        
        let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
        
        await MainActor.run {
            self.isSubscribed = authResponse.is_subscribed
            self.subscriptionExpiryDate = authResponse.subscription_expires_at
        }
    }
    
    // 【新增】检查当前订阅状态（从 Apple 获取）
    func updateSubscriptionStatus() async {
        var hasActiveSubscription = false
        
        // 遍历当前有效的权限
        for await result in Transaction.currentEntitlements {
            do {
                // 修复点：调用实例方法 checkVerified
                let transaction = try checkVerified(result)
                
                // 检查是否是我们的订阅产品且未过期
                if transaction.productID == subscriptionProductID {
                    if let expirationDate = transaction.expirationDate, expirationDate > Date() {
                        hasActiveSubscription = true
                        await MainActor.run {
                            self.subscriptionExpiryDate = expirationDate.ISO8601Format()
                        }
                    }
                }
            } catch {
                print("Failed to verify transaction")
            }
        }
        
        await MainActor.run {
            self.isSubscribed = hasActiveSubscription
            print("AuthManager: 本地 StoreKit 检查订阅状态: \(hasActiveSubscription)")
        }
    }
    
    // 辅助函数：验证 JWS 签名
    // 【修复】删除了 static 关键字，使其成为实例方法，解决 "cannot be used on instance" 错误
    func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw NSError(domain: "StoreError", code: 401, userInfo: [NSLocalizedDescriptionKey: "Transaction unverified"])
        case .verified(let safe):
            return safe
        }
    }
    
    // MARK: - Server Sync (保留与 Python 的通信)
    
    // 复用你之前的逻辑，但在 StoreKit 成功后调用
    private func syncPurchaseToServer(userId: String) async throws {
        let url = URL(string: "\(serverBaseURL)/payment/subscribe")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // 告诉服务器充值 30 天 (或者根据 transaction.expirationDate 计算)
        let body: [String: Any] = ["user_id": userId, "days": 30]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            print("同步服务器失败，但本地已购买成功")
            return
        }
        print("服务器同步成功")
    }
    
    // 【新增】检查服务器上的订阅状态
    func checkServerSubscriptionStatus() async {
        guard let userId = userIdentifier else { return }
        guard let url = URL(string: "\(serverBaseURL)/user/status?user_id=\(userId)") else { return }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct StatusResponse: Codable {
                let is_subscribed: Bool
                let subscription_expires_at: String?
            }
            let status = try JSONDecoder().decode(StatusResponse.self, from: data)
            
            await MainActor.run {
                self.isSubscribed = status.is_subscribed
                self.subscriptionExpiryDate = status.subscription_expires_at
                print("AuthManager: 状态同步完成，订阅状态: \(status.is_subscribed)")
            }
        } catch {
            print("AuthManager: 检查状态失败: \(error)")
        }
    }
    
    // ... (Keychain Helpers 保持不变) ...
    private func saveUserIdentifierToKeychain(_ identifier: String) throws {
        guard let data = identifier.data(using: .utf8) else { throw KeychainError.dataConversionError }
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
