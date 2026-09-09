import SwiftUI
import StoreKit

struct SubscriptionView: View {

    @EnvironmentObject var authManager: AuthManager
    @Environment(\.dismiss) var dismiss
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    @State private var isPurchasing = false
    @State private var showError = false
    @State private var errorMessage = ""

    @State private var showRedeemAlert = false
    @State private var inviteCode = ""
    @State private var isRedeeming = false

    @State private var isRestoring = false
    @State private var showRestoreAlert = false
    @State private var restoreMessage = ""

    /// 登录成功后要继续做的事（现在只剩"兑换码"需要登录）
    enum PendingAction { case none, redeem }
    @State private var pendingAction: PendingAction = .none

    var body: some View {
        ZStack {
            Color.viewBackground.ignoresSafeArea()

            VStack(spacing: 25) {
                VStack(spacing: 10) {
                    Text(Localized.subTitle)
                        .font(.largeTitle.bold())
                        .foregroundColor(.primary)
                        // 连按 5 次 = 内部兑换码（★需求1：直接拉起苹果登录，无中转页）
                        .onTapGesture(count: 5) {
                            if authManager.isLoggedIn {
                                showRedeemAlert = true
                            } else {
                                pendingAction = .redeem
                                authManager.signInWithApple()
                                AnonymousSubscribePromptManager.shared.resetForTesting()
                            }
                        }

                    Text(Localized.subDesc)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 40)

                // 免费套餐
                Button(action: { dismiss() }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(Localized.planFree).foregroundColor(.primary).font(.headline)
                            Text(authManager.isSubscribed ? Localized.planFreeDetailSubbed : Localized.planFreeDetail)
                                .font(.subheadline).foregroundColor(.secondary)
                        }
                        Spacer()
                        if !authManager.isSubscribed {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.gray).font(.title)
                        }
                    }
                    .padding()
                    .background(Color.cardBackground)
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(authManager.isSubscribed ? Color.clear : Color.gray, lineWidth: 2))
                    .shadow(color: Color.black.opacity(0.05), radius: 5)
                }
                .buttonStyle(PlainButtonStyle())
                
                // 付费套餐
                Button(action: { handlePurchase() }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(Localized.planPro).font(.title2.bold()).foregroundColor(.primary)
                            Text(Localized.planProDesc).font(.subheadline).foregroundColor(.secondary)
                            if !authManager.isLoggedIn {
                                Text(isGlobalEnglishMode
                                     ? "No sign-in needed · Zero data collected"
                                     : "无需登录 · 零信息收集")
                                    .font(.caption2).foregroundColor(.blue)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing) { Localized.pricePerMonthView }
                    }
                    .padding()
                    .background(Color.cardBackground)
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange, lineWidth: 2))
                    .shadow(color: Color.black.opacity(0.05), radius: 5)
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                HStack(spacing: 20) {
                    Button(action: { performRestore() }) {
                        Text(Localized.restorePurchase)
                            .font(.footnote).foregroundColor(.blue).underline()
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

                Spacer()

                if authManager.isSubscribed {
                    Text(Localized.currentProUser).foregroundColor(.orange).padding()
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
        .onAppear  { NotificationPermissionManager.shared.suppress(true) }
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
        // ★需求1：登录成功后继续挂起的兑换动作（不再有 LoginView）
        .onChange(of: authManager.isLoggedIn) { newValue in
            guard newValue else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                switch pendingAction {
                case .redeem: showRedeemAlert = true
                case .none:   if authManager.isSubscribed { dismiss() }
                }
                if pendingAction != .redeem { pendingAction = .none }
            }
        }
    }

    // ★【需求3】购买不再检查登录
    private func handlePurchase() {
        isPurchasing = true
        Task {
            do {
                let isSuccess = try await authManager.purchaseSubscription()
                await MainActor.run {
                    isPurchasing = false
                    if isSuccess {
                        AnonymousSubscribePromptManager.shared.markPurchased()
                        dismiss()
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

    // 恢复购买同样不需要登录（纯 StoreKit）
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
            pendingAction = .redeem
            authManager.signInWithApple()
            return
        }
        isRedeeming = true
        Task {
            do {
                try await authManager.redeemInviteCode(inviteCode)
                await MainActor.run {
                    isRedeeming = false; pendingAction = .none; inviteCode = ""; dismiss()
                }
            } catch {
                await MainActor.run {
                    isRedeeming = false; pendingAction = .none; inviteCode = ""
                    errorMessage = error.localizedDescription; showError = true
                }
            }
        }
    }
}

@MainActor
final class PurchaseFlowManager: ObservableObject {

    static let shared = PurchaseFlowManager()

    /// ★★★【需求4】开关：
    /// true  = 所有"点数用尽/需要订阅"入口 → 直接拉起苹果订阅面板
    /// false = 回退到旧的 SubscriptionView 中转页（代码完整保留，随时可切回）
    static var useDirectPurchase = true

    @Published var isPurchasing = false
    @Published var isRestoring  = false

    @Published var showError = false
    @Published var errorMessage = ""

    @Published var showSuccessToast = false

    private init() {}

    // MARK: - 购买（登录 / 未登录通吃）

    func startPurchase(auth: AuthManager, reason: String = "") {
        guard !isPurchasing else { return }
        guard Self.useDirectPurchase else {
            // 回退：走旧中转页
            auth.presentLegacySubscriptionSheet()
            return
        }

        print("💳 [PurchaseFlow] 直接拉起订阅 (reason=\(reason), loggedIn=\(auth.isLoggedIn))")
        isPurchasing = true
        Task {
            do {
                let ok = try await auth.purchaseSubscription()
                await MainActor.run {
                    self.isPurchasing = false
                    if ok {
                        self.showSuccessToast = true
                        // 买成功了就别再骚扰用户
                        AnonymousSubscribePromptManager.shared.markPurchased()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { self.showSuccessToast = false }
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.isPurchasing = false
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
        }
    }

    // MARK: - 恢复购买（未登录也能用，纯 StoreKit）

    func restore(auth: AuthManager) {
        guard !isRestoring else { return }
        isRestoring = true
        Task {
            do {
                try await auth.restorePurchases()
                await MainActor.run {
                    self.isRestoring = false
                    if auth.isSubscribed {
                        self.showSuccessToast = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { self.showSuccessToast = false }
                        }
                    } else {
                        self.errorMessage = Localized.isEnglish
                            ? "No active subscription found for this Apple ID."
                            : "未找到该 Apple ID 下的有效订阅。"
                        self.showError = true
                    }
                }
            } catch {
                await MainActor.run {
                    self.isRestoring = false
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
        }
    }
}

// MARK: - 全局 HUD / Alert 宿主（登录中、购买中、恢复中都在这里）
struct AppFlowOverlay: View {
    @EnvironmentObject var authManager: AuthManager
    @ObservedObject private var flow = PurchaseFlowManager.shared

    var body: some View {
        ZStack {
            if flow.isPurchasing || flow.isRestoring || authManager.isLoggingIn {
                Color.black.opacity(0.45).ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView().scaleEffect(1.4).tint(.white)
                    Text(hudText)
                        .font(.subheadline)
                        .foregroundColor(.white)
                }
                .padding(28)
                .background(Material.ultraThinMaterial)
                .cornerRadius(18)
            }

            if flow.showSuccessToast {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                        Text(Localized.isEnglish ? "Subscription active" : "订阅已生效")
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .shadow(radius: 8)
                    .padding(.bottom, 60)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: flow.isPurchasing)
        .animation(.easeInOut, value: flow.showSuccessToast)
        .alert(Localized.isEnglish ? "Notice" : "提示", isPresented: $flow.showError) {
            Button(Localized.confirm, role: .cancel) { }
        } message: {
            Text(flow.errorMessage)
        }
        // 登录失败提示（原来在 LoginView 里，中转页删了之后挪到这里）
        .alert(Localized.isEnglish ? "Sign In Failed" : "登录失败",
               isPresented: Binding(
                   get: { authManager.errorMessage != nil },
                   set: { if !$0 { authManager.errorMessage = nil } })) {
            Button(Localized.confirm, role: .cancel) { authManager.errorMessage = nil }
        } message: {
            Text(authManager.errorMessage ?? "")
        }
    }

    private var hudText: String {
        if authManager.isLoggingIn { return Localized.isEnglish ? "Signing in…" : "正在登录…" }
        if flow.isRestoring { return Localized.restoring }
        return Localized.processingPayment
    }
}

@MainActor
final class AnonymousSubscribePromptManager: ObservableObject {

    static let shared = AnonymousSubscribePromptManager()

    /// 第一次提醒所需的免费新闻阅读数
    private let firstThreshold = 5
    /// 之后每隔多少篇再提醒一次
    private let repeatEvery = 8

    private let kCount   = "AnonPromo_FreeReadCount"
    private let kNoMore  = "AnonPromo_DontRemind"
    private let kShown   = "AnonPromo_ShownTimes"

    @Published var showSheet = false
    private var pending = false
    /// ★【补丁】外部判断是否有待弹窗，用来给通知预弹窗让路
    var hasPending: Bool { pending && !dontRemind }

    private init() {}

    var dontRemind: Bool {
        get { UserDefaults.standard.bool(forKey: kNoMore) }
        set { UserDefaults.standard.set(newValue, forKey: kNoMore) }
    }

    // MARK: - 🛠️ 测试重置方法
    func resetForTesting() {
        let d = UserDefaults.standard
        d.removeObject(forKey: kCount)
        d.removeObject(forKey: kNoMore)
        d.removeObject(forKey: kShown)
        
        self.pending = false
        self.showSheet = false
        print("🔄 [Debug] 免登录弹窗计数与状态已完全重置！")
    }

    /// 用户读完了一篇"免费旧新闻"（仅未登录 & 未订阅时调用）
    func noteFreeArticleRead() {
        guard !dontRemind else { return }
        let d = UserDefaults.standard
        let n = d.integer(forKey: kCount) + 1
        d.set(n, forKey: kCount)

        let shown = d.integer(forKey: kShown)
        let need = shown == 0 ? firstThreshold : firstThreshold + repeatEvery * shown
        if n >= need { pending = true }
    }

    /// 在"离开详情页"这种安全时机真正弹出，避免打断阅读
    func flushIfNeeded() {
        guard pending, !dontRemind, !showSheet else { return }
        pending = false
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: kShown) + 1, forKey: kShown)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard !self.dontRemind else { return }
            self.showSheet = true
        }
    }

    /// 已经付费了，永久闭嘴
    func markPurchased() {
        dontRemind = true
        showSheet = false
        pending = false
    }
}

// MARK: - ⭐ 统一质感的「免登录订阅」按钮（与 VIP 按钮 1:1 一致）
struct AnonymousSubscribeButton: View {
    @EnvironmentObject var authManager: AuthManager
    @AppStorage("isGlobalEnglishMode") private var en = false
    @State private var subShine = false
    var reason: String = "paywall"

    var body: some View {
        Button {
            PurchaseFlowManager.shared.startPurchase(auth: authManager, reason: reason)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 20)).foregroundColor(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text(en ? "Subscribe without Sign-in" : "免登录订阅")
                        .font(.system(size: 20, weight: .bold))
                    Text(en ? "Zero data collected · Worry-free" : "零信息收集，严格隐私保护")
                        .font(.system(size: 11)).opacity(0.9)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    // 原价划线
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("¥").font(.system(size: 10))
                        Text("24")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.7))
                            .strikethrough(color: .white.opacity(0.7))
                    }
                    // 现价
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("¥").font(.system(size: 13, weight: .bold))
                        Text("12").font(.system(size: 24, weight: .heavy))
                    }
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(colors: [Color.indigo, Color.blue, Color.cyan],
                               startPoint: .leading, endPoint: .trailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.35), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                Text(en ? "BEST" : "超值")
                    .font(.system(size: 10, weight: .heavy)).foregroundColor(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(LinearGradient(colors: [.pink, .red], startPoint: .leading, endPoint: .trailing))
                    .clipShape(Capsule())
                    .offset(x: 6, y: -8)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            }
            .shadow(color: .blue.opacity(0.45), radius: subShine ? 12 : 6, x: 0, y: 4)
            .scaleEffect(subShine ? 1.02 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .onAppear {
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) {
                subShine = true
            }
        }
    }
}

