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
    @Published var isSubscribed: Bool = false
    @Published var subscriptionExpiryDate: String?
    /// 【新增】当前设备上是否真的存在有效的 Apple 订阅凭证（与"服务器端 VIP"区分开）
    @Published var hasAppleEntitlement: Bool = false
    
    @Published var errorMessage: String?
    @Published var showSubscriptionSheet: Bool = false

    private(set) var userIdentifier: String?
    
    private let userIdentifierKey = "zhangyan.Indices"
    private let subscriptionProductID = "com.zhangyan.finance.subscription.monthly"
    private let serverBaseURL = "http://106.15.183.158:5001/api/Finance"
    
    private var updateListenerTask: Task<Void, Error>?

    // 缓存 Key
    private let cacheIsSubscribedKey = "AuthCache_IsSubscribed"
    private let cacheExpiryDateKey = "AuthCache_ExpiryDate"
    private let cacheSavedAtKey = "AuthCache_SavedAt"          // 【新增】缓存写入时间
    private let cacheGraceDays: Double = 3                      // 【新增】无到期时间的老缓存最多信任 3 天

    /// 【修复 B2】只保存"来自 StoreKit 的真实到期时间"，绝不混入服务器/后门下发的时间
    private var appleEntitlementExpiry: Date?

    override init() {
        super.init()
        checkUserInKeychain()
        updateListenerTask = listenForTransactions()
    }
    
    deinit {
        updateListenerTask?.cancel()
    }

    // MARK: - Invite Code Redemption (后门逻辑)
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
                    self.saveSubscriptionCache(isSubscribed: true, expiryDate: result.subscription_expires_at)
                    print("AuthManager: 兑换码使用成功，已升级为 VIP")
                }
            }
            return true
        } else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMsg = json["error"] as? String {
                throw NSError(domain: "Server", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMsg])
            }
            throw URLError(.badServerResponse)
        }
    }

    // MARK: - 好友邀请码
    struct FriendRedeemResponse: Codable {
        let status: String?
        let reward_points: Int?
        let bonus_remaining: Int?
        let remaining_total: Int?
        let error: String?
    }

    func redeemFriendInviteCode(_ code: String) async throws -> Int {
        guard let userId = userIdentifier, isLoggedIn else {
            throw NSError(domain: "AuthError", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "请先登录后再使用邀请码"])
        }
        let url = URL(string: "\(serverBaseURL)/invite/redeem")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["user_id": userId, "invite_code": code])

        let (data, response) = try await URLSession.shared.data(for: request)
        let decoded = try? JSONDecoder().decode(FriendRedeemResponse.self, from: data)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }

        if http.statusCode == 200, let d = decoded, d.status == "success" {
            await UsageManager.shared.refreshQuota()
            return d.reward_points ?? 0
        } else {
            let msg = decoded?.error ?? "邀请码验证失败"
            throw NSError(domain: "Server", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    // 检查钥匙串中的用户状态
    private func checkUserInKeychain() {
        do {
            if let userId = try loadUserIdentifierFromKeychain() {
                self.userIdentifier = userId
                self.isLoggedIn = true
                print("AuthManager: 本地已登录，User ID: \(userId)")
                UsageManager.shared.setCurrentUser(userId, isLoggedIn: true)
                
                loadSubscriptionCache()
                
                Task {
                    await updateSubscriptionStatus()
                    await checkServerSubscriptionStatus()
                }
            } else {
                self.isLoggedIn = false
                UsageManager.shared.setCurrentUser(nil, isLoggedIn: false)
                Task { await updateSubscriptionStatus() }
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
        request.requestedScopes = [.fullName, .email]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }
    
    func signOut() {
        self.isLoggedIn = false
        UsageManager.shared.setCurrentUser(nil, isLoggedIn: false)
        self.userIdentifier = nil
        self.subscriptionExpiryDate = nil
        
        try? deleteUserIdentifierFromKeychain()
        
        Task {
            await updateSubscriptionStatus()
            print("AuthManager: 登出完成，已重新校验本地权限")
        }
    }

    func deleteAccount() async throws {
        guard let userId = userIdentifier else { throw URLError(.userAuthenticationRequired) }
        
        let url = URL(string: "\(serverBaseURL)/user/delete")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = ["user_id": userId]
        request.httpBody = try JSONEncoder().encode(body)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        await MainActor.run {
            self.signOut()
            print("AuthManager: 账号已彻底删除并登出。")
        }
    }

    // MARK: - StoreKit 2
    func listenForTransactions() -> Task<Void, Error> {
        return Task.detached {
            for await result in StoreKit.Transaction.updates {
                await self.handleTransactionUpdate(result)
            }
        }
    }
    
    private func handleTransactionUpdate(_ result: VerificationResult<StoreKit.Transaction>) async {
        do {
            let transaction = try checkVerified(result)
            await updateSubscriptionStatus()
            await transaction.finish()
        } catch {
            print("验证失败: \(error)")
        }
    }
    
    func updateSubscriptionStatus() async {
        var hasActiveSubscription = false
        var latestExpirationDate: Date? = nil
        
        for await result in StoreKit.Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)
                if transaction.productID == subscriptionProductID {
                    if let expirationDate = transaction.expirationDate, expirationDate > Date() {
                        hasActiveSubscription = true
                        if latestExpirationDate == nil || expirationDate > latestExpirationDate! {
                            latestExpirationDate = expirationDate
                        }
                    }
                }
            } catch {
                print("Failed to verify transaction: \(error)")
            }
        }
        
        let finalStatus = hasActiveSubscription
        let finalDate = latestExpirationDate
        let finalDateStr = latestExpirationDate?.ISO8601Format()
        
        await MainActor.run {
            // 【修复 B2】只有 StoreKit 的时间才写进 appleEntitlementExpiry
            self.hasAppleEntitlement = finalStatus
            self.appleEntitlementExpiry = finalDate
            
            if finalStatus {
                self.isSubscribed = true
                self.subscriptionExpiryDate = finalDateStr
                self.saveSubscriptionCache(isSubscribed: true, expiryDate: finalDateStr)
                print("AuthManager: 发现有效 Apple 订阅 (VIP)")
            } else {
                if !self.isLoggedIn {
                    self.isSubscribed = false
                    self.subscriptionExpiryDate = nil
                    self.clearSubscriptionCache()
                    print("AuthManager: 无 Apple 订阅且未登录 -> 重置为免费版")
                }
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
        // 【修复 B2】只有 Apple 侧确实有凭证才同步；服务器端 VIP 不需要也不应该回写
        if hasAppleEntitlement {
            try await syncPurchaseToServer(userId: userId)
        }
        // 无论如何再拉一次服务器权威状态
        await checkServerSubscriptionStatus()
    }

    // MARK: - Server Sync
    private func syncPurchaseToServer(userId: String) async throws {
        // 【修复 B2】只上报 StoreKit 真实到期时间
        guard let realExpiry = appleEntitlementExpiry, realExpiry > Date() else {
            print("AuthManager: 未取得 Apple 到期时间，跳过服务器同步（避免把后门/服务器时间回写）")
            return
        }
        
        let url = URL(string: "\(serverBaseURL)/payment/subscribe")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "user_id": userId,
            "explicit_expiry": realExpiry.ISO8601Format()
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            print("同步服务器失败，但本地已购买成功")
            return
        }
        print("服务器同步成功")
    }
    
    /// 服务器权威状态（手动改库 / 后门 / 安卓端购买 都走这里生效）
    func checkServerSubscriptionStatus() async {
        guard let userId = userIdentifier,
              let encoded = userId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
        guard let url = URL(string: "\(serverBaseURL)/user/status?user_id=\(encoded)") else { return }
        
        do {
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData   // 【新增】避免读到旧缓存
            req.timeoutInterval = 10
            let (data, _) = try await URLSession.shared.data(for: req)
            struct StatusResponse: Codable {
                let is_subscribed: Bool
                let subscription_expires_at: String?
            }
            let status = try JSONDecoder().decode(StatusResponse.self, from: data)
            
            await MainActor.run {
                if status.is_subscribed {
                    self.isSubscribed = true
                    self.subscriptionExpiryDate = status.subscription_expires_at
                    self.saveSubscriptionCache(isSubscribed: true, expiryDate: status.subscription_expires_at)
                    print("AuthManager: 服务器确认 VIP，到期 \(status.subscription_expires_at ?? "-")")
                } else {
                    print("AuthManager: 服务器显示无订阅/已过期")
                    // 服务器说没有 → 只保留本机 Apple 凭证这一条退路
                    if self.hasAppleEntitlement {
                        self.isSubscribed = true
                        self.subscriptionExpiryDate = self.appleEntitlementExpiry?.ISO8601Format()
                        self.saveSubscriptionCache(isSubscribed: true, expiryDate: self.subscriptionExpiryDate)
                        print("AuthManager: 但本机存在有效 Apple 订阅，保持 VIP")
                    } else {
                        self.isSubscribed = false
                        self.subscriptionExpiryDate = nil
                        self.clearSubscriptionCache()
                    }
                }
            }
        } catch {
            print("AuthManager: Server status check failed: \(error)")
        }
    }
    
    /// 【新增】一次性刷新全部权限（供下拉刷新 / 回前台调用）
    func refreshSubscriptionAll() async {
        await updateSubscriptionStatus()
        await checkServerSubscriptionStatus()
    }

    // MARK: - ASAuthorization Delegate
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        if let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential {
            guard let identityTokenData = appleIDCredential.identityToken,
                  let identityToken = String(data: identityTokenData, encoding: .utf8) else { return }
            
            let userId = appleIDCredential.user
            
            Task {
                do {
                    try saveUserIdentifierToKeychain(userId)
                    
                    await MainActor.run {
                        self.userIdentifier = userId
                        self.isLoggedIn = true
                        UsageManager.shared.setCurrentUser(userId, isLoggedIn: true)
                        self.isLoggingIn = true
                    }
                    
                    try await sendTokenToServer(token: identityToken, userId: userId)
                    await updateSubscriptionStatus()
                    await checkServerSubscriptionStatus()
                    
                    await MainActor.run { self.isLoggingIn = false }
                } catch {
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
            if authResponse.is_subscribed {
                self.isSubscribed = true
                self.subscriptionExpiryDate = authResponse.subscription_expires_at
                self.saveSubscriptionCache(isSubscribed: true, expiryDate: authResponse.subscription_expires_at)
                print("AuthManager: 服务器认证成功，用户是 VIP")
            } else {
                print("AuthManager: 服务器认证成功，用户暂无服务器端订阅")
            }
        }
    }

    // MARK: - Caching（【修复 B1】缓存必须带过期校验）
    private func saveSubscriptionCache(isSubscribed: Bool, expiryDate: String?) {
        UserDefaults.standard.set(isSubscribed, forKey: cacheIsSubscribedKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cacheSavedAtKey)
        if let date = expiryDate {
            UserDefaults.standard.set(date, forKey: cacheExpiryDateKey)
        } else {
            UserDefaults.standard.removeObject(forKey: cacheExpiryDateKey)
        }
    }
    
    private func loadSubscriptionCache() {
        guard UserDefaults.standard.bool(forKey: cacheIsSubscribedKey) else { return }
        let cachedExpiry = UserDefaults.standard.string(forKey: cacheExpiryDateKey)
        
        if let s = cachedExpiry, let d = Self.parseISODate(s) {
            // 有明确到期时间：过期直接作废，绝不"永久 VIP"
            guard d > Date() else {
                clearSubscriptionCache()
                print("AuthManager: 本地缓存已过期(\(s))，不再赋予 VIP")
                return
            }
        } else {
            // 老缓存没有到期时间：只给有限宽限期
            let savedAt = UserDefaults.standard.double(forKey: cacheSavedAtKey)
            let age = Date().timeIntervalSince1970 - savedAt
            guard savedAt > 0, age < cacheGraceDays * 86400 else {
                clearSubscriptionCache()
                print("AuthManager: 无到期时间的旧缓存已超过宽限期，作废")
                return
            }
        }
        
        self.isSubscribed = true
        self.subscriptionExpiryDate = cachedExpiry
        print("AuthManager: 已加载本地缓存，暂时赋予 VIP 权限（待服务器校正）")
    }
    
    private func clearSubscriptionCache() {
        UserDefaults.standard.removeObject(forKey: cacheIsSubscribedKey)
        UserDefaults.standard.removeObject(forKey: cacheExpiryDateKey)
        UserDefaults.standard.removeObject(forKey: cacheSavedAtKey)
    }
    
    /// 宽松解析服务器/StoreKit 的 ISO8601 时间
    static func parseISODate(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        if let d = f2.date(from: s) { return d }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let d = df.date(from: s) { return d }
        }
        return nil
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
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        ZStack {
            Color(UIColor.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 30) {
                Spacer()

                VStack(spacing: 15) {
                    Image(systemName: "newspaper.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.blue)
                    
                    Text("登录 【美股精灵】")
                        .font(.largeTitle.bold())
                        .foregroundColor(.primary)
                    
                    Text("成功登录后\n即使更换了设备\n也可以同步您的订阅状态")
                        .font(.headline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()

                VStack(spacing: 20) {
                    if authManager.isLoggingIn {
                        ProgressView().scaleEffect(1.5)
                    } else {
                        SignInWithAppleButton(
                            .signIn,
                            onRequest: { _ in },
                            onCompletion: { _ in }
                        )
                        .onTapGesture { authManager.signInWithApple() }
                        .signInWithAppleButtonStyle(colorScheme == .light ? .black : .white)
                        .frame(height: 50)
                        .cornerRadius(10)
                        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
                    }

                    if let errorMessage = authManager.errorMessage {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 40)

                Spacer()
                
                Button("稍后再说") { dismiss() }
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.bottom, 20)
            }
        }
        .onChange(of: authManager.isLoggedIn) { _, newValue in
            if newValue { dismiss() }
        }
    }
}