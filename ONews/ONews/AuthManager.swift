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

    // ✅ 全局唯一实例（AppDelegate 必须用 AuthManager.shared，不要再 new）
    static let shared = AuthManager()

    @Published var isLoggedIn: Bool = false
    @Published var isLoggingIn: Bool = false
    @Published var isSubscribed: Bool = false
    @Published var subscriptionExpiryDate: String?

    // 视频模块黑名单状态（服务端按 user_id 下发）
    @Published var isVideoModuleBlocked: Bool = false

    @Published var errorMessage: String?
    @Published var showSubscriptionSheet: Bool = false

    private(set) var userIdentifier: String?

    // ==========================================================
    // 【核心修复】Apple(StoreKit) 侧是否真的有有效订阅。
    // 它只由 Transaction.currentEntitlements 决定，绝不看 UserDefaults 缓存。
    // 老代码把"缓存里的 2099"当成 Apple 本地凭证，导致后门状态被回写服务器、永远降不了权。
    // ==========================================================
    private(set) var hasAppleEntitlement: Bool = false
    private var appleEntitlementExpiry: Date?

    private let userIdentifierKey = "zhangyan.ONews"
    private let subscriptionProductID = "com.zhangyan.onews.subscription.monthly"

    private let serverBaseURL = "http://106.15.183.158:5001/api/ONews"
    // ❌ 已移除 predictionServerBaseURL（Prediction 功能已下线）

    private let cacheIsSubscribedKey = "AuthCache_IsSubscribed"
    private let cacheExpiryDateKey   = "AuthCache_ExpiryDate"
    private let cacheVideoBlockedKey = "AuthCache_VideoBlocked"
    private let cacheSavedAtKey      = "AuthCache_SavedAt"
    /// 离线宽限期：超过这个时长没有成功刷新过，就不再相信本地缓存的 VIP（防止永久白嫖）
    private let cacheGracePeriod: TimeInterval = 7 * 24 * 3600

    private var updateListenerTask: Task<Void, Error>?

    /// 是否为后门/永久 VIP（服务器用 2099 作为哨兵值下发）
    var isPermanentVIP: Bool {
        guard isSubscribed, let dateStr = subscriptionExpiryDate else { return false }
        return dateStr.hasPrefix("2099")
    }

    // MARK: - 时间解析（统一工具）

    /// 【核心修复】兼容服务器可能返回的所有格式：
    /// 2026-09-10T06:21:00Z / +08:00 / 无时区(按 UTC) / 空格分隔 / 带小数秒 / 仅日期
    static func parseServerDate(_ raw: String?) -> Date? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if !s.contains("T"), s.contains(" ") {
            s = s.replacingOccurrences(of: " ", with: "T")
        }
        
        // 1) 标准 ISO8601（必须带时区）
        let iso = ISO8601DateFormatter()
        let optionsList: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime]
        ]
        for opts in optionsList {
            iso.formatOptions = opts
            if let d = iso.date(from: s) { return d }
        }
        
        // 2) 无时区 —— 一律按 UTC 解释（和服务器保持一致）
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
                    "yyyy-MM-dd'T'HH:mm:ss.SSS",
                    "yyyy-MM-dd'T'HH:mm:ss",
                    "yyyy-MM-dd'T'HH:mm",
                    "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let d = df.date(from: s) { return d }
        }
        return nil
    }

    /// 上报给服务器的统一格式：2026-09-10T06:21:00Z
    static func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    // MARK: - Init

    override init() {
        super.init()
        checkUserInKeychain()
        updateListenerTask = listenForTransactions()
    }

    deinit {
        updateListenerTask?.cancel()
    }

    private func checkUserInKeychain() {
        do {
            if let userId = try loadUserIdentifierFromKeychain() {
                self.userIdentifier = userId
                self.isLoggedIn = true
                print("AuthManager: 本地已登录，User ID: \(userId)")
                UserDefaults.standard.set(userId, forKey: "current_user_id")

                // 先用缓存快速点亮 UI（带过期 + 宽限期校验）
                loadSubscriptionCache()

                // 再依次核对：Apple 本地凭证 → 服务器（服务器为最终权威）
                Task {
                    await updateSubscriptionStatus()
                    await checkServerSubscriptionStatus()
                }
            } else {
                self.isLoggedIn = false
                self.isSubscribed = false
                clearSubscriptionCache()
            }
        } catch {
            self.isLoggedIn = false
            self.isSubscribed = false
            print("AuthManager: 检查钥匙串时出错: \(error.localizedDescription)")
        }
    }

    // MARK: - Sign In / Out

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
        try? deleteUserIdentifierFromKeychain()
        self.userIdentifier = nil
        self.isLoggedIn = false
        self.isSubscribed = false
        self.subscriptionExpiryDate = nil
        self.isVideoModuleBlocked = false
        self.hasAppleEntitlement = false
        self.appleEntitlementExpiry = nil
        clearSubscriptionCache()
        UserDefaults.standard.removeObject(forKey: "current_user_id")

        // 【新增】点数账本一并清零，胶囊不会残留旧点数
        NewsQuotaManager.shared.reset()
        FreeQuotaManager.shared.reset()

        print("AuthManager: 用户已登出，本地订阅缓存与点数已清空。")
    }

    func deleteAccount() async throws {
        guard let userId = userIdentifier else { throw URLError(.userAuthenticationRequired) }

        let url = URL(string: "\(serverBaseURL)/user/delete")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["user_id": userId])

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        self.signOut()
        print("AuthManager: 账号已彻底删除并登出。")
    }

    // MARK: - 邀请码兑换

    func redeemInviteCode(_ code: String) async throws {
        guard let userId = userIdentifier else { throw URLError(.userAuthenticationRequired) }

        let url = URL(string: "\(serverBaseURL)/user/redeem")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["user_id": userId, "invite_code": code])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }

        if http.statusCode != 200 {
            if let json = try? JSONDecoder().decode([String: String].self, from: data),
               let msg = json["error"] {
                throw NSError(domain: "AuthError", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: msg])
            }
            throw URLError(.badServerResponse)
        }

        struct RedeemResponse: Codable {
            let is_subscribed: Bool
            let subscription_expires_at: String?
        }
        let r = try JSONDecoder().decode(RedeemResponse.self, from: data)
        applyEntitlement(isSubscribed: r.is_subscribed,
                         expiry: r.subscription_expires_at,
                         source: "redeem")
        print("AuthManager: 邀请码兑换成功。")
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

    func purchaseSubscription() async throws -> Bool {
        guard let userId = userIdentifier else { throw URLError(.userAuthenticationRequired) }

        let products = try await Product.products(for: [subscriptionProductID])
        guard let product = products.first else {
            throw NSError(domain: "StoreError", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: Localized.errProductNotFound])
        }

        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)

            // 以 Apple 的过期时间为准
            self.hasAppleEntitlement = true
            self.appleEntitlementExpiry = transaction.expirationDate
            applyEntitlement(isSubscribed: true,
                             expiry: transaction.expirationDate.map { Self.isoString($0) },
                             source: "purchase")

            if let exp = transaction.expirationDate {
                await syncAppleExpiryToServer(userId: userId, expiry: exp)
            }
            await transaction.finish()
            self.showSubscriptionSheet = false
            return true

        case .userCancelled:
            print(Localized.errUserCancelled)
            return false
        case .pending:
            print("交易挂起")
            return false
        @unknown default:
            print("未知状态")
            return false
        }
    }

    func handleAppDidBecomeActive() {
        Task {
            await updateSubscriptionStatus()
            await checkServerSubscriptionStatus()
        }
    }

    func restorePurchases() async throws {
        try await AppStore.sync()
        await updateSubscriptionStatus()
        await checkServerSubscriptionStatus()
    }

    /// 只根据 Apple 本地凭证更新状态（有 → 立刻给权限并同步服务器；没有 → 交给服务器裁决）
    func updateSubscriptionStatus() async {
        var active = false
        var latest: Date? = nil

        for await result in StoreKit.Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)
                guard transaction.productID == subscriptionProductID else { continue }
                if let exp = transaction.expirationDate, exp > Date() {
                    active = true
                    if latest == nil || exp > latest! { latest = exp }
                }
            } catch {
                print("Failed to verify transaction: \(error)")
            }
        }

        self.hasAppleEntitlement = active
        self.appleEntitlementExpiry = latest

        if active {
            applyEntitlement(isSubscribed: true,
                             expiry: latest.map { Self.isoString($0) },
                             source: "StoreKit")
            if let userId = userIdentifier, let exp = latest {
                await syncAppleExpiryToServer(userId: userId, expiry: exp)
            }
        } else {
            print("AuthManager: Apple 本地无有效订阅凭证，等待服务器裁决。")
        }
    }

    func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw NSError(domain: "StoreError", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: Localized.errTransactionUnverified])
        case .verified(let safe):
            return safe
        }
    }

    // MARK: - Apple Sign In Delegate

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential else {
            handleSignInError(Localized.errAppleIDCredentialFailed)
            return
        }
        guard let tokenData = cred.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8) else {
            handleSignInError(Localized.errNoIdentityToken)
            return
        }
        let userId = cred.user

        Task {
            do {
                try await sendTokenToServer(token: identityToken, userId: userId)
                try saveUserIdentifierToKeychain(userId)
                UserDefaults.standard.set(userId, forKey: "current_user_id")

                self.userIdentifier = userId
                self.isLoggedIn = true
                self.isLoggingIn = false

                await updateSubscriptionStatus()
                await checkServerSubscriptionStatus()
                print("AuthManager: 登录成功。订阅状态: \(self.isSubscribed)")
            } catch {
                handleSignInError("\(Localized.errServerVerifyFailed): \(error.localizedDescription)")
            }
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        if (error as? ASAuthorizationError)?.code == .canceled {
            handleSignInError(nil)
        } else {
            print("AuthManager: Apple 登录授权失败: \(error.localizedDescription)")
            handleSignInError(Localized.errLoginFailedRetry)
        }
    }

    private func handleSignInError(_ message: String?) {
        self.isLoggingIn = false
        self.errorMessage = message
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        return UIApplication.shared.connectedScenes
            .filter { $0.activationState == .foregroundActive }
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    // MARK: - Server

    private func sendTokenToServer(token: String, userId: String) async throws {
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? ""
        let formattedDeviceId = deviceId.isEmpty ? "" : "dev_" + deviceId

        let url = URL(string: "\(serverBaseURL)/auth/apple")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "identity_token": token,
            "user_id": userId,
            "device_id": formattedDeviceId
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        struct AuthResponse: Codable {
            let is_subscribed: Bool
            let subscription_expires_at: String?
            let video_module_blocked: Bool?
        }
        let r = try JSONDecoder().decode(AuthResponse.self, from: data)

        self.isVideoModuleBlocked = r.video_module_blocked ?? false
        UserDefaults.standard.set(self.isVideoModuleBlocked, forKey: self.cacheVideoBlockedKey)

        if r.is_subscribed {
            applyEntitlement(isSubscribed: true, expiry: r.subscription_expires_at, source: "auth")
        }
        // ❌ 已移除向 Prediction 后端的静默注册
    }

    /// 只把 **Apple 的真实到期时间** 同步给服务器；绝不上报缓存/2099 之类的后门时间
    private func syncAppleExpiryToServer(userId: String, expiry: Date) async {
        guard let url = URL(string: "\(serverBaseURL)/payment/subscribe") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["user_id": userId, "explicit_expiry": Self.isoString(expiry)]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, resp) = try await URLSession.shared.data(for: request)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            print("AuthManager: 同步 Apple 到期时间(\(Self.isoString(expiry))) -> 服务器，HTTP \(code)")
        } catch {
            print("AuthManager: 同步订阅到服务器失败: \(error.localizedDescription)")
        }
    }

    /// 服务器是最终权威：说没订阅 + Apple 本地也没凭证 → 立即降权并清缓存
    func checkServerSubscriptionStatus() async {
        guard let userId = userIdentifier else { return }

        let result = await fetchServerStatus(
            url: "\(serverBaseURL)/user/status?user_id=\(userId)")

        guard result.reachable else {
            print("AuthManager: 服务器不可达，保留当前状态（缓存宽限期内）。")
            return
        }

        if let blocked = result.videoBlocked {
            self.isVideoModuleBlocked = blocked
            UserDefaults.standard.set(blocked, forKey: cacheVideoBlockedKey)
        }

        if result.isSubscribed {
            applyEntitlement(isSubscribed: true, expiry: result.expiryDate, source: "server")
            return
        }

        // 服务器说没有
        if hasAppleEntitlement, let exp = appleEntitlementExpiry {
            // Apple 侧确实有 → 以 Apple 为准，并把真实时间补给服务器
            print("AuthManager: 服务器无记录，但 Apple 有有效订阅，补同步。")
            applyEntitlement(isSubscribed: true, expiry: Self.isoString(exp), source: "StoreKit-fix")
            await syncAppleExpiryToServer(userId: userId, expiry: exp)
        } else {
            print("AuthManager: 服务器 + Apple 均无订阅 → 降权并清空缓存。")
            applyEntitlement(isSubscribed: false, expiry: nil, source: "server")
        }
    }

    private func fetchServerStatus(url urlString: String)
        async -> (reachable: Bool, isSubscribed: Bool, expiryDate: String?, videoBlocked: Bool?) {
        guard let url = URL(string: urlString) else { return (false, false, nil, nil) }
        do {
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData   // 顺手关掉 URLCache
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1

            struct StatusResponse: Codable {
                let is_subscribed: Bool
                let subscription_expires_at: String?
                let video_module_blocked: Bool?
            }
            do {
                let s = try JSONDecoder().decode(StatusResponse.self, from: data)
                print("AuthManager: /user/status HTTP \(code) -> sub=\(s.is_subscribed), exp=\(s.subscription_expires_at ?? "nil")")
                return (true, s.is_subscribed, s.subscription_expires_at, s.video_module_blocked)
            } catch {
                // ★ 关键：服务器有回应但内容不对 —— 这不是"没网"，是服务端出错了！
                let body = String(data: data, encoding: .utf8) ?? "<非文本>"
                print("""
                AuthManager: ⚠️ 服务器返回了无法解析的内容（这不是网络问题！）
                    HTTP \(code)
                    body: \(body.prefix(500))
                """)
                return (false, false, nil, nil)   // 仍按"不可信"处理，保守保留当前状态
            }
        } catch {
            print("AuthManager: 网络请求失败（真的不可达）: \(error.localizedDescription)")
            return (false, false, nil, nil)
        }
    }

    // MARK: - 状态落地 + 缓存

    private func applyEntitlement(isSubscribed: Bool, expiry: String?, source: String) {
        self.isSubscribed = isSubscribed
        self.subscriptionExpiryDate = isSubscribed ? expiry : nil
        if isSubscribed {
            saveSubscriptionCache(isSubscribed: true, expiryDate: expiry)
        } else {
            clearSubscriptionCache()
        }
        print("AuthManager: [\(source)] isSubscribed=\(isSubscribed), expiry=\(expiry ?? "nil")")
    }

    private func saveSubscriptionCache(isSubscribed: Bool, expiryDate: String?) {
        let d = UserDefaults.standard
        d.set(isSubscribed, forKey: cacheIsSubscribedKey)
        d.set(Date(), forKey: cacheSavedAtKey)
        if let s = expiryDate { d.set(s, forKey: cacheExpiryDateKey) }
        else { d.removeObject(forKey: cacheExpiryDateKey) }
    }

    private func loadSubscriptionCache() {
        let d = UserDefaults.standard
        self.isVideoModuleBlocked = d.bool(forKey: cacheVideoBlockedKey)

        guard d.bool(forKey: cacheIsSubscribedKey) else { return }
        let savedAt = d.object(forKey: cacheSavedAtKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(savedAt) < cacheGracePeriod else {
            print("AuthManager: 本地缓存超过离线宽限期，忽略。")
            return
        }
        guard let str = d.string(forKey: cacheExpiryDateKey),
              let date = Self.parseServerDate(str) else {
            print("AuthManager: 缓存到期时间无法解析，忽略。")
            return
        }
        guard date > Date() else {
            print("AuthManager: 本地缓存已过期。")
            return
        }
        self.isSubscribed = true
        self.subscriptionExpiryDate = str
        print("AuthManager: 已加载本地缓存，临时赋予 VIP（等待服务器核对）。")
    }

    private func clearSubscriptionCache() {
        let d = UserDefaults.standard
        d.removeObject(forKey: cacheIsSubscribedKey)
        d.removeObject(forKey: cacheExpiryDateKey)
        d.removeObject(forKey: cacheSavedAtKey)
        d.removeObject(forKey: cacheVideoBlockedKey)
    }

    // MARK: - Keychain

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
            if status == errSecDuplicateItem { throw KeychainError.duplicateItem }
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
        var ref: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &ref)
        if status == errSecSuccess {
            guard let data = ref as? Data, let id = String(data: data, encoding: .utf8) else { return nil }
            return id
        } else if status == errSecItemNotFound {
            return nil
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

// MARK: - LoginView（未改动）

struct LoginView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            Color.viewBackground.ignoresSafeArea()

            VStack(spacing: 30) {
                Spacer()
                VStack(spacing: 15) {
                    Image(systemName: "newspaper.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.primary)
                    Text(Localized.loginWelcome)
                        .font(.largeTitle.bold())
                        .foregroundColor(.primary)
                    Text(Localized.loginDesc)
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
                        .signInWithAppleButtonStyle(.black)
                        .frame(height: 50)
                        .cornerRadius(10)
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
                Button(Localized.later) { dismiss() }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 20)
            }
        }
    }
}

// MARK: - 订阅守卫修饰符

struct SubscriptionGateModifier: ViewModifier {
    @Binding var isPresented: Bool
    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) { SubscriptionView() }
    }
}

extension View {
    func subscriptionGate(isPresented: Binding<Bool>) -> some View {
        self.modifier(SubscriptionGateModifier(isPresented: isPresented))
    }
}

extension AuthManager {
    /// 检查是否有访问视频内容的权限
    func canAccessVideoContent() -> Bool { isSubscribed }
}