// MARK: - 免登录订阅引导页（需求 3b）
struct AnonymousSubscribeView: View {
    @EnvironmentObject var authManager: AuthManager
    @ObservedObject private var promo = AnonymousSubscribePromptManager.shared
    @ObservedObject private var flow = PurchaseFlowManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var dontRemind = false

    private let bullets: [(String, String, String)] = Localized.isEnglish ? [
        ("person.fill.xmark", "No sign-in required",
         "No Apple ID, no email, no phone number. We never create an account for you."),
        ("hand.raised.fill", "Zero data collection",
         "Nothing about you is uploaded. Your reading history stays on this device."),
        ("checkmark.shield.fill", "Verified locally by Apple",
         "Your receipt is validated on-device by Apple. Same Apple ID? Just tap Restore Purchases."),
        ("newspaper.fill", "Everything unlocked",
         "All of today's news and the full archive — no points, no waiting.")
    ] : [
        ("person.fill.xmark", "无需登录",
         "不需要 Apple 登录，不填邮箱、不填手机号，我们不会为你创建任何账号。"),
        ("hand.raised.fill", "零信息收集",
         "不上传任何个人信息，不保留您的阅读记录。"),
        ("checkmark.shield.fill", "苹果本地验证，安全可靠",
         "订阅凭证只由 Apple 在设备本地校验；唯一的遗憾将是换新手机后无法「恢复购买」。"),
        ("newspaper.fill", "全部内容解锁",
         "当日新闻 + 全部历史新闻随便看，不用点数、不用等 3 天。")
    ]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 22) {

                    VStack(spacing: 12) {
                        Text(Localized.isEnglish ? "Subscribe without signing in" : "无需登录，也能订阅")
                            .font(.system(size: 24, weight: .heavy))
                            .multilineTextAlignment(.center)
                        Text(Localized.isEnglish
                             ? "You're reading the free archive. Want today's news too?"
                             : "为确保用户隐私及安全，隆重推出免登陆订阅功能。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 12)

                    VStack(spacing: 14) {
                        ForEach(bullets, id: \.1) { icon, title, desc in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: icon)
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.blue)
                                    .frame(width: 26)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(title).font(.system(size: 15, weight: .bold))
                                    Text(desc)
                                        .font(.system(size: 13))
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(UIColor.secondarySystemGroupedBackground))
                    )

                    // HStack(spacing: 14) {
                    //     Button {
                    //         PurchaseFlowManager.shared.restore(auth: authManager)
                    //     } label: {
                    //         Text(Localized.restorePurchase)
                    //             .font(.footnote).underline().foregroundColor(.blue)
                    //     }
                    //     Link(Localized.privacy,
                    //          destination: URL(string: "https://sskeysskey.github.io/website/privacy.html")!)
                    //     Text("|").foregroundColor(.secondary)
                    //     Link(Localized.terms,
                    //          destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                    // }
                    // .font(.caption)
                    // .foregroundColor(.secondary)

                    // 价格披露（审核必需：名称 / 周期 / 价格 / 自动续订说明）
                    // VStack(spacing: 8) {
                    //     HStack {
                    //         VStack(alignment: .leading, spacing: 3) {
                    //             Text(Localized.planPro).font(.headline)
                    //             Text(Localized.planProDesc)
                    //                 .font(.caption).foregroundColor(.secondary)
                    //         }
                    //         Spacer()
                    //         Localized.pricePerMonthView
                    //     }
                    //     Text(Localized.freePlanFootnote)
                    //         .font(.caption2)
                    //         .foregroundColor(.secondary)
                    //         .multilineTextAlignment(.leading)
                    //         .frame(maxWidth: .infinity, alignment: .leading)
                    // }
                    // .padding(14)
                    // .background(
                    //     RoundedRectangle(cornerRadius: 14)
                    //         .stroke(Color.orange, lineWidth: 1.5)
                    // )

                    AnonymousSubscribeButton(reason: "anon-promo-sheet")
                    .padding(26)
                    Toggle(isOn: $dontRemind) {
                        Text(Localized.isEnglish ? "Don't remind me again" : "以后不再提醒")
                            .font(.subheadline)
                    }
                    .tint(.blue)
                    .padding(.horizontal, 4)
                }
                .padding(20)
            }
            .background(Color.viewBackground.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Localized.close) { commitAndClose() }
                }
            }

            .onAppear { dontRemind = promo.dontRemind }
            .onChange(of: dontRemind) { promo.dontRemind = $0 }
            .onChange(of: authManager.isSubscribed) { if $0 { commitAndClose() } }
        }
        .interactiveDismissDisabled(false)
        .onDisappear { promo.dontRemind = dontRemind }
    }

    private func commitAndClose() {
        promo.dontRemind = dontRemind
        dismiss()
    }
}