import SwiftUI
import AuthenticationServices
import Security
import StoreKit

enum KeychainError: Error {
    case duplicateItem
    case unknown(OSStatus)
    case dataConversionError
    case itemNotFound
}

@MainActor
class AuthManager: NSObject, ObservableObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {

    static let shared = AuthManager()

    @Published var isLoggedIn: Bool = false
    @Published var isLoggingIn: Bool = false
    @Published var isSubscribed: Bool = false
    @Published var subscriptionExpiryDate: String?

    @Published var isVideoModuleBlocked: Bool = false
    @Published var errorMessage: String?

    // ★★★【需求4】任何旧代码把它置 true，都会被拦截成"直接拉起苹果订阅"。
    //     把 PurchaseFlowManager.useDirectPurchase 改成 false，就自动回到旧的 SubscriptionView 中转页。
    @Published var showSubscriptionSheet: Bool = false {
        didSet {
            guard showSubscriptionSheet else { return }
            if PurchaseFlowManager.useDirectPurchase {
                showSubscriptionSheet = false          // 递归安全：置 false 时直接 return
                PurchaseFlowManager.shared.startPurchase(auth: self, reason: "showSubscriptionSheet")
            }
        }
    }

    /// 强制走旧中转页（个人中心「升级专业版」/ 审核入口用）
    func presentLegacySubscriptionSheet() {
        let saved = PurchaseFlowManager.useDirectPurchase
        PurchaseFlowManager.useDirectPurchase = false
        showSubscriptionSheet = true
        PurchaseFlowManager.useDirectPurchase = saved
    }

    private(set) var userIdentifier: String?

    private(set) var hasAppleEntitlement: Bool = false
    private var appleEntitlementExpiry: Date?

    /// ★【需求3】免登录订阅用的设备标识（本地持久化，避免 IDFV 变动）
    let anonymousDeviceId: String = AuthManager.makeAnonymousDeviceId()

    /// 是否属于"未登录但已订阅"的用户
    var isAnonymousSubscribed: Bool { isSubscribed && !isLoggedIn }

    private let userIdentifierKey = "zhangyan.ONews"
    private let subscriptionProductID = "com.zhangyan.onews.subscription.monthly"

    private let serverBaseURL = "http://106.15.183.158:5001/api/ONews"

    private let cacheIsSubscribedKey = "AuthCache_IsSubscribed"
    private let cacheExpiryDateKey   = "AuthCache_ExpiryDate"
    private let cacheVideoBlockedKey = "AuthCache_VideoBlocked"
    private let cacheSavedAtKey      = "AuthCache_SavedAt"
    private let anonReportedAtKey    = "AnonSub_LastReportedAt"
    private let cacheGracePeriod: TimeInterval = 7 * 24 * 3600

    private var updateListenerTask: Task<Void, Error>?

    var isPermanentVIP: Bool {
        guard isSubscribed, let dateStr = subscriptionExpiryDate else { return false }
        return dateStr.hasPrefix("2099")
    }

    // MARK: - 设备标识

    private static func makeAnonymousDeviceId() -> String {
        let key = "AnonSub_DeviceIdentifier"
        if let s = UserDefaults.standard.string(forKey: key), !s.isEmpty { return s }
        let idfv = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        let value = "dev_" + idfv
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    // MARK: - 时间解析

    static func parseServerDate(_ raw: String?) -> Date? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if !s.contains("T"), s.contains(" ") { s = s.replacingOccurrences(of: " ", with: "T") }

        let iso = ISO8601DateFormatter()
        for opts in [[.withInternetDateTime, .withFractionalSeconds],
                     [ISO8601DateFormatter.Options.withInternetDateTime]] as [ISO8601DateFormatter.Options] {
            iso.formatOptions = opts
            if let d = iso.date(from: s) { return d }
        }

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

    deinit { updateListenerTask?.cancel() }

    private func checkUserInKeychain() {
        do {
            if let userId = try loadUserIdentifierFromKeychain() {
                self.userIdentifier = userId
                self.isLoggedIn = true
                print("AuthManager: 本地已登录，User ID: \(userId)")
                UserDefaults.standard.set(userId, forKey: "current_user_id")

                loadSubscriptionCache()

                Task {
                    await updateSubscriptionStatus()
                    await checkServerSubscriptionStatus()
                }
            } else {
                self.isLoggedIn = false
                // ★【需求3】未登录也可能是订阅用户：先读缓存点亮，再让 StoreKit 裁决
                loadSubscriptionCache()
                Task {
                    await updateSubscriptionStatus()
                    await reconcileAnonymousEntitlement()
                }
            }
        } catch {
            self.isLoggedIn = false
            self.isSubscribed = false
            print("AuthManager: 检查钥匙串时出错: \(error.localizedDescription)")
        }
    }

    // MARK: - Sign In / Out（★需求1：直接拉起苹果登录，无中转页）

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
        self.subscriptionExpiryDate = nil
        self.isVideoModuleBlocked = false
        clearSubscriptionCache()
        UserDefaults.standard.removeObject(forKey: "current_user_id")

        NewsQuotaManager.shared.reset()
        FreeQuotaManager.shared.reset()

        // 登出后如果 Apple 本地仍有有效订阅（免登录订阅），保持 VIP
        Task {
            await updateSubscriptionStatus()
            await reconcileAnonymousEntitlement()
        }
        print("AuthManager: 用户已登出。")
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
    }

