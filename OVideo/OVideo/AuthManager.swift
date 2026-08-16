import SwiftUI
import AppKit
import AuthenticationServices
import Security
import StoreKit
import Combine

/// 线程安全地保存登录时的窗口，供 nonisolated 的 presentationAnchor 使用
/// （避免使用 macOS 14 才有的 MainActor.assumeIsolated）
final class WindowAnchorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var window: NSWindow?
    func set(_ w: NSWindow?) { lock.lock(); window = w; lock.unlock() }
    func get() -> NSWindow? { lock.lock(); defer { lock.unlock() }; return window }
}

@MainActor
final class AuthManager: NSObject, ObservableObject,
    ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {

    static let shared = AuthManager()

    @Published var isLoggedIn = false
    @Published var isLoggingIn = false
    @Published var isSubscribed = false
    @Published var subscriptionExpiryDate: String?
    @Published var isVideoModuleBlocked = false
    @Published var errorMessage: String?
    @Published var showSubscriptionSheet = false

    private(set) var userIdentifier: String?

    private let keychainAccount = "com.zhangyan.gwvideo.appleUser"
    private let productID = "com.zhangyan.gwvideo.subscription.monthly"
    private let serverBase = "http://106.15.183.158:5001/api/ONews"
    private let cacheSubKey = "GW_CacheIsSubscribed"
    private let cacheExpKey = "GW_CacheExpiry"
    private let cacheBlkKey = "GW_CacheVideoBlocked"

    private let anchorBox = WindowAnchorBox()
    private var listener: Task<Void, Never>?

    var isPermanentVIP: Bool {
        guard isSubscribed, let d = subscriptionExpiryDate else { return false }
        return d.hasPrefix("2099")
    }
    var trackIdentity: (id: String, type: String) {
        if let u = userIdentifier, !u.isEmpty { return (u, "apple") }
        return (DeviceIdentity.deviceId, "device")
    }

    override init() {
        super.init()
        restoreFromKeychain()
        listener = Task.detached { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard let self else { return }
                if let t = try? await self.verify(result) {
                    await self.updateSubscriptionStatus()
                    await t.finish()
                }
            }
        }
    }
    // 单例，不写 deinit（@MainActor 类的 deinit 不能访问隔离属性）

    // MARK: 状态
    private func restoreFromKeychain() {
        guard let uid = try? loadKeychain() else { isSubscribed = false; return }
        userIdentifier = uid
        isLoggedIn = true
        UserDefaults.standard.set(uid, forKey: "current_user_id")
        loadCache()
        Task {
            await updateSubscriptionStatus()
            await checkServerStatus()
        }
    }

    func handleBecomeActive() {
        Task { await updateSubscriptionStatus(); await checkServerStatus() }
    }

    // MARK: Sign in with Apple (macOS)
    func signInWithApple() {
        guard !isLoggingIn else { return }
        anchorBox.set(NSApp.keyWindow ?? NSApp.windows.first)
        isLoggingIn = true; errorMessage = nil
        let req = ASAuthorizationAppleIDProvider().createRequest()
        req.requestedScopes = [.fullName, .email]
        let c = ASAuthorizationController(authorizationRequests: [req])
        c.delegate = self
        c.presentationContextProvider = self
        c.performRequests()
    }

    /// 供 SignInWithAppleButton 的 onCompletion 直接调用，避免双重发起
    func handleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            isLoggingIn = true; errorMessage = nil
            process(authorization)
        case .failure(let err):
            let canceled = (err as? ASAuthorizationError)?.code == .canceled
            fail(canceled ? nil : T("登录失败，请重试", "Sign-in failed, please retry"))
        }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        anchorBox.get() ?? NSWindow()
    }

    nonisolated func authorizationController(controller: ASAuthorizationController,
                                             didCompleteWithAuthorization authorization: ASAuthorization) {
        Task { @MainActor in self.process(authorization) }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController,
                                             didCompleteWithError error: Error) {
        let canceled = (error as? ASAuthorizationError)?.code == .canceled
        Task { @MainActor in self.fail(canceled ? nil : T("登录失败，请重试", "Sign-in failed, please retry")) }
    }

    private func process(_ authorization: ASAuthorization) {
        guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = cred.identityToken,
              let token = String(data: tokenData, encoding: .utf8) else {
            fail(T("无法获取身份令牌", "Failed to get identity token"))
            return
        }
        let uid = cred.user
        Task { @MainActor in
            do {
                try await self.sendTokenToServer(token: token, userId: uid)
                try self.saveKeychain(uid)
                UserDefaults.standard.set(uid, forKey: "current_user_id")
                self.userIdentifier = uid
                self.isLoggedIn = true
                self.isLoggingIn = false
                await self.updateSubscriptionStatus()
                await self.checkServerStatus()
            } catch {
                self.fail(T("服务器验证失败：", "Server verification failed: ") + error.localizedDescription)
            }
        }
    }

    private func fail(_ msg: String?) { isLoggingIn = false; errorMessage = msg }

    func signOut() {
        try? deleteKeychain()
        userIdentifier = nil; isLoggedIn = false; isSubscribed = false
        subscriptionExpiryDate = nil; isVideoModuleBlocked = false
        clearCache()
        UserDefaults.standard.removeObject(forKey: "current_user_id")
    }

    func deleteAccount() async throws {
        guard let uid = userIdentifier else { throw URLError(.userAuthenticationRequired) }
        var r = URLRequest(url: URL(string: "\(serverBase)/user/delete")!)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(["user_id": uid])
        let (_, resp) = try await URLSession.shared.data(for: r)
        guard let h = resp as? HTTPURLResponse, h.statusCode == 200 else { throw URLError(.badServerResponse) }
        signOut()
    }

    func redeemInviteCode(_ code: String) async throws {
        guard let uid = userIdentifier else { throw URLError(.userAuthenticationRequired) }
        var r = URLRequest(url: URL(string: "\(serverBase)/user/redeem")!)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(["user_id": uid, "invite_code": code])
        let (d, resp) = try await URLSession.shared.data(for: r)
        guard let h = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if h.statusCode != 200 {
            if let e = try? JSONDecoder().decode([String: String].self, from: d), let m = e["error"] {
                throw NSError(domain: "GW", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: m])
            }
            throw URLError(.badServerResponse)
        }
        struct R: Codable { let is_subscribed: Bool; let subscription_expires_at: String? }
        let rr = try JSONDecoder().decode(R.self, from: d)
        isSubscribed = rr.is_subscribed
        subscriptionExpiryDate = rr.subscription_expires_at
        saveCache(rr.is_subscribed, rr.subscription_expires_at)
    }

    // MARK: StoreKit 2
    func purchase() async throws -> Bool {
        guard let uid = userIdentifier else { throw URLError(.userAuthenticationRequired) }
        let products = try await Product.products(for: [productID])
        guard let p = products.first else {
            throw NSError(domain: "GW", code: 404, userInfo: [NSLocalizedDescriptionKey:
                T("未找到商品，请稍后再试", "Product not found")])
        }
        switch try await p.purchase() {
        case .success(let v):
            let t = try verify(v)
            await updateSubscriptionStatus()
            try? await syncPurchase(uid)
            await t.finish()
            showSubscriptionSheet = false
            return true
        default: return false
        }
    }

    func restorePurchases() async throws {
        try await AppStore.sync()
        await updateSubscriptionStatus()
        if let uid = userIdentifier, isSubscribed { try? await syncPurchase(uid) }
    }

    func updateSubscriptionStatus() async {
        var active = false; var latest: Date?
        for await result in StoreKit.Transaction.currentEntitlements {
            guard let t = try? verify(result), t.productID == productID,
                  let exp = t.expirationDate, exp > Date() else { continue }
            active = true; latest = exp
        }
        if active {
            isSubscribed = true
            subscriptionExpiryDate = latest?.ISO8601Format()
            saveCache(true, subscriptionExpiryDate)
            if let uid = userIdentifier { Task { try? await syncPurchase(uid) } }
        }
    }

    /// 泛型用 V：叫 T 会遮蔽全局本地化函数 T(_:_:)
    private func verify<V>(_ r: VerificationResult<V>) throws -> V {
        switch r {
        case .verified(let s): return s
        case .unverified: throw NSError(domain: "GW", code: 401,
            userInfo: [NSLocalizedDescriptionKey: T("交易验证失败", "Transaction unverified")])
        }
    }

    // MARK: Server
    private func sendTokenToServer(token: String, userId: String) async throws {
        var r = URLRequest(url: URL(string: "\(serverBase)/auth/apple")!)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: [
            "identity_token": token, "user_id": userId, "device_id": DeviceIdentity.deviceId])
        let (d, resp) = try await URLSession.shared.data(for: r)
        guard let h = resp as? HTTPURLResponse, (200...299).contains(h.statusCode) else {
            throw URLError(.badServerResponse)
        }
        struct R: Codable { let is_subscribed: Bool; let subscription_expires_at: String?
                            let video_module_blocked: Bool? }
        let rr = try JSONDecoder().decode(R.self, from: d)
        isSubscribed = rr.is_subscribed
        subscriptionExpiryDate = rr.subscription_expires_at
        isVideoModuleBlocked = rr.video_module_blocked ?? false
        saveCache(rr.is_subscribed, rr.subscription_expires_at)
        UserDefaults.standard.set(isVideoModuleBlocked, forKey: cacheBlkKey)
    }

    private func syncPurchase(_ uid: String) async throws {
        var body: [String: Any] = ["user_id": uid]
        if let e = subscriptionExpiryDate { body["explicit_expiry"] = e } else { body["days"] = 30 }
        var r = URLRequest(url: URL(string: "\(serverBase)/payment/subscribe")!)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: r)
    }

    func checkServerStatus() async {
        guard let uid = userIdentifier,
              let enc = uid.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let u = URL(string: "\(serverBase)/user/status?user_id=\(enc)") else { return }
        struct R: Codable { let is_subscribed: Bool; let subscription_expires_at: String?
                            let video_module_blocked: Bool? }
        guard let (d, _) = try? await URLSession.shared.data(from: u),
              let r = try? JSONDecoder().decode(R.self, from: d) else { return }
        if let b = r.video_module_blocked {
            isVideoModuleBlocked = b
            UserDefaults.standard.set(b, forKey: cacheBlkKey)
        }
        if r.is_subscribed {
            isSubscribed = true
            subscriptionExpiryDate = r.subscription_expires_at
            saveCache(true, r.subscription_expires_at)
        } else if !localAppleEntitlementValid() {
            isSubscribed = false; subscriptionExpiryDate = nil; clearCache()
        } else {
            Task { try? await syncPurchase(uid) }
        }
    }

    private func localAppleEntitlementValid() -> Bool {
        guard isSubscribed, let s = subscriptionExpiryDate else { return false }
        if s.hasPrefix("2099") { return true }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d > Date() }
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime]
        if let d = f1.date(from: s) { return d > Date() }
        let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        if let d = f2.date(from: s) { return d >= Calendar.current.startOfDay(for: Date()) }
        return false
    }

    // MARK: Cache
    private func saveCache(_ sub: Bool, _ exp: String?) {
        let d = UserDefaults.standard
        d.set(sub, forKey: cacheSubKey)
        if let e = exp { d.set(e, forKey: cacheExpKey) } else { d.removeObject(forKey: cacheExpKey) }
    }
    private func loadCache() {
        let d = UserDefaults.standard
        isVideoModuleBlocked = d.bool(forKey: cacheBlkKey)
        guard d.bool(forKey: cacheSubKey), let s = d.string(forKey: cacheExpKey) else { return }
        isSubscribed = true; subscriptionExpiryDate = s
        if !localAppleEntitlementValid() { isSubscribed = false; subscriptionExpiryDate = nil }
    }
    private func clearCache() {
        let d = UserDefaults.standard
        [cacheSubKey, cacheExpKey, cacheBlkKey].forEach { d.removeObject(forKey: $0) }
    }

    // MARK: Keychain（macOS 必须用 data protection keychain）
    private func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrAccount as String: keychainAccount,
         kSecAttrService as String: "GWVideo",
         kSecUseDataProtectionKeychain as String: true]
    }
    private func saveKeychain(_ v: String) throws {
        try? deleteKeychain()
        var q = baseQuery()
        q[kSecValueData as String] = Data(v.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let st = SecItemAdd(q as CFDictionary, nil)
        guard st == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) }
    }
    private func loadKeychain() throws -> String? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecSuccess, let d = out as? Data { return String(data: d, encoding: .utf8) }
        if st == errSecItemNotFound { return nil }
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(st))
    }
    private func deleteKeychain() throws {
        let st = SecItemDelete(baseQuery() as CFDictionary)
        if st != errSecSuccess && st != errSecItemNotFound {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(st))
        }
    }
}