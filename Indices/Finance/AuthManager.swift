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

    // 【新增】缓存 Key
    private let cacheIsSubscribedKey = "AuthCache_IsSubscribed"
    private let cacheExpiryDateKey = "AuthCache_ExpiryDate"

    override init() {
        super.init()
        // 2. 检查登录状态
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
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
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
                    // 兑换成功也更新缓存
                    self.saveSubscriptionCache(isSubscribed: true, expiryDate: result.subscription_expires_at)
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
                // 1. 先确立身份
                self.userIdentifier = userId
                self.isLoggedIn = true
                print("AuthManager: 本地已登录，User ID: \(userId)")
                
                // 【优化点 1】立即加载上次缓存的订阅状态
                // 这样用户一打开 App 就能看到皇冠，不用等待网络请求
                loadSubscriptionCache() 
                
                // 2. 启动后台检查
                Task {
                    // 【优化点 2】执行顺序很重要
                    // 先查 Apple (StoreKit)
                    // 如果你是亲友码，这里可能会把 isSubscribed 设为 false
                    await updateSubscriptionStatus()
                    
                    // 后查服务器 (Server)
                    // 这一步是“最终裁决”。如果服务器说是 VIP，它会把 isSubscribed 改回 true
                    // 这样就保证了亲友码用户的最终状态是正确的
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
            print("AuthManager: 检查钥匙串出错: \(error)")
        }
    }

    // MARK: - Sign In / Sign Out
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
    
    // 【核心修复 1】登出逻辑优化
    func signOut() {
        // 1. 仅清除“账号相关”的状态
        self.isLoggedIn = false
        self.userIdentifier = nil
        self.subscriptionExpiryDate = nil // 清除服务器下发的过期时间
        
        // 2. 尝试删除钥匙串中的账号（不影响 VIP 状态）
        try? deleteUserIdentifierFromKeychain()
        
        // 3. 【重要】不要在这里直接 clearSubscriptionCache()！
        // 因为如果用户是通过 Apple 订阅的，缓存应该保留。
        // 我们立即调用 updateSubscriptionStatus()，让它去决定是保留还是清除。
        
        Task {
            // 这次检查会决定：
            // - 如果有 Apple 订阅 -> isSubscribed 保持 true，缓存更新。
            // - 如果无 Apple 订阅 -> isSubscribed 变为 false，缓存清除。
            await updateSubscriptionStatus()
            print("AuthManager: 登出完成，已重新校验本地权限")
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
    
    // 【核心修复 2】权限检查逻辑优化
    // 这个方法现在不仅负责“开启”权限，也负责在没权限且未登录时“关闭”权限
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
                // 情况 A: 找到了有效的 Apple 订阅
                // 无论是否登录，都视为 VIP，并更新缓存
                self.isSubscribed = true
                self.subscriptionExpiryDate = finalDateStr
                // ✅ 保存缓存
                self.saveSubscriptionCache(isSubscribed: true, expiryDate: finalDateStr)
                print("AuthManager: 发现有效 Apple 订阅 (VIP)")
            } else {
                // 情况 B: 没找到 Apple 订阅
                // 这里要小心：如果用户是“服务器端 VIP”（比如安卓买的），我们不能因为 Apple 没查到就取消 VIP。
                // 所以：只有在【未登录】的情况下，Apple 没查到，我们才敢断定他不是 VIP。
                
                if !self.isLoggedIn {
                    self.isSubscribed = false
                    self.subscriptionExpiryDate = nil
                    self.clearSubscriptionCache() // 只有这时才真正清除缓存
                    print("AuthManager: 无 Apple 订阅且未登录 -> 重置为免费版")
                }
                // 如果 isLoggedIn == true，我们不做任何操作，保留服务器可能下发的状态
            }
        }
    }
    
    func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw NSError(domain: "StoreError", code: 401, userInfo: [NSLocalizedDescriptionKey: "Transaction unverified"])
        case .verified(let safe):
            return safe
        }
    }

    func purchaseSubscription() async throws {
        guard let userId = userIdentifier else { throw URLError(.userAuthenticationRequired) }
        
        let products = try await Product.products(for: [subscriptionProductID])
        guard let product = products.first else { throw NSError(domain: "StoreError", code: 404, userInfo: nil) }
        
        let result = try await product.purchase()
        
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await updateSubscriptionStatus()
            try await syncPurchaseToServer(userId: userId)
            await transaction.finish()
            await MainActor.run { self.showSubscriptionSheet = false }
        case .userCancelled, .pending:
            break
        @unknown default:
            break
        }
    }

    func restorePurchases() async throws {
        guard let userId = userIdentifier else { throw URLError(.userAuthenticationRequired) }
        try await AppStore.sync()
        await updateSubscriptionStatus()
        if isSubscribed {
            try await syncPurchaseToServer(userId: userId)
        }
    }

    // MARK: - Server Sync
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
                    // 1. 服务器确认是 VIP
                    self.isSubscribed = true
                    self.subscriptionExpiryDate = status.subscription_expires_at
                    // ✅ 保存缓存
                    self.saveSubscriptionCache(isSubscribed: true, expiryDate: status.subscription_expires_at)
                    print("AuthManager: 服务器确认 VIP")
                } else {
                    // 2. 【修复这里】服务器说不是 VIP (过期了)
                    print("AuthManager: 服务器显示无订阅/已过期")
                    
                    // A. 先假设用户没权限，清理状态
                    self.isSubscribed = false
                    self.subscriptionExpiryDate = nil
                    self.clearSubscriptionCache()
                    
                    // B. 但是！为了防止误杀 Apple 订阅用户
                    // 立即重新触发一次 Apple 权限检查。
                    // 如果用户有 Apple 订阅，updateSubscriptionStatus 会把 isSubscribed 重新设回 true。
                    Task { [weak self] in
                        await self?.updateSubscriptionStatus()
                    }
                }
            }
        } catch {
            print("AuthManager: Server status check failed: \(error)")
        }
    }
    
    // 辅助方法：快速检查当前内存中是否有有效的 Apple 订阅证据
    // 你可以在 updateSubscriptionStatus 里维护一个变量，或者直接判断 subscriptionProductID
    private func hasActiveAppleSubscription() -> Bool {
        // 这是一个简化的判断，更严谨的做法是在 updateSubscriptionStatus 里记录一个 Bool 变量
        // 这里我们可以假设：如果当前是 VIP，但服务器说是 false，
        // 唯一的希望就是 Apple。如果 updateSubscriptionStatus 刚刚运行过，
        // 且没找到 Apple 订阅，它虽然没改 isSubscribed (因为 loggedIn)，
        // 但它肯定没更新 subscriptionExpiryDate (或者更新的是 nil)。
        
        // 最稳妥的方法：复用 updateSubscriptionStatus 的逻辑，
        // 但为了不写重复代码，建议在类里加一个属性：
        // @Published var hasAppleEntitlement: Bool = false
        // 在 updateSubscriptionStatus 里更新这个属性。
        
        // 如果不想大改，可以用下面的临时逻辑：
        // 如果当前是 VIP，我们假设它是服务器给的。现在服务器收回了，我们就收回。
        // 除非... 用户刚刚买了 Apple。
        // 鉴于你的架构，最简单的修补是：
        // 既然 checkServerSubscriptionStatus 是最后一步“裁决者”，
        // 如果服务器返回 false，我们应该信任服务器（前提是服务器知道 Apple 的购买状态）。
        // 但如果服务器不知道 Apple 的状态（同步失败），这里直接 false 会误杀。
        
        // ⭐️ 最佳轻量级方案：
        // 不要在这里纠结，而是修改 updateSubscriptionStatus
        return false // 占位，看下面的“最终建议”
    }

    // MARK: - ASAuthorization Delegate
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        if let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential {
            guard let identityTokenData = appleIDCredential.identityToken,
                  let identityToken = String(data: identityTokenData, encoding: .utf8) else { return }
            
            let userId = appleIDCredential.user
            
            Task {
                do {
                    // 1. 先保存 Keychain
                    try saveUserIdentifierToKeychain(userId)
                    
                    // 2. 【关键修复】先在 UI 上确立“已登录”状态
                    // 这样后续的检查就不会因为“未登录”而误删权限
                    await MainActor.run {
                        self.userIdentifier = userId
                        self.isLoggedIn = true
                        self.isLoggingIn = true // 保持 loading 状态直到服务器返回
                    }
                    
                    // 3. 请求服务器 (获取亲友码/服务器端 VIP 状态)
                    // 如果服务器返回 VIP，这里会把 isSubscribed 设为 true
                    try await sendTokenToServer(token: identityToken, userId: userId)
                    
                    // 4. 最后再同步 Apple 本地权限
                    // 此时 isLoggedIn 已经是 true 了，所以即使 Apple 返回 false，
                    // updateSubscriptionStatus 里的逻辑也不会清除服务器给的 VIP。
                    await updateSubscriptionStatus() 
                    
                    // 5. 结束 Loading
                    await MainActor.run {
                        self.isLoggingIn = false
                    }
                } catch {
                    // 如果出错，回滚状态
                    await MainActor.run {
                        self.isLoggedIn = false
                        self.userIdentifier = nil
                        try? self.deleteUserIdentifierFromKeychain()
                    }
                    handleSignInError("登录失败: \(error.localizedDescription)")
                }
            }
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        if (error as? ASAuthorizationError)?.code != .canceled {
            handleSignInError("登录失败")
        }
    }
    
    private func handleSignInError(_ message: String?) {
        DispatchQueue.main.async {
            self.isLoggingIn = false
            self.errorMessage = message
        }
    }
    
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
    
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
        
        struct AuthResponse: Codable {
            let status: String?
            let is_subscribed: Bool
            let subscription_expires_at: String?
        }
        
        let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
        
        await MainActor.run {
            // 如果服务器说是 VIP，直接覆盖本地状态
            if authResponse.is_subscribed {
                self.isSubscribed = true
                self.subscriptionExpiryDate = authResponse.subscription_expires_at
                // 立即保存缓存，防止闪烁
                self.saveSubscriptionCache(isSubscribed: true, expiryDate: authResponse.subscription_expires_at)
                print("AuthManager: 服务器认证成功，用户是 VIP (亲友/订阅)")
            } else {
                // 如果服务器说不是 VIP，我们暂时不设为 false，
                // 因为可能还要等 updateSubscriptionStatus 检查 Apple 的收据
                print("AuthManager: 服务器认证成功，用户暂无服务器端订阅")
            }
        }
    }

    // MARK: - Caching
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
            // 简单校验日期（可选），如果缓存是 true，先给权限，后续网络请求会校正
            self.isSubscribed = true
            self.subscriptionExpiryDate = cachedExpiry
            print("AuthManager: 已加载本地缓存，暂时赋予 VIP 权限。")
        }
    }
    
    private func clearSubscriptionCache() {
        UserDefaults.standard.removeObject(forKey: cacheIsSubscribedKey)
        UserDefaults.standard.removeObject(forKey: cacheExpiryDateKey)
    }

    // MARK: - Keychain Helpers
    private func saveUserIdentifierToKeychain(_ identifier: String) throws {
        guard let data = identifier.data(using: .utf8) else { throw KeychainError.dataConversionError }
        try? deleteUserIdentifierFromKeychain()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: userIdentifierKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemAdd(query as CFDictionary, nil)
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
        if status == errSecSuccess, let data = dataTypeRef as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
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
                    
                    Text("登录 【美股精灵】")
                        .font(.largeTitle.bold())
                        // 3. 使用系统主文本颜色 (自动黑/白)
                        .foregroundColor(.primary)
                    
                    Text("成功登录后\n即使更换了设备\n也可以同步您的订阅状态")
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