    // MARK: - 邀请码兑换（仍需登录，因为要绑账号）

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
        applyEntitlement(isSubscribed: r.is_subscribed, expiry: r.subscription_expires_at, source: "redeem")
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

    /// ★★★【需求3+4】登录 / 未登录都能买；未登录时把凭证记录到服务器的匿名表
    func purchaseSubscription() async throws -> Bool {
        let products = try await Product.products(for: [subscriptionProductID])
        guard let product = products.first else {
            throw NSError(domain: "StoreError", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: Localized.errProductNotFound])
        }

        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)

            self.hasAppleEntitlement = true
            self.appleEntitlementExpiry = transaction.expirationDate
            applyEntitlement(isSubscribed: true,
                             expiry: transaction.expirationDate.map { Self.isoString($0) },
                             source: isLoggedIn ? "purchase" : "purchase-anonymous")

            if let userId = userIdentifier, let exp = transaction.expirationDate {
                await syncAppleExpiryToServer(userId: userId, expiry: exp)
            } else {
                await reportAnonymousSubscription(transaction, force: true)
            }

            await transaction.finish()
            self.showSubscriptionSheet = false
            return true

        case .userCancelled:
            return false
        case .pending:
            return false
        @unknown default:
            return false
        }
    }

    func handleAppDidBecomeActive() {
        Task {
            await updateSubscriptionStatus()
            if isLoggedIn {
                await checkServerSubscriptionStatus()
            } else {
                await reconcileAnonymousEntitlement()
            }
        }
    }

    func restorePurchases() async throws {
        try await AppStore.sync()
        await updateSubscriptionStatus()
        if isLoggedIn { await checkServerSubscriptionStatus() }
        else { await reconcileAnonymousEntitlement() }
    }

    /// 只根据 Apple 本地凭证更新状态
    func updateSubscriptionStatus() async {
        var active = false
        var latest: Date? = nil
        var latestTransaction: StoreKit.Transaction? = nil

        for await result in StoreKit.Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)
                guard transaction.productID == subscriptionProductID else { continue }
                if let exp = transaction.expirationDate, exp > Date() {
                    active = true
                    if latest == nil || exp > latest! { latest = exp; latestTransaction = transaction }
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
                             source: isLoggedIn ? "StoreKit" : "StoreKit-anonymous")
            if let userId = userIdentifier, let exp = latest {
                await syncAppleExpiryToServer(userId: userId, expiry: exp)
            } else if let t = latestTransaction {
                await reportAnonymousSubscription(t, force: false)   // 每天最多一次
            }
        } else {
            print("AuthManager: Apple 本地无有效订阅凭证。")
        }
    }

    /// 未登录用户的降权逻辑：完全以 StoreKit 本地凭证为准（不依赖服务器，device id 不可信）
    private func reconcileAnonymousEntitlement() async {
        guard !isLoggedIn else { return }
        if !hasAppleEntitlement && isSubscribed {
            print("AuthManager: 未登录且 Apple 无凭证 → 取消匿名 VIP。")
            applyEntitlement(isSubscribed: false, expiry: nil, source: "anonymous-reconcile")
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
            handleSignInError(Localized.errAppleIDCredentialFailed); return
        }
        guard let tokenData = cred.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8) else {
            handleSignInError(Localized.errNoIdentityToken); return
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
            } catch {
                handleSignInError("\(Localized.errServerVerifyFailed): \(error.localizedDescription)")
            }
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        if (error as? ASAuthorizationError)?.code == .canceled {
            handleSignInError(nil)
        } else {
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
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "identity_token": token, "user_id": userId, "device_id": formattedDeviceId
        ])

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
    }

    private func syncAppleExpiryToServer(userId: String, expiry: Date) async {
        guard let url = URL(string: "\(serverBaseURL)/payment/subscribe") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "user_id": userId, "explicit_expiry": Self.isoString(expiry)
        ])
        do {
            let (_, resp) = try await URLSession.shared.data(for: request)
            print("AuthManager: 同步到期时间 -> HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        } catch {
            print("AuthManager: 同步订阅失败: \(error.localizedDescription)")
        }
    }

    /// ★★★【需求3】把"免登录订阅"记到服务器（真正可靠的唯一键是 original_transaction_id）
    private func reportAnonymousSubscription(_ transaction: StoreKit.Transaction, force: Bool) async {
        // 非首次购买时，每天最多上报一次，省流量
        if !force {
            let last = UserDefaults.standard.object(forKey: anonReportedAtKey) as? Date ?? .distantPast
            guard Date().timeIntervalSince(last) > 12 * 3600 else { return }
        }
        guard let url = URL(string: "\(serverBaseURL)/payment/anonymous_subscribe") else { return }
        guard let exp = transaction.expirationDate else { return }

        var body: [String: Any] = [
            "device_id": anonymousDeviceId,
            "original_transaction_id": String(transaction.originalID),
            "transaction_id": String(transaction.id),
            "product_id": transaction.productID,
            "expiry": Self.isoString(exp),
            "purchase_date": Self.isoString(transaction.purchaseDate),
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        ]
        if #available(iOS 16.0, *) { body["environment"] = transaction.environment.rawValue }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, resp) = try await URLSession.shared.data(for: request)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            print("AuthManager: 匿名订阅上报 HTTP \(code)")
            if code == 200 { UserDefaults.standard.set(Date(), forKey: anonReportedAtKey) }
        } catch {
            print("AuthManager: 匿名订阅上报失败: \(error.localizedDescription)")
        }
    }

    func checkServerSubscriptionStatus() async {
        guard let userId = userIdentifier else { return }
        let result = await fetchServerStatus(url: "\(serverBaseURL)/user/status?user_id=\(userId)")
        guard result.reachable else { return }

        if let blocked = result.videoBlocked {
            self.isVideoModuleBlocked = blocked
            UserDefaults.standard.set(blocked, forKey: cacheVideoBlockedKey)
        }
        if result.isSubscribed {
            applyEntitlement(isSubscribed: true, expiry: result.expiryDate, source: "server")
            return
        }
        if hasAppleEntitlement, let exp = appleEntitlementExpiry {
            applyEntitlement(isSubscribed: true, expiry: Self.isoString(exp), source: "StoreKit-fix")
            await syncAppleExpiryToServer(userId: userId, expiry: exp)
        } else {
            applyEntitlement(isSubscribed: false, expiry: nil, source: "server")
        }
    }

    private func fetchServerStatus(url urlString: String)
        async -> (reachable: Bool, isSubscribed: Bool, expiryDate: String?, videoBlocked: Bool?) {
        guard let url = URL(string: urlString) else { return (false, false, nil, nil) }
        do {
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            struct StatusResponse: Codable {
                let is_subscribed: Bool
                let subscription_expires_at: String?
                let video_module_blocked: Bool?
            }
            do {
                let s = try JSONDecoder().decode(StatusResponse.self, from: data)
                return (true, s.is_subscribed, s.subscription_expires_at, s.video_module_blocked)
            } catch {
                print("AuthManager: ⚠️ 服务器返回无法解析（HTTP \(code)）")
                return (false, false, nil, nil)
            }
        } catch {
            return (false, false, nil, nil)
        }
    }

    // MARK: - 状态落地 + 缓存

    private func applyEntitlement(isSubscribed: Bool, expiry: String?, source: String) {
        self.isSubscribed = isSubscribed
        self.subscriptionExpiryDate = isSubscribed ? expiry : nil
        if isSubscribed { saveSubscriptionCache(isSubscribed: true, expiryDate: expiry) }
        else { clearSubscriptionCache() }
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
        guard Date().timeIntervalSince(savedAt) < cacheGracePeriod else { return }
        guard let str = d.string(forKey: cacheExpiryDateKey),
              let date = Self.parseServerDate(str), date > Date() else { return }
        self.isSubscribed = true
        self.subscriptionExpiryDate = str
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

// MARK: - 订阅守卫修饰符（保留）

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
    func canAccessVideoContent() -> Bool { isSubscribed }
}