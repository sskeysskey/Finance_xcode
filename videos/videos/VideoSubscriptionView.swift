import SwiftUI
import StoreKit

// MARK: - 订阅中转页（审核入口 / 个人中心「升级会员」用）
struct SubscriptionView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.dismiss) var dismiss
    @AppStorage("isGlobalEnglishMode") private var en = false

    @State private var isPurchasing = false
    @State private var showError = false
    @State private var errorMessage = ""

    @State private var showRedeemAlert = false
    @State private var inviteCode = ""
    @State private var isRedeeming = false

    @State private var isRestoring = false
    @State private var showRestoreAlert = false
    @State private var restoreMessage = ""

    enum PendingAction { case none, redeem }
    @State private var pendingAction: PendingAction = .none

    var body: some View {
        ZStack {
            Color.viewBackground.ignoresSafeArea()
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Text(Localized.subTitle)
                        .font(.largeTitle.bold())
                        .onTapGesture(count: 5) {          // 内部兑换码入口
                            if authManager.isLoggedIn { showRedeemAlert = true }
                            else { pendingAction = .redeem; authManager.signInWithApple() }
                        }
                    Text(Localized.subDesc)
                        .font(.subheadline).foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 40)

                Button { dismiss() } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(Localized.planFree).font(.headline)
                            Text(authManager.isSubscribed ? Localized.planFreeDetailSubbed
                                                          : Localized.planFreeDetail)
                                .font(.subheadline).foregroundColor(.secondary)
                        }
                        Spacer()
                        if !authManager.isSubscribed {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.gray).font(.title)
                        }
                    }
                    .padding().background(Color.cardBackground).cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(authManager.isSubscribed ? .clear : .gray, lineWidth: 2))
                }
                .buttonStyle(PlainButtonStyle())

                Button { handlePurchase() } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(Localized.planPro).font(.title3.bold())
                            Text(Localized.planProDesc).font(.subheadline).foregroundColor(.secondary)
                            if !authManager.isLoggedIn {
                                Text(en ? "No sign-in needed · Zero data collected"
                                        : "无需登录 · 零信息收集")
                                    .font(.caption2).foregroundColor(.blue)
                            }
                        }
                        Spacer()
                        Localized.pricePerMonthView
                    }
                    .padding().background(Color.cardBackground).cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange, lineWidth: 2))
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                HStack(spacing: 16) {
                    Button { performRestore() } label: {
                        Text(Localized.restorePurchase).font(.footnote)
                            .foregroundColor(.blue).underline()
                    }
                    .disabled(isRestoring || isPurchasing || isRedeeming)
                    Text("|").foregroundColor(.secondary)
                    Link(Localized.privacy,
                         destination: URL(string: "https://sskeysskey.github.io/website/privacy.html")!)
                        .font(.footnote).foregroundColor(.secondary)
                    Text("|").foregroundColor(.secondary)
                    Link(Localized.terms,
                         destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                        .font(.footnote).foregroundColor(.secondary)
                }

                if authManager.isSubscribed {
                    Text(Localized.currentProUser).foregroundColor(.orange)
                } else {
                    Text(Localized.freePlanFootnote)
                        .font(.caption).foregroundColor(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal)
                }

                Button(Localized.close) { dismiss() }
                    .foregroundColor(.secondary).padding(.bottom)
            }
            .padding(.horizontal)

            if isPurchasing || isRedeeming || isRestoring {
                Color.black.opacity(0.6).ignoresSafeArea()
                VStack {
                    ProgressView().scaleEffect(1.5).tint(.white)
                    Text(isRestoring ? Localized.restoring
                         : (isRedeeming ? Localized.verifying : Localized.processingPayment))
                        .foregroundColor(.white).padding(.top)
                }
            }
        }
        .onAppear { NotificationPermissionManager.shared.suppress(true) }
        .onDisappear { NotificationPermissionManager.shared.suppress(false) }
        .alert(Localized.paymentFailed, isPresented: $showError) {
            Button(Localized.confirm, role: .cancel) { }
        } message: { Text(errorMessage) }
        .alert(Localized.internalTestTitle, isPresented: $showRedeemAlert) {
            TextField(Localized.enterInviteCode, text: $inviteCode)
                .textInputAutocapitalization(.characters)
            Button(Localized.cancel, role: .cancel) { pendingAction = .none }
            Button(Localized.redeem) { handleRedeem() }
        } message: { Text(Localized.inviteCodeInstruction) }
        .alert(Localized.restoreResult, isPresented: $showRestoreAlert) {
            Button(Localized.confirm, role: .cancel) { if authManager.isSubscribed { dismiss() } }
        } message: { Text(restoreMessage) }
        .onChange(of: authManager.isLoggedIn) { newValue in
            guard newValue else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if pendingAction == .redeem { showRedeemAlert = true; pendingAction = .none }
                else if authManager.isSubscribed { dismiss() }
            }
        }
    }

    private func handlePurchase() {
        isPurchasing = true
        Task {
            do {
                let ok = try await authManager.purchaseSubscription()
                await MainActor.run {
                    isPurchasing = false
                    if ok { AnonymousSubscribePromptManager.shared.markPurchased(); dismiss() }
                }
            } catch {
                await MainActor.run {
                    isPurchasing = false
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }

    private func performRestore() {
        isRestoring = true
        Task {
            do {
                try await authManager.restorePurchases()
                await MainActor.run {
                    isRestoring = false
                    restoreMessage = authManager.isSubscribed ? Localized.restoreSuccess
                                                              : Localized.restoreNotFound
                    showRestoreAlert = true
                }
            } catch {
                await MainActor.run {
                    isRestoring = false
                    restoreMessage = "\(Localized.restoreFailed): \(error.localizedDescription)"
                    showRestoreAlert = true
                }
            }
        }
    }

    private func handleRedeem() {
        guard !inviteCode.isEmpty else { return }
        guard authManager.isLoggedIn else {
            pendingAction = .redeem; authManager.signInWithApple(); return
        }
        isRedeeming = true
        Task {
            do {
                try await authManager.redeemInviteCode(inviteCode)
                await MainActor.run { isRedeeming = false; inviteCode = ""; dismiss() }
            } catch {
                await MainActor.run {
                    isRedeeming = false; inviteCode = ""
                    errorMessage = error.localizedDescription; showError = true
                }
            }
        }
    }
}

// MARK: - 购买流程管理器
@MainActor
final class PurchaseFlowManager: ObservableObject {
    static let shared = PurchaseFlowManager()

    /// true = 各入口直接拉起苹果订阅面板；false = 回落旧中转页
    static var useDirectPurchase = true

    @Published var isPurchasing = false
    @Published var isRestoring  = false
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var showSuccessToast = false

    private init() {}

    func startPurchase(auth: AuthManager, reason: String = "") {
        guard !isPurchasing else { return }
        guard Self.useDirectPurchase else { auth.presentLegacySubscriptionSheet(); return }
        isPurchasing = true
        Task {
            do {
                let ok = try await auth.purchaseSubscription()
                await MainActor.run {
                    isPurchasing = false
                    if ok {
                        showSuccessToast = true
                        AnonymousSubscribePromptManager.shared.markPurchased()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { self.showSuccessToast = false }
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    isPurchasing = false
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }

    func restore(auth: AuthManager) {
        guard !isRestoring else { return }
        isRestoring = true
        Task {
            do {
                try await auth.restorePurchases()
                await MainActor.run {
                    isRestoring = false
                    if auth.isSubscribed {
                        showSuccessToast = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { self.showSuccessToast = false }
                        }
                    } else {
                        errorMessage = Localized.restoreNotFound
                        showError = true
                    }
                }
            } catch {
                await MainActor.run {
                    isRestoring = false
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }
}

// MARK: - 全局 HUD / 错误 Alert
struct AppFlowOverlay: View {
    @EnvironmentObject var authManager: AuthManager
    @ObservedObject private var flow = PurchaseFlowManager.shared

    var body: some View {
        ZStack {
            if flow.isPurchasing || flow.isRestoring || authManager.isLoggingIn {
                Color.black.opacity(0.45).ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView().scaleEffect(1.4).tint(.white)
                    Text(hudText).font(.subheadline).foregroundColor(.white)
                }
                .padding(28).background(Material.ultraThinMaterial).cornerRadius(18)
            }
            if flow.showSuccessToast {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                        Text(Localized.isEnglish ? "Subscription active" : "订阅已生效").fontWeight(.medium)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.ultraThinMaterial).clipShape(Capsule())
                    .shadow(radius: 8).padding(.bottom, 60)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: flow.isPurchasing)
        .animation(.easeInOut, value: flow.showSuccessToast)
        .alert(Localized.isEnglish ? "Notice" : "提示", isPresented: $flow.showError) {
            Button(Localized.confirm, role: .cancel) { }
        } message: { Text(flow.errorMessage) }
        .alert(Localized.isEnglish ? "Sign In Failed" : "登录失败",
               isPresented: Binding(get: { authManager.errorMessage != nil },
                                    set: { if !$0 { authManager.errorMessage = nil } })) {
            Button(Localized.confirm, role: .cancel) { authManager.errorMessage = nil }
        } message: { Text(authManager.errorMessage ?? "") }
    }

    private var hudText: String {
        if authManager.isLoggingIn { return Localized.isEnglish ? "Signing in…" : "正在登录…" }
        if flow.isRestoring { return Localized.restoring }
        return Localized.processingPayment
    }
}

// MARK: - 免登录订阅引导（触发时机：游客付费墙出现 N 次后，在返回首页时弹）
@MainActor
final class AnonymousSubscribePromptManager: ObservableObject {
    static let shared = AnonymousSubscribePromptManager()

    private let firstThreshold = 2      // 第一次：见过 2 次游客付费墙
    private let repeatEvery    = 4

    private let kCount = "AnonPromo_GuestPaywallCount"
    private let kNoMore = "AnonPromo_DontRemind"
    private let kShown = "AnonPromo_ShownTimes"

    @Published var showSheet = false
    private var pending = false
    var hasPending: Bool { pending && !dontRemind }

    private init() {}

    var dontRemind: Bool {
        get { UserDefaults.standard.bool(forKey: kNoMore) }
        set { UserDefaults.standard.set(newValue, forKey: kNoMore) }
    }

    func resetForTesting() {
        let d = UserDefaults.standard
        [kCount, kNoMore, kShown].forEach { d.removeObject(forKey: $0) }
        pending = false; showSheet = false
    }

    /// 游客撞到付费墙 / 免费看完一集
    func noteGuestPaywall() {
        guard !dontRemind, !AuthManager.shared.isSubscribed, !AuthManager.shared.isLoggedIn else { return }
        let d = UserDefaults.standard
        let n = d.integer(forKey: kCount) + 1
        d.set(n, forKey: kCount)
        let shown = d.integer(forKey: kShown)
        let need = shown == 0 ? firstThreshold : firstThreshold + repeatEvery * shown
        if n >= need { pending = true }
    }

    func flushIfNeeded() {
        guard pending, !dontRemind, !showSheet else { return }
        pending = false
        let d = UserDefaults.standard
        d.set(d.integer(forKey: kShown) + 1, forKey: kShown)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard !self.dontRemind else { return }
            self.showSheet = true
        }
    }

    func markPurchased() { dontRemind = true; showSheet = false; pending = false }
}

// MARK: - 免登录订阅按钮
struct AnonymousSubscribeButton: View {
    @EnvironmentObject var authManager: AuthManager
    @AppStorage("isGlobalEnglishMode") private var en = false
    @ObservedObject private var price = StorePriceStore.shared
    @State private var shine = false
    var reason: String = "paywall"

    var body: some View {
        Button {
            PurchaseFlowManager.shared.startPurchase(auth: authManager, reason: reason)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "crown.fill").font(.system(size: 20)).foregroundColor(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text(en ? "Subscribe without Sign-in" : "免登录订阅")
                        .font(.system(size: 19, weight: .bold))
                    Text(en ? "Zero data collected · Worry-free" : "零信息收集，严格隐私保护")
                        .font(.system(size: 11)).opacity(0.9)
                }
                Spacer()
                Text(price.displayPrice).font(.system(size: 22, weight: .heavy))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(LinearGradient(colors: [Color.indigo, Color.blue, Color.cyan],
                                       startPoint: .leading, endPoint: .trailing))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.35), lineWidth: 1))
            .shadow(color: .blue.opacity(0.45), radius: shine ? 12 : 6, y: 4)
            .scaleEffect(shine ? 1.02 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .onAppear {
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { shine = true }
        }
    }
}

// MARK: - 免登录订阅说明页
struct AnonymousSubscribeView: View {
    @EnvironmentObject var authManager: AuthManager
    @ObservedObject private var promo = AnonymousSubscribePromptManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var dontRemind = false

    private var bullets: [(String, String, String)] {
        Localized.isEnglish ? [
            ("person.fill.xmark", "No sign-in required",
             "No Apple ID, no email, no phone number. We never create an account for you."),
            ("hand.raised.fill", "Zero data collection",
             "Nothing about you is uploaded. Your watch history stays on this device."),
            ("checkmark.shield.fill", "Verified locally by Apple",
             "Your receipt is validated on-device by Apple. Same Apple ID? Just tap Restore Purchases."),
            ("play.rectangle.fill", "Everything unlocked",
             "All movies and series, unlimited streaming and downloads — no points, no waiting.")
        ] : [
            ("person.fill.xmark", "无需登录",
             "不需要 Apple 登录，不填邮箱、不填手机号，我们不会为你创建任何账号。"),
            ("hand.raised.fill", "零信息收集",
             "不上传任何个人信息，观看记录只保存在本机。"),
            ("checkmark.shield.fill", "苹果本地验证，安全可靠",
             "订阅凭证只由 Apple 在设备本地校验；同一 Apple ID 换设备后点「恢复购买」即可。"),
            ("play.rectangle.fill", "全部内容解锁",
             "全部影视内容无限观看、无限缓存，不用点数、不用等。")
        ]
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 12) {
                        Text(Localized.isEnglish ? "Subscribe without signing in" : "无需登录，也能订阅")
                            .font(.system(size: 24, weight: .heavy)).multilineTextAlignment(.center)
                        Text(Localized.isEnglish
                             ? "Maximum privacy. Zero account required."
                             : "为确保用户隐私及安全，特别推出免登录订阅。")
                            .font(.subheadline).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 12)

                    VStack(spacing: 14) {
                        ForEach(bullets, id: \.1) { icon, title, desc in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: icon).font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.blue).frame(width: 26)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(title).font(.system(size: 15, weight: .bold))
                                    Text(desc).font(.system(size: 13)).foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 16)
                        .fill(Color(UIColor.secondarySystemGroupedBackground)))

                    AnonymousSubscribeButton(reason: "anon-promo-sheet").padding(.vertical, 8)

                    Text(Localized.freePlanFootnote)
                        .font(.caption2).foregroundColor(.secondary)

                    HStack(spacing: 14) {
                        Button { PurchaseFlowManager.shared.restore(auth: authManager) } label: {
                            Text(Localized.restorePurchase).font(.caption).underline()
                        }
                        Link(Localized.privacy,
                             destination: URL(string: "https://sskeysskey.github.io/website/privacy.html")!)
                            .font(.caption)
                        Link(Localized.terms,
                             destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)

                    Toggle(isOn: $dontRemind) {
                        Text(Localized.isEnglish ? "Don't remind me again" : "以后不再提醒").font(.subheadline)
                    }
                    .tint(.blue).padding(.horizontal, 4)
                }
                .padding(20)
            }
            .background(Color.viewBackground.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Localized.close) { promo.dontRemind = dontRemind; dismiss() }
                }
            }
            .onAppear { dontRemind = promo.dontRemind }
            .onChange(of: dontRemind) { promo.dontRemind = $0 }
            .onChange(of: authManager.isSubscribed) { if $0 { dismiss() } }
        }
        .onDisappear { promo.dontRemind = dontRemind }
    }
}
