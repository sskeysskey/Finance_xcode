import SwiftUI
import AuthenticationServices
import Security
import StoreKit
import UIKit

enum KeychainError: Error {
    case duplicateItem
    case unknown(OSStatus)
    case dataConversionError
    case itemNotFound
}

@MainActor
final class AuthManager: NSObject, ObservableObject,
                         ASAuthorizationControllerDelegate,
                         ASAuthorizationControllerPresentationContextProviding {

    static let shared = AuthManager()

    @Published var isLoggedIn: Bool = false
    @Published var isLoggingIn: Bool = false
    @Published var isSubscribed: Bool = false
    @Published var subscriptionExpiryDate: String?
    @Published var isVideoModuleBlocked: Bool = false
    @Published var errorMessage: String?

    /// 旧代码把它置 true 时，默认直接拉起苹果订阅面板
    @Published var showSubscriptionSheet: Bool = false {
        didSet {
            guard showSubscriptionSheet else { return }
            if PurchaseFlowManager.useDirectPurchase {
                showSubscriptionSheet = false
                PurchaseFlowManager.shared.startPurchase(auth: self, reason: "showSubscriptionSheet")
            }
        }
    }

    /// 强制走中转页（个人中心「升级会员」/ 审核入口用）
    func presentLegacySubscriptionSheet() {
        let saved = PurchaseFlowManager.useDirectPurchase
        PurchaseFlowManager.useDirectPurchase = false
        showSubscriptionSheet = true
        PurchaseFlowManager.useDirectPurchase = saved
    }

    private(set) var userIdentifier: String?
    private(set) var hasAppleEntitlement: Bool = false
    private var appleEntitlementExpiry: Date?

    /// 免登录订阅的设备标识（= "dev_" + IDFV，同一开发者团队的 App 之间一致 → 可跨 App 共享）
    let anonymousDeviceId: String = AuthManager.makeAnonymousDeviceId()
    var currentIDFV: String { UIDevice.current.identifierForVendor?.uuidString ?? "" }
    var isAnonymousSubscribed: Bool { isSubscribed && !isLoggedIn }

    private let userIdentifierKey = "zhangyan.OVideo.appleUser"
    private let subscriptionProductID = StorePriceStore.productID
    private let serverBaseURL = "http://106.15.183.158:5001/api/OVideo"

    private let cacheIsSubscribedKey = "AuthCache_IsSubscribed"
    private let cacheExpiryDateKey   = "AuthCache_ExpiryDate"
    private let cacheVideoBlockedKey = "AuthCache_VideoBlocked"
    private let cacheSavedAtKey      = "AuthCache_SavedAt"
    private let anonReportedAtKey    = "AnonSub_LastReportedAt"
    private let crossAppExpiryKey    = "CrossAppAnon_Expiry"
    private let crossAppCheckedKey   = "CrossAppAnon_CheckedAt"
    private let cacheGracePeriod: TimeInterval = 7 * 24 * 3600
    private let crossAppGrace: TimeInterval   = 5 * 24 * 3600

    private var updateListenerTask: Task<Void, Error>?

    var isPermanentVIP: Bool {
        guard isSubscribed, let s = subscriptionExpiryDate else { return false }
        return s.hasPrefix("2099")
    }

    // MARK: - 设备标识
    private static func makeAnonymousDeviceId() -> String {
        let key = "AnonSub_DeviceIdentifier"
        if let s = UserDefaults.standard.string(forKey: key), !s.isEmpty { return s }
        let idfv = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        let v = "dev_" + idfv
        UserDefaults.standard.set(v, forKey: key)
        return v
    }

    // MARK: - 时间
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
        for f in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS",
                  "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            df.dateFormat = f
            if let d = df.date(from: s) { return d }
        }
        return nil
    }

    static func isoString(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
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
            if let uid = try loadUserIdentifierFromKeychain() {
                userIdentifier = uid
                isLoggedIn = true
                UserDefaults.standard.set(uid, forKey: "current_user_id")
                loadSubscriptionCache()
                Task {
                    await updateSubscriptionStatus()
                    await checkServerSubscriptionStatus()
                }
            } else {
                isLoggedIn = false
                loadSubscriptionCache()
                Task {
                    await updateSubscriptionStatus()
                    await reconcileAnonymousEntitlement()
                }
            }
        } catch {
            isLoggedIn = false
            isSubscribed = false
        }
    }

    // MARK: - Sign in / out
    func signInWithApple() {
        guard !isLoggingIn else { return }
        isLoggingIn = true
        errorMessage = nil
        let req = ASAuthorizationAppleIDProvider().createRequest()
        req.requestedScopes = [.fullName, .email]
        let c = ASAuthorizationController(authorizationRequests: [req])
        c.delegate = self
        c.presentationContextProvider = self
        c.performRequests()
    }

    func signOut() {
        try? deleteUserIdentifierFromKeychain()
        userIdentifier = nil
        isLoggedIn = false
        subscriptionExpiryDate = nil
        isVideoModuleBlocked = false
        clearSubscriptionCache()
        UserDefaults.standard.removeObject(forKey: "current_user_id")
        FreeQuotaManager.shared.reset()
        Task {
            await updateSubscriptionStatus()
            await reconcileAnonymousEntitlement()
        }
    }

    func deleteAccount() async throws {
        guard let uid = userIdentifier else { throw URLError(.userAuthenticationRequired) }
        var r = URLRequest(url: URL(string: "\(serverBaseURL)/user/delete")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(["user_id": uid])
        let (_, resp) = try await URLSession.shared.data(for: r)
        guard let h = resp as? HTTPURLResponse, h.statusCode == 200 else { throw URLError(.badServerResponse) }
        signOut()
    }

    // MARK: - 内部邀请码
    func redeemInviteCode(_ code: String) async throws {
        guard let uid = userIdentifier else { throw URLError(.userAuthenticationRequired) }
        var r = URLRequest(url: URL(string: "\(serverBaseURL)/user/redeem")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(["user_id": uid, "invite_code": code])
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard let h = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if h.statusCode != 200 {
            if let j = try? JSONDecoder().decode([String: String].self, from: data), let m = j["error"] {
                throw NSError(domain: "AuthError", code: h.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: m])
            }
            throw URLError(.badServerResponse)
        }
        struct R: Codable { let is_subscribed: Bool; let subscription_expires_at: String? }
        let d = try JSONDecoder().decode(R.self, from: data)
        applyEntitlement(isSubscribed: d.is_subscribed, expiry: d.subscription_expires_at, source: "redeem")
    }

    // MARK: - StoreKit 2
    func listenForTransactions() -> Task<Void, Error> {
        Task.detached {
            for await result in StoreKit.Transaction.updates {
                await self.handleTransactionUpdate(result)
            }
        }
    }

    private func handleTransactionUpdate(_ r: VerificationResult<StoreKit.Transaction>) async {
        do {
            let t = try checkVerified(r)
            await updateSubscriptionStatus()
            await t.finish()
        } catch { print("验证失败: \(error)") }
    }

    func purchaseSubscription() async throws -> Bool {
        let products = try await Product.products(for: [subscriptionProductID])
        guard let product = products.first else {
            throw NSError(domain: "StoreError", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: Localized.errProductNotFound])
        }
        switch try await product.purchase() {
        case .success(let v):
            let t = try checkVerified(v)
            hasAppleEntitlement = true
            appleEntitlementExpiry = t.expirationDate
            applyEntitlement(isSubscribed: true,
                             expiry: t.expirationDate.map { Self.isoString($0) },
                             source: isLoggedIn ? "purchase" : "purchase-anonymous")
            if let uid = userIdentifier, let e = t.expirationDate {
                await syncAppleExpiryToServer(userId: uid, expiry: e)
            } else {
                await reportAnonymousSubscription(t, force: true)
            }
            await t.finish()
            showSubscriptionSheet = false
            return true
        case .userCancelled, .pending: return false
        @unknown default: return false
        }
    }

    func handleAppDidBecomeActive() {
        Task {
            await updateSubscriptionStatus()
            if isLoggedIn { await checkServerSubscriptionStatus() }
            else { await reconcileAnonymousEntitlement() }
        }
    }

    func restorePurchases() async throws {
        try await AppStore.sync()
        await updateSubscriptionStatus()
        if isLoggedIn { await checkServerSubscriptionStatus() }
        else { await reconcileAnonymousEntitlement() }
    }

    func updateSubscriptionStatus() async {
        var active = false
        var latest: Date?
        var latestT: StoreKit.Transaction?
        for await r in StoreKit.Transaction.currentEntitlements {
            do {
                let t = try checkVerified(r)
                guard t.productID == subscriptionProductID else { continue }
                if let e = t.expirationDate, e > Date() {
                    active = true
                    if latest == nil || e > latest! { latest = e; latestT = t }
                }
            } catch { }
        }
        hasAppleEntitlement = active
        appleEntitlementExpiry = latest

        if active {
            applyEntitlement(isSubscribed: true,
                             expiry: latest.map { Self.isoString($0) },
                             source: isLoggedIn ? "StoreKit" : "StoreKit-anonymous")
            if let uid = userIdentifier, let e = latest {
                await syncAppleExpiryToServer(userId: uid, expiry: e)
            } else if let t = latestT {
                await reportAnonymousSubscription(t, force: false)
            }
        }
    }

    /// 未登录用户：本地凭证 → 跨 App 免登录订阅 → 缓存宽限 → 降权
    private func reconcileAnonymousEntitlement() async {
        guard !isLoggedIn else { return }
        if hasAppleEntitlement { return }

        if let exp = await fetchCrossAppAnonymousExpiry(), exp > Date() {
            applyEntitlement(isSubscribed: true, expiry: Self.isoString(exp),
                             source: "cross-app-anonymous")
            return
        }
        if isSubscribed {
            applyEntitlement(isSubscribed: false, expiry: nil, source: "anonymous-reconcile")
        }
    }

    /// 跨 App 查询免登录订阅（同一开发者团队 IDFV 一致）
    private func fetchCrossAppAnonymousExpiry() async -> Date? {
        var comps = URLComponents(string: "\(serverBaseURL)/payment/anonymous_status")!
        comps.queryItems = [
            .init(name: "device_id", value: anonymousDeviceId),
            .init(name: "idfv", value: currentIDFV),
            .init(name: "cross_app", value: "1")
        ]
        guard let url = comps.url else { return cachedCrossAppExpiry() }
        do {
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 12
            let (data, _) = try await URLSession.shared.data(for: req)
            struct R: Codable { let is_subscribed: Bool; let expire_at: String? }
            let r = try JSONDecoder().decode(R.self, from: data)
            let d = UserDefaults.standard
            if r.is_subscribed, let exp = Self.parseServerDate(r.expire_at), exp > Date() {
                d.set(Self.isoString(exp), forKey: crossAppExpiryKey)
                d.set(Date(), forKey: crossAppCheckedKey)
                return exp
            }
            d.removeObject(forKey: crossAppExpiryKey)
            d.removeObject(forKey: crossAppCheckedKey)
            return nil
        } catch {
            return cachedCrossAppExpiry()      // 断网时用缓存 + 宽限期
        }
    }

    private func cachedCrossAppExpiry() -> Date? {
        let d = UserDefaults.standard
        guard let s = d.string(forKey: crossAppExpiryKey),
              let exp = Self.parseServerDate(s), exp > Date(),
              let checked = d.object(forKey: crossAppCheckedKey) as? Date,
              Date().timeIntervalSince(checked) < crossAppGrace else { return nil }
        return exp
    }

    func checkVerified<T>(_ r: VerificationResult<T>) throws -> T {
        switch r {
        case .unverified:
            throw NSError(domain: "StoreError", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: Localized.errTransactionUnverified])
        case .verified(let safe): return safe
        }
    }

    // MARK: - Apple 登录回调
    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential else {
            handleSignInError(Localized.errAppleIDCredentialFailed); return
        }
        guard let td = cred.identityToken, let token = String(data: td, encoding: .utf8) else {
            handleSignInError(Localized.errNoIdentityToken); return
        }
        let uid = cred.user
        Task {
            do {
                try await sendTokenToServer(token: token, userId: uid)
                try saveUserIdentifierToKeychain(uid)
                UserDefaults.standard.set(uid, forKey: "current_user_id")
                userIdentifier = uid
                isLoggedIn = true
                isLoggingIn = false
                await updateSubscriptionStatus()
                await checkServerSubscriptionStatus()
                await FreeQuotaManager.shared.refresh(userId: uid)
            } catch {
                handleSignInError("\(Localized.errServerVerifyFailed): \(error.localizedDescription)")
            }
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        if (error as? ASAuthorizationError)?.code == .canceled { handleSignInError(nil) }
        else { handleSignInError(Localized.errLoginFailedRetry) }
    }

    private func handleSignInError(_ m: String?) { isLoggingIn = false; errorMessage = m }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .filter { $0.activationState == .foregroundActive }
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    // MARK: - Server
    private func sendTokenToServer(token: String, userId: String) async throws {
        var r = URLRequest(url: URL(string: "\(serverBaseURL)/auth/apple")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: [
            "identity_token": token, "user_id": userId,
            "device_id": anonymousDeviceId, "client": OVideoClient.id
        ])
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard let h = resp as? HTTPURLResponse, (200...299).contains(h.statusCode) else {
            throw URLError(.badServerResponse)
        }
        struct R: Codable {
            let is_subscribed: Bool
            let subscription_expires_at: String?
            let video_module_blocked: Bool?
        }
        let d = try JSONDecoder().decode(R.self, from: data)
        isVideoModuleBlocked = d.video_module_blocked ?? false
        UserDefaults.standard.set(isVideoModuleBlocked, forKey: cacheVideoBlockedKey)
        if d.is_subscribed {
            applyEntitlement(isSubscribed: true, expiry: d.subscription_expires_at, source: "auth")
        }
    }

    private func syncAppleExpiryToServer(userId: String, expiry: Date) async {
        guard let url = URL(string: "\(serverBaseURL)/payment/subscribe") else { return }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: [
            "user_id": userId, "explicit_expiry": Self.isoString(expiry), "client": OVideoClient.id
        ])
        _ = try? await URLSession.shared.data(for: r)
    }

    private func reportAnonymousSubscription(_ t: StoreKit.Transaction, force: Bool) async {
        if !force {
            let last = UserDefaults.standard.object(forKey: anonReportedAtKey) as? Date ?? .distantPast
            guard Date().timeIntervalSince(last) > 12 * 3600 else { return }
        }
        guard let url = URL(string: "\(serverBaseURL)/payment/anonymous_subscribe"),
              let exp = t.expirationDate else { return }
        var body: [String: Any] = [
            "device_id": anonymousDeviceId,
            "idfv": currentIDFV,
            "client": OVideoClient.id,
            "original_transaction_id": String(t.originalID),
            "transaction_id": String(t.id),
            "product_id": t.productID,
            "expiry": Self.isoString(exp),
            "purchase_date": Self.isoString(t.purchaseDate),
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        ]
        if #available(iOS 16.0, *) { body["environment"] = t.environment.rawValue }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        if let (_, resp) = try? await URLSession.shared.data(for: r),
           (resp as? HTTPURLResponse)?.statusCode == 200 {
            UserDefaults.standard.set(Date(), forKey: anonReportedAtKey)
        }
    }

    func checkServerSubscriptionStatus() async {
        guard let uid = userIdentifier else { return }
        let res = await fetchServerStatus(url: "\(serverBaseURL)/user/status?user_id=\(uid)")
        guard res.reachable else { return }
        if let b = res.videoBlocked {
            isVideoModuleBlocked = b
            UserDefaults.standard.set(b, forKey: cacheVideoBlockedKey)
        }
        if res.isSubscribed {
            applyEntitlement(isSubscribed: true, expiry: res.expiryDate, source: "server")
            return
        }
        if hasAppleEntitlement, let e = appleEntitlementExpiry {
            applyEntitlement(isSubscribed: true, expiry: Self.isoString(e), source: "StoreKit-fix")
            await syncAppleExpiryToServer(userId: uid, expiry: e)
        } else {
            applyEntitlement(isSubscribed: false, expiry: nil, source: "server")
        }
    }

    private func fetchServerStatus(url s: String)
        async -> (reachable: Bool, isSubscribed: Bool, expiryDate: String?, videoBlocked: Bool?) {
        guard let url = URL(string: s) else { return (false, false, nil, nil) }
        do {
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, _) = try await URLSession.shared.data(for: req)
            struct R: Codable {
                let is_subscribed: Bool
                let subscription_expires_at: String?
                let video_module_blocked: Bool?
            }
            let r = try JSONDecoder().decode(R.self, from: data)
            return (true, r.is_subscribed, r.subscription_expires_at, r.video_module_blocked)
        } catch { return (false, false, nil, nil) }
    }

    // MARK: - 状态落地
    private func applyEntitlement(isSubscribed: Bool, expiry: String?, source: String) {
        self.isSubscribed = isSubscribed
        self.subscriptionExpiryDate = isSubscribed ? expiry : nil
        if isSubscribed { saveSubscriptionCache(expiry) } else { clearSubscriptionCache() }
        print("AuthManager: [\(source)] sub=\(isSubscribed) exp=\(expiry ?? "nil")")
    }

    private func saveSubscriptionCache(_ expiry: String?) {
        let d = UserDefaults.standard
        d.set(true, forKey: cacheIsSubscribedKey)
        d.set(Date(), forKey: cacheSavedAtKey)
        if let s = expiry { d.set(s, forKey: cacheExpiryDateKey) }
        else { d.removeObject(forKey: cacheExpiryDateKey) }
    }

    private func loadSubscriptionCache() {
        let d = UserDefaults.standard
        isVideoModuleBlocked = d.bool(forKey: cacheVideoBlockedKey)
        guard d.bool(forKey: cacheIsSubscribedKey) else { return }
        let saved = d.object(forKey: cacheSavedAtKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(saved) < cacheGracePeriod,
              let s = d.string(forKey: cacheExpiryDateKey),
              let dt = Self.parseServerDate(s), dt > Date() else { return }
        isSubscribed = true
        subscriptionExpiryDate = s
    }

    private func clearSubscriptionCache() {
        let d = UserDefaults.standard
        [cacheIsSubscribedKey, cacheExpiryDateKey, cacheSavedAtKey].forEach { d.removeObject(forKey: $0) }
    }

    // MARK: - Keychain
    private func saveUserIdentifierToKeychain(_ id: String) throws {
        guard let data = id.data(using: .utf8) else { throw KeychainError.dataConversionError }
        try? deleteUserIdentifierFromKeychain()
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: userIdentifierKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let s = SecItemAdd(q as CFDictionary, nil)
        guard s == errSecSuccess else {
            throw s == errSecDuplicateItem ? KeychainError.duplicateItem : KeychainError.unknown(s)
        }
    }

    private func loadUserIdentifierFromKeychain() throws -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: userIdentifierKey,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var ref: AnyObject?
        let s = SecItemCopyMatching(q as CFDictionary, &ref)
        if s == errSecSuccess {
            guard let d = ref as? Data else { return nil }
            return String(data: d, encoding: .utf8)
        } else if s == errSecItemNotFound { return nil }
        throw KeychainError.unknown(s)
    }

    private func deleteUserIdentifierFromKeychain() throws {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: userIdentifierKey
        ]
        let s = SecItemDelete(q as CFDictionary)
        if s != errSecSuccess && s != errSecItemNotFound { throw KeychainError.unknown(s) }
    }
}

extension AuthManager {
    func canAccessVideoContent() -> Bool { isSubscribed }
}
