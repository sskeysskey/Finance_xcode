import SwiftUI
import AuthenticationServices
import Security
import StoreKit // 引入 StoreKit

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
    
    // 【新增】缓存 Key
    private let cacheIsSubscribedKey = "AuthCache_IsSubscribed"
    private let cacheExpiryDateKey = "AuthCache_ExpiryDate"
    
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
                
                // 【核心修复 1】启动时，先加载本地缓存的订阅状态
                // 这样即使网络请求失败，用户也能看到之前的订阅状态
                loadSubscriptionCache()
                
                // 【核心修复 2】
                // 启动时，不仅要检查服务器，更要直接检查 Apple 本地的 Entitlements (权限)。
                Task {
                    // 1. 优先检查 Apple 本地凭证 (这是最快且最准确的源头)
                    await updateSubscriptionStatus()
                    
                    // 2. 同时/随后检查服务器状态 (用于同步安卓/跨平台状态或特殊后门)
                    await checkServerSubscriptionStatus()
                }
            } else {
                self.isLoggedIn = false
                self.isSubscribed = false
                clearSubscriptionCache() // 未登录时清理缓存
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
            clearSubscriptionCache() // 清理缓存
            print("AuthManager: 用户已成功登出。")
        } catch {
            // 即使删除失败，也在 UI 上表现为登出
            self.userIdentifier = nil
            self.isLoggedIn = false
            self.isSubscribed = false
            clearSubscriptionCache()
            print("AuthManager: 登出错误: \(error.localizedDescription)")
        }
    }

    // 【新增】兑换邀请码
    func redeemInviteCode(_ code: String) async throws {
        guard let userId = userIdentifier else { throw URLError(.userAuthenticationRequired) }
        
        let url = URL(string: "\(serverBaseURL)/user/redeem")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = ["user_id": userId, "invite_code": code]
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        if httpResponse.statusCode != 200 {
            // 尝试解析错误信息
            if let errorJson = try? JSONDecoder().decode([String: String].self, from: data),
               let serverMsg = errorJson["error"] {
                throw NSError(domain: "AuthError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: serverMsg])
            }
            throw URLError(.badServerResponse)
        }
        
        // 解析成功响应
        struct RedeemResponse: Codable {
            let is_subscribed: Bool
            let subscription_expires_at: String?
        }
        
        let redeemResponse = try JSONDecoder().decode(RedeemResponse.self, from: data)
        
        await MainActor.run {
            self.isSubscribed = redeemResponse.is_subscribed
            self.subscriptionExpiryDate = redeemResponse.subscription_expires_at
            // 兑换成功也更新缓存
            self.saveSubscriptionCache(isSubscribed: redeemResponse.is_subscribed, expiryDate: redeemResponse.subscription_expires_at)
            print("AuthManager: 邀请码兑换成功，VIP 状态已激活。")
        }
    }

    // MARK: - StoreKit 2 Payment Logic (核心修改)

    // 【新增】监听交易流
    func listenForTransactions() -> Task<Void, Error> {
        return Task.detached {
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
    
    // 【修改】购买订阅 - 返回 Bool 表示是否购买成功
    // 返回 true: 购买成功
    // 返回 false: 用户取消或挂起
    func purchaseSubscription() async throws -> Bool {
        // 1. 检查登录
        guard let userId = userIdentifier else {
            throw URLError(.userAuthenticationRequired)
        }
        
        // 2. 获取商品信息
        let products = try await Product.products(for: [subscriptionProductID])
        guard let product = products.first else {
            throw NSError(domain: "StoreError", code: 404, userInfo: [NSLocalizedDescriptionKey: Localized.errProductNotFound]) // 使用双语
        }
        
        // 3. 发起购买
        let result = try await product.purchase()
        
        switch result {
        case .success(let verification):
            // 验证交易
            let transaction = try checkVerified(verification)
            
            // 购买成功，更新本地状态
            await updateSubscriptionStatus()
            
            // 同步给服务器
            try await syncPurchaseToServer(userId: userId)
            
            // 完成交易
            await transaction.finish()
            
            await MainActor.run {
                // 如果是 MainContentView 通过这个变量控制的弹窗，这里关闭它
                self.showSubscriptionSheet = false
            }
            
            return true // ✅ 返回成功
            
        case .userCancelled:
            print(Localized.errUserCancelled) // 使用双语
            return false // ❌ 返回失败（取消）
            
        case .pending:
            print("交易挂起")
            return false // ❌ 返回失败（挂起）
            
        @unknown default:
            print("未知状态")
            return false
        }
    }

    func handleAppDidBecomeActive() {
        Task {
            // 每次回到前台都刷一下，确保续订后第一时间同步给服务器
            await updateSubscriptionStatus()
            await checkServerSubscriptionStatus()
        }
    }

    // 【新增】恢复购买功能 (从 Finance 移植)
    func restorePurchases() async throws {
        // 1. 强制同步 App Store 交易信息 (StoreKit 2)
        // 这会弹出 Apple ID 密码输入框（如果是沙盒环境或长时间未操作）
        try await AppStore.sync()
        
        // 2. 重新检查所有权限
        await updateSubscriptionStatus()
        
        // 3. 如果需要，可以在这里再次同步到 Python 服务器 (可选)
        if let userId = userIdentifier, isSubscribed {
            try await syncPurchaseToServer(userId: userId)
        }
    }

    // MARK: - ASAuthorizationControllerDelegate

    // 授权成功回调
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        if let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential {
            guard let identityTokenData = appleIDCredential.identityToken,
                  let identityToken = String(data: identityTokenData, encoding: .utf8) else {
                handleSignInError(Localized.errNoIdentityToken) // 使用双语
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
                        
                        print("AuthManager: 登录成功。订阅状态: \(self.isSubscribed)")
                    }
                } catch {
                    handleSignInError("\(Localized.errServerVerifyFailed): \(error.localizedDescription)") // 使用双语
                }
            }
        } else {
            handleSignInError(Localized.errAppleIDCredentialFailed) // 使用双语
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
            handleSignInError(Localized.errLoginFailedRetry) // 使用双语
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
            // 登录成功，保存缓存
            self.saveSubscriptionCache(isSubscribed: authResponse.is_subscribed, expiryDate: authResponse.subscription_expires_at)
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
                // 如果 Apple 说有效，直接覆盖所有状态，这是最高优先级
                self.isSubscribed = true
                self.subscriptionExpiryDate = finalDateStr
                // 本地 StoreKit 检查最权威，更新缓存
                self.saveSubscriptionCache(isSubscribed: true, expiryDate: finalDateStr)
            }
            print("AuthManager: 本地 StoreKit 检查完成。结果: \(self.isSubscribed)")
        }
    }
    
    // 辅助函数：验证 JWS 签名
    // 【修复】删除了 static 关键字，使其成为实例方法，解决 "cannot be used on instance" 错误
    func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw NSError(domain: "StoreError", code: 401, userInfo: [NSLocalizedDescriptionKey: Localized.errTransactionUnverified]) // 使用双语
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
                // 1. 如果服务器说 "是 VIP"
                if status.is_subscribed {
                    self.isSubscribed = true
                    self.subscriptionExpiryDate = status.subscription_expires_at
                    // 服务器校验成功，更新缓存
                    self.saveSubscriptionCache(isSubscribed: true, expiryDate: status.subscription_expires_at)
                    print("AuthManager: 服务器确认 VIP 身份。")
                } 
                // 2. 如果服务器说 "不是 VIP"
                else {
                    // 【核心修复】
                    // 只有在 "本地 Apple 凭证也过期" 的情况下，才听服务器的。
                    // 如果我们刚刚通过 StoreKit 确认了本地权限有效，就忽略服务器的 "false"。
                    if self.isSubscribedViaAppleLocal() {
                        print("AuthManager: 服务器返回未订阅，但本地 Apple 凭证有效。忽略服务器结果，保持 VIP。")
                        // 可选：这里可以触发一次静默的同步，告诉服务器更新状态
                        Task { try? await self.syncPurchaseToServer(userId: userId) }
                    } else {
                        // 确实没订阅，也没本地凭证，那才是真的没订阅
                        self.isSubscribed = false
                        self.subscriptionExpiryDate = nil
                        self.clearSubscriptionCache()
                        print("AuthManager: 服务器确认未订阅，且无本地凭证。")
                    }
                }
            }
        } catch {
            print("AuthManager: 检查服务器状态失败: \(error)")
            // 网络失败时不操作，保持现有状态（依赖缓存或本地凭证）
        }
    }
    
    // 【新增】辅助函数：判断当前是否是基于 Apple 本地凭证的订阅
    // 我们需要一个简单的判断：如果当前 isSubscribed 为 true，且 expiryDate 是将来，
    // 我们就假设它是有效的（因为 updateSubscriptionStatus 会定期运行保证它准确）
    private func isSubscribedViaAppleLocal() -> Bool {
        guard self.isSubscribed else { return false }
        guard let dateStr = self.subscriptionExpiryDate else { return false } // 永久会员可能没日期，视情况而定
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        // 尝试解析
        if let date = formatter.date(from: dateStr) {
            return date > Date()
        }
        
        // 兼容简单格式
        let simpleFormatter = ISO8601DateFormatter()
        simpleFormatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        if let date = simpleFormatter.date(from: dateStr) {
             // 简单日期通常指当天的 00:00，为了保险起见，如果是今天或未来，都算有效
             return date >= Calendar.current.startOfDay(for: Date())
        }
        
        // 如果是 "2099" 这种永久标记，也算有效
        if dateStr.starts(with: "2099") { return true }
        
        return false
    }
    
    // MARK: - 缓存逻辑 (解决网络启动慢/失败的问题)
    
    private func saveSubscriptionCache(isSubscribed: Bool, expiryDate: String?) {
        UserDefaults.standard.set(isSubscribed, forKey: cacheIsSubscribedKey)
        if let date = expiryDate {
            UserDefaults.standard.set(date, forKey: cacheExpiryDateKey)
        } else {
            UserDefaults.standard.removeObject(forKey: cacheExpiryDateKey)
        }
    }
    
    private func loadSubscriptionCache() {
        let cachedStatus = UserDefaults.standard.bool(forKey: cacheIsSubscribedKey)
        let cachedExpiry = UserDefaults.standard.string(forKey: cacheExpiryDateKey)
        
        if cachedStatus {
            // 只有当缓存是 true 时，我们才需要验证日期
            // 如果缓存里有日期，检查是否已过期
            if let dateStr = cachedExpiry {
                // 简单解析 ISO8601
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                
                // 尝试解析，如果解析失败尝试简单格式
                var date = formatter.date(from: dateStr)
                if date == nil {
                    let simpleFormatter = ISO8601DateFormatter()
                    simpleFormatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
                    date = simpleFormatter.date(from: dateStr)
                }
                
                if let validDate = date {
                    if validDate > Date() {
                        // 缓存有效且未过期
                        self.isSubscribed = true
                        self.subscriptionExpiryDate = dateStr
                        print("AuthManager: 已加载本地缓存，暂时赋予 VIP 权限。")
                        return
                    } else {
                        print("AuthManager: 本地缓存已过期。")
                    }
                } else {
                    // 如果是永久 VIP (2099年) 或者日期解析不了但状态是 true，也暂时信任
                    // 假设 2099 这种简单字符串
                    if dateStr.starts(with: "2099") {
                        self.isSubscribed = true
                        self.subscriptionExpiryDate = dateStr
                        return
                    }
                }
            }
        }
        
        // 如果缓存无效或未订阅
        // self.isSubscribed = false // 默认就是 false，不用重复赋值
    }
    
    private func clearSubscriptionCache() {
        UserDefaults.standard.removeObject(forKey: cacheIsSubscribedKey)
        UserDefaults.standard.removeObject(forKey: cacheExpiryDateKey)
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
            // 【修改】使用系统背景色
            Color.viewBackground
                .ignoresSafeArea()

            VStack(spacing: 30) {
                Spacer()

                // Logo 和标题
                VStack(spacing: 15) {
                    Image(systemName: "newspaper.fill")
                        .font(.system(size: 60))
                        // 【修改】颜色自适应
                        .foregroundColor(.primary)
                    
                    Text(Localized.loginWelcome) // 替换
                        .font(.largeTitle.bold())
                        .foregroundColor(.primary)
                    
                    Text(Localized.loginDesc) // 替换
                        .font(.headline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()

                // 登录按钮区域
                VStack(spacing: 20) {
                    if authManager.isLoggingIn {
                        ProgressView()
                            // 【修改】使用默认样式
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
                        // 【修改】使用系统默认样式，会自动适配黑白
                        .signInWithAppleButtonStyle(.black) 
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
                Button(Localized.later) { // 替换
                    dismiss()
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.bottom, 20)
            }
        }
    }
}