import SwiftUI
import AuthenticationServices
import Security
import StoreKit

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
    
    // 【修改】Finance 专用的 Key
    private let userIdentifierKey = "zhangyan.Indices"
    // 【修改】Finance 专用的 Product ID (需在 App Store Connect 创建)
    private let subscriptionProductID = "com.zhangyan.finance.subscription.monthly"
    // 【修改】Finance API 地址
    private let serverBaseURL = "http://106.15.183.158:5001/api/Finance"
    
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

    // MARK: - Invite Code Redemption (后门逻辑)
    
    /// 尝试兑换邀请码
    func redeemInviteCode(_ code: String) async throws -> Bool {
        guard let userId = userIdentifier else {
            throw NSError(domain: "AuthError", code: 401, userInfo: [NSLocalizedDescriptionKey: "请先登录后再使用兑换码"])
        }
        
        let url = URL(string: "\(serverBaseURL)/user/redeem")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = ["user_id": userId, "invite_code": code]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        if httpResponse.statusCode == 200 {
            // 解析返回结果
            struct RedeemResponse: Codable {
                let status: String
                let is_subscribed: Bool
                let subscription_expires_at: String?
            }
            
            let result = try JSONDecoder().decode(RedeemResponse.self, from: data)
            
            await MainActor.run {
                if result.is_subscribed {
                    self.isSubscribed = true
                    self.subscriptionExpiryDate = result.subscription_expires_at
                    print("AuthManager: 兑换码使用成功，已升级为 VIP")
                }
            }
            return true
        } else {
            // 处理错误消息
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMsg = json["error"] as? String {
                throw NSError(domain: "Server", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMsg])
            }
            throw URLError(.badServerResponse)
        }
    }

    // 检查钥匙串中的用户状态
    private func checkUserInKeychain() {
        do {
            if let userId = try loadUserIdentifierFromKeychain() {
                self.userIdentifier = userId
                self.isLoggedIn = true
                print("AuthManager: 本地已登录，User ID: \(userId)")
                
                // 【核心修复】
                // 启动时，不仅要检查服务器，更要直接检查 Apple 本地的 Entitlements (权限)。
                Task {
                    // 1. 优先检查 Apple 本地凭证 (这是最快且最准确的源头)
                    await updateSubscriptionStatus()
                    
                    // 2. 同时/随后检查服务器状态
                    await checkServerSubscriptionStatus()
                }
            } else {
                self.isLoggedIn = false
                // 即使未登录，也要检查本地是否有有效的 StoreKit 权限（匿名购买的情况）
                Task {
                    await updateSubscriptionStatus()
                }
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
            // 注意：登出不应直接取消订阅状态，因为用户可能通过 StoreKit 本地购买了
            // 但为了安全起见或逻辑统一，可以重新检查一次 StoreKit
            Task { await updateSubscriptionStatus() }
            
            self.subscriptionExpiryDate = nil
            print("AuthManager: 用户已成功登出。")
        } catch {
            // 即使删除失败，也在 UI 上表现为登出
            self.userIdentifier = nil
            self.isLoggedIn = false
            print("AuthManager: 登出错误: \(error.localizedDescription)")
        }
    }

    // MARK: - StoreKit 2 Payment Logic (核心修改)

    // 【新增】监听交易流
    func listenForTransactions() -> Task<Void, Error> {
        return Task.detached {
            // 【修复】StoreKit.Transaction.updates 的遍历不会抛出错误
            for await result in StoreKit.Transaction.updates {
                await self.handleTransactionUpdate(result)
            }
        }
    }
    
    // 辅助方法处理交易更新
    // 【修复】参数类型明确指定 StoreKit.Transaction
    private func handleTransactionUpdate(_ result: VerificationResult<StoreKit.Transaction>) async {
        do {
            let transaction = try checkVerified(result)
            await updateSubscriptionStatus()
            await transaction.finish()
        } catch {
            print("验证失败: \(error)")
        }
    }
    
    // 【修改】购买订阅 - 强制要求登录
    func purchaseSubscription() async throws {
        // 1. 【核心修改】恢复强制登录检查
        guard let userId = userIdentifier else {
            throw URLError(.userAuthenticationRequired)
        }
        
        // 2. 获取商品信息
        let products = try await Product.products(for: [subscriptionProductID])
        guard let product = products.first else {
            throw NSError(domain: "StoreError", code: 404, userInfo: [NSLocalizedDescriptionKey: "未找到商品信息，请检查 App Store Connect 配置"])
        }
        
        // 3. 发起购买
        let result = try await product.purchase()
        
        switch result {
        case .success(let verification):
            // 验证交易
            let transaction = try checkVerified(verification)
            
            // 购买成功，更新本地状态
            await updateSubscriptionStatus()
            
            // 【重要】同步给服务器 (现在 userId 必定存在)
            try await syncPurchaseToServer(userId: userId)
            
            // 完成交易
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

    // 【修改】恢复购买功能 - 强制要求登录
    func restorePurchases() async throws {
        // 1. 【核心修改】为了数据同步，强制要求先登录才能恢复
        guard let userId = userIdentifier else {
            throw URLError(.userAuthenticationRequired)
        }

        // 2. 强制同步 App Store 交易信息
        try await AppStore.sync()
        
        // 3. 重新检查所有权限
        await updateSubscriptionStatus()
        
        // 4. 同步到服务器
        if isSubscribed {
            try await syncPurchaseToServer(userId: userId)
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
                    
                    // 登录成功后，也立即检查一下本地 Apple 权限，双重保险
                    await updateSubscriptionStatus()
                    
                    // 更新 UI 状态
                    await MainActor.run {
                        self.userIdentifier = userId
                        self.isLoggedIn = true
                        self.isLoggingIn = false
                        
                        // 注意：这里不再强制弹出订阅页，因为调用方（SymbolItemView）会处理后续流程
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
        
        // 解析服务器返回的订阅状态
        struct AuthResponse: Codable {
            let is_subscribed: Bool
            let subscription_expires_at: String?
        }
        
        let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
        
        await MainActor.run {
            // 只有当服务器明确说已订阅时才覆盖为 true，否则保留本地可能存在的 StoreKit 状态
            if authResponse.is_subscribed {
                self.isSubscribed = true
                self.subscriptionExpiryDate = authResponse.subscription_expires_at
            }
        }
    }
    
    // 【新增】检查当前订阅状态（从 Apple 获取）
    func updateSubscriptionStatus() async {
        var hasActiveSubscription = false
        var latestExpirationDate: Date? = nil
        
        // 【修复】明确指定 StoreKit.Transaction
        for await result in StoreKit.Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)
                
                // 检查是否是我们的订阅产品
                if transaction.productID == subscriptionProductID {
                    // 检查过期时间
                    if let expirationDate = transaction.expirationDate {
                        if expirationDate > Date() {
                            hasActiveSubscription = true
                            latestExpirationDate = expirationDate
                            print("AuthManager: 发现有效订阅，过期时间: \(expirationDate)")
                        }
                    }
                }
            } catch {
                print("Failed to verify transaction: \(error)")
            }
        }
        
        // 更新 UI 状态
        let finalStatus = hasActiveSubscription
        let finalDateStr = latestExpirationDate?.ISO8601Format()
        
        await MainActor.run {
            if finalStatus {
                self.isSubscribed = true
                self.subscriptionExpiryDate = finalDateStr
            }
            print("AuthManager: 本地 StoreKit 检查完成。结果: \(self.isSubscribed)")
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
        
        // 【核心修改】构建请求体
        var body: [String: Any] = ["user_id": userId]
        
        // 检查 AuthManager 中是否已经有了从 Apple 获取的过期时间
        // 注意：purchaseSubscription 和 restorePurchases 都会先调用 updateSubscriptionStatus
        // 所以此时 self.subscriptionExpiryDate 应该是最新的真实时间
        if let realExpiryDate = self.subscriptionExpiryDate {
            // 传给服务器字段：explicit_expiry
            body["explicit_expiry"] = realExpiryDate
        } else {
            // 如果实在拿不到时间（极少情况），再回退到加30天
            body["days"] = 30
        }
        
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
                if status.is_subscribed {
                    self.isSubscribed = true
                    self.subscriptionExpiryDate = status.subscription_expires_at
                }
                print("AuthManager: 服务器状态同步完成，订阅状态: \(status.is_subscribed)")
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
    @Environment(\.colorScheme) var colorScheme // 获取当前系统模式

    var body: some View {
        ZStack {
            // 1. 使用系统背景色 (Light: 白, Dark: 黑)
            Color(UIColor.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 30) {
                Spacer()

                // Logo 和标题
                VStack(spacing: 15) {
                    Image(systemName: "newspaper.fill")
                        .font(.system(size: 80))
                        // 2. 使用主色调或 Primary 颜色
                        .foregroundColor(.blue)
                    
                    Text("登录 【美股精灵】 账号")
                        .font(.largeTitle.bold())
                        // 3. 使用系统主文本颜色 (自动黑/白)
                        .foregroundColor(.primary)
                    
                    Text("登录后\n不同设备间可以同步您的订阅")
                        .font(.headline)
                        // 4. 使用系统次级文本颜色 (灰色)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()

                // 登录按钮区域
                VStack(spacing: 20) {
                    if authManager.isLoggingIn {
                        ProgressView()
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
                        // 5. 按钮样式适配：亮色模式用黑按钮，深色模式用白按钮
                        .signInWithAppleButtonStyle(colorScheme == .light ? .black : .white)
                        .frame(height: 50)
                        .cornerRadius(10)
                        // 添加阴影让按钮更有层次感
                        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
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
                    // 【核心修改】这里仅关闭视图，后续的支付跳转逻辑由父视图的 onDismiss 处理
                    dismiss()
                }
                .font(.subheadline)
                .foregroundColor(.secondary) // 改为次级颜色
                .padding(.bottom, 20)
            }
        }
        // 移除 .preferredColorScheme(.dark) 以允许系统切换
        .onChange(of: authManager.isLoggedIn) { _, newValue in
            if newValue {
                dismiss()
            }
        }
    }
}
