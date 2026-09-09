import SwiftUI

@MainActor
final class NewsPointsCoordinator: ObservableObject {
    static let shared = NewsPointsCoordinator()
    private init() {}

    private let quota = NewsQuotaManager.shared
    weak var authRef: AuthManager?

    // ⭐ 点数来源上下文：新闻 / 视频（邀请拉新分两套，订阅统一）
    enum PointsContext { case news, video }

    // 确认扣点弹窗
    @Published var showConfirmSheet = false
    @Published var confirmTitle = ""
    @Published var confirmRemaining = 0
    @Published var confirmUsingBonus = false
    private var confirmAction: (() -> Void)?

    // 点数不足 / 登录门禁
    @Published var showInsufficientSheet = false
    @Published var insufficientNeedLogin = false
    @Published var insufficientRemaining = 0
    @Published var insufficientContext: PointsContext = .news
    @Published var insufficientIsShortage = true   // true=真不足；false=主动点“+”获取更多点数

    // 结算中 / 错误
    @Published var isProcessing = false
    @Published var showErrorSheet = false
    @Published var errorText = ""

    // ★【需求5】自动扣点后的轻提示（不阻塞、不打断音频）
    @Published var autoDeductToast: String? = nil
    private var toastToken = UUID()

    // 全局 sheet（由 MainAppView 绑定）
    @Published var showInviteSheet = false
    @Published var showVideoInviteSheet = false     // 视频邀请
    @Published var showSubscriptionSheet = false
    // 视频首页首启登录弹窗
    @Published var showVideoLoginPrompt = false

    // ★【需求1】登录中转页已删除。这里保留属性只为兼容旧调用点：
    //   任何地方把它置为 true，都会被自动改写成「直接拉起苹果登录」。
    @Published var showLoginSheet = false {
        didSet {
            guard showLoginSheet else { return }
            showLoginSheet = false                       // 递归安全：置 false 时 guard 直接返回
            let auth = authRef ?? AuthManager.shared
            DispatchQueue.main.async { auth.signInWithApple() }
        }
    }

    // MARK: - 【需求2】唯一的「这天是否受限」判定入口
    static func isRestrictedDay(_ timestamp: String, viewModel: NewsViewModel) -> Bool {
        viewModel.isTimestampLocked(timestamp: timestamp)
    }

    // MARK: - 是否可免费访问一篇新闻
    static func canAccess(_ article: Article, auth: AuthManager, viewModel: NewsViewModel) -> Bool {
        if auth.isSubscribed || auth.isPermanentVIP { return true }
        if !isRestrictedDay(article.timestamp, viewModel: viewModel) { return true }   // 老新闻免费
        return NewsQuotaManager.shared.isNewsUnlocked(FreeQuotaManager.newsKey(article))
    }

    // MARK: - 列表锁标志显示规则
    static func shouldShowLock(timestamp: String, auth: AuthManager, viewModel: NewsViewModel) -> Bool {
        if auth.isSubscribed || auth.isPermanentVIP { return false }
        if !isRestrictedDay(timestamp, viewModel: viewModel) { return false }
        if !auth.isLoggedIn { return false }
        return NewsQuotaManager.shared.remaining <= 0
    }

    // MARK: - 尝试解锁一篇新闻
    /// - Parameters:
    ///   - onBlocked: 只要「弹出了阻塞式弹窗 / 解锁失败」就会回调（用于让调用方停止音频等）
    ///   - onSuccess: 解锁成功（含已解锁）后继续原动作
    func attemptUnlockArticle(_ article: Article,
                              auth: AuthManager,
                              viewModel: NewsViewModel,
                              onBlocked: (() -> Void)? = nil,
                              onSuccess: @escaping () -> Void) {
        self.authRef = auth
        if Self.canAccess(article, auth: auth, viewModel: viewModel) { onSuccess(); return }

        if !auth.isLoggedIn {
            onBlocked?()
            presentInsufficient(needLogin: true, context: .news)
            return
        }
        if quota.remaining <= 0 {
            onBlocked?()
            presentInsufficient(needLogin: false, context: .news)
            return
        }

        // ★★★【需求5】勾了「直接扣除，不再询问」→ 静默扣点，不弹任何窗（音频得以连贯播放）
        if NewsPointsPrefs.autoDeduct {
            performUnlock(article: article, auth: auth, silent: true,
                          onBlocked: onBlocked, onSuccess: onSuccess)
            return
        }

        presentConfirm(title: article.topic) { [weak self] in
            self?.performUnlock(article: article, auth: auth, silent: false,
                               onBlocked: onBlocked, onSuccess: onSuccess)
        }
    }

    /// 真正的扣点动作。silent=true 时不显示「处理中」遮罩，只在成功后给一个轻提示
    private func performUnlock(article: Article,
                               auth: AuthManager,
                               silent: Bool,
                               onBlocked: (() -> Void)?,
                               onSuccess: @escaping () -> Void) {
        if !silent { isProcessing = true }
        Task { [weak self] in
            guard let self = self else { return }
            let uid = FreeQuotaManager.currentUserId(auth: auth)
            let key = FreeQuotaManager.newsKey(article)
            let r = await self.quota.unlockNews(userId: uid, articleKey: key, topic: article.topic)
            if !silent { self.isProcessing = false }

            switch r {
            case .success:
                if silent { self.showAutoDeductToast() }
                onSuccess()
            case .alreadyUnlocked:
                onSuccess()
            case .quotaExceeded:
                onBlocked?()
                self.presentInsufficient(needLogin: false, context: .news)
            case .failed:
                onBlocked?()
                self.presentError(Localized.isEnglish
                                  ? "Network error. Failed to use your point, please try again."
                                  : "网络异常，扣点失败，请稍后再试")
            }
        }
    }

    private func showAutoDeductToast() {
        autoDeductToast = Localized.isEnglish
            ? "1 point used · \(quota.remaining) left"
            : "剩余 \(quota.remaining) 点\n首页'个人中心'可关闭'自动扣点'"
        let token = UUID(); toastToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
            guard let self = self, self.toastToken == token else { return }
            self.autoDeductToast = nil
        }
    }

    // MARK: - 首启登录引导弹窗（已废弃，保留空实现）
    func maybeShowFirstLaunchInvitePrompt(auth: AuthManager,
                                          reviewMode: Bool,
                                          isNewUser: Bool,
                                          isVideoHome: Bool) {
        self.authRef = auth
        UserDefaults.standard.set(true, forKey: "hasShownNewsInvitePrompt")
        return   // 不再弹任何窗
    }

    // MARK: - 低层
    func presentConfirm(title: String, onConfirm: @escaping () -> Void) {
        confirmTitle = title
        confirmRemaining = quota.remaining
        confirmUsingBonus = quota.bonusRemaining > 0
        confirmAction = onConfirm
        showConfirmSheet = true
    }

    func presentInsufficient(needLogin: Bool,
                             context: PointsContext = .news,
                             isShortage: Bool = true) {
        insufficientContext = context
        insufficientNeedLogin = needLogin
        insufficientIsShortage = isShortage
        insufficientRemaining = (context == .video)
            ? FreeQuotaManager.shared.remaining
            : quota.remaining
        showInsufficientSheet = true
    }

    func presentError(_ msg: String) { errorText = msg; showErrorSheet = true }

    func confirmYes() {
        showConfirmSheet = false
        let a = confirmAction; confirmAction = nil
        DispatchQueue.main.async { a?() }
    }
    func confirmNo() { showConfirmSheet = false; confirmAction = nil }

    // ⭐【需求4】订阅：直接拉起苹果订阅（useDirectPurchase = false 时自动回落到旧中转页）
    func goSubscribe() {
        showInsufficientSheet = false
        let auth = authRef ?? AuthManager.shared
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if PurchaseFlowManager.useDirectPurchase {
                PurchaseFlowManager.shared.startPurchase(auth: auth, reason: "news-points-insufficient")
            } else {
                self.showSubscriptionSheet = true
            }
        }
    }

    // 新闻邀请（保留）
    func openInvite() {
        showInsufficientSheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.showInviteSheet = true }
    }

    // ⭐ 邀请拉新：按上下文路由（新闻 / 视频 分两套）
    func openInviteForContext() {
        showInsufficientSheet = false
        let ctx = insufficientContext
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if ctx == .video { self.showVideoInviteSheet = true }
            else { self.showInviteSheet = true }
        }
    }

    // ⭐ 从不足弹窗内直接登录（复用 Apple 登录）
    func doLoginFromInsufficient() {
        showInsufficientSheet = false
        let auth = authRef ?? AuthManager.shared
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { auth.signInWithApple() }
    }

    /// ★【需求1】不再有中转页：等价于直接拉起苹果登录
    func goLogin() {
        showInsufficientSheet = false
        let auth = authRef ?? AuthManager.shared
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { auth.signInWithApple() }
    }
    func dismissInsufficient() { showInsufficientSheet = false }
}

// MARK: - 全局弹窗浮层
struct NewsPointsOverlayView: View {
    @ObservedObject var c = NewsPointsCoordinator.shared
    @AppStorage("isGlobalEnglishMode") private var en = false
    @State private var subShine = false   // ⭐ 订阅按钮呼吸动画

    var body: some View {
        ZStack {
            if c.showConfirmSheet { confirmDialog }
            if c.showInsufficientSheet { insufficientDialog }
            if c.showVideoLoginPrompt { videoLoginDialog }
            if c.showErrorSheet { errorDialog }
            if c.isProcessing { processingOverlay }
            if let toast = c.autoDeductToast { autoDeductToastView(toast) }   // ★需求5
        }
        .animation(.easeInOut(duration: 0.2), value: c.showConfirmSheet)
        .animation(.easeInOut(duration: 0.2), value: c.showInsufficientSheet)
        .animation(.easeInOut(duration: 0.2), value: c.showVideoLoginPrompt)
        .animation(.easeInOut(duration: 0.2), value: c.showErrorSheet)
        .animation(.easeInOut(duration: 0.2), value: c.isProcessing)
        .animation(.easeInOut(duration: 0.25), value: c.autoDeductToast)
    }

    // ★【需求5】静默扣点提示：不遮挡、不拦手势
    private func autoDeductToastView(_ text: String) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "bolt.circle.fill")
                    .font(.system(size: 15)).foregroundColor(.orange)
                Text(text)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
            .padding(.bottom, 120)
        }
        .allowsHitTesting(false)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().scaleEffect(1.3).tint(.white)
                Text(en ? "Processing..." : "处理中...").font(.footnote).foregroundColor(.white)
            }
            .padding(24).background(Color.black.opacity(0.6)).cornerRadius(14)
        }
    }

    private var errorDialog: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { c.showErrorSheet = false }
            VStack(spacing: 0) {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 42))
                    .foregroundStyle(.orange).padding(.top, 24)
                Text(en ? "Failed" : "操作失败").font(.headline).padding(.top, 12)
                Text(c.errorText).font(.subheadline).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 20).padding(.top, 8)
                Divider().padding(.top, 18)
                Button { c.showErrorSheet = false } label: {
                    Text(en ? "OK" : "知道了").fontWeight(.bold).frame(maxWidth: .infinity).padding(.vertical, 14)
                }
            }
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(18).padding(.horizontal, 60).shadow(radius: 20)
            .transition(.scale.combined(with: .opacity))
        }
    }

    // 视频首页登录引导弹窗（首启用，保留）
    private var videoLoginDialog: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button { c.showVideoLoginPrompt = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .padding(.trailing, 16).padding(.top, 16)
                }
                Text(en ? "Sign in to Watch Free" : "登录后免费观看")
                    .font(.headline).padding(.top, 12)
                Text(en ? "Sign in (free, no purchase needed) to get a welcome gift plus free daily passes."
                        : "登录后即可领取新人礼包和每日免费观看点数，登录无需付费。")
                    .font(.subheadline).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 20).padding(.top, 8)
                Button {
                    c.showVideoLoginPrompt = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        (c.authRef ?? AuthManager.shared).signInWithApple()
                    }
                } label: {
                    HStack {
                        Image(systemName: "person.fill.checkmark")
                        Text(en ? "Sign in · Get points" : "现在就登录").fontWeight(.bold)
                    }
                    .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(LinearGradient(colors: [.pink, .orange], startPoint: .leading, endPoint: .trailing))
                    .cornerRadius(12)
                }
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 24)
            }
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(18).padding(.horizontal, 40).shadow(radius: 20)
            .transition(.scale.combined(with: .opacity))
        }
    }

    // MARK: - 扣点确认弹窗（★需求5：加入「直接扣除，不再询问」）
    private var confirmDialog: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { c.confirmNo() }
            VStack(spacing: 0) {
                Image(systemName: "bolt.circle.fill").font(.system(size: 44))
                    .foregroundStyle(.orange).padding(.top, 24)
                Text(en ? "Use 1 Point" : "点数消耗确认")
                    .font(.subheadline).foregroundColor(.secondary).padding(.top, 12)
                Text(en ? "Title: \(c.confirmTitle)" : "标题：\(c.confirmTitle)")
                    .font(.headline)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                HStack(spacing: 4) {
                    Text(en ? "Cost" : "本次将消耗")
                    Text("1").fontWeight(.bold).foregroundColor(.orange)
                    Text(en ? "· Left" : "点 · 剩余")
                    Text("\(c.confirmRemaining)").fontWeight(.bold).foregroundColor(.blue)
                    Text(en ? "" : "点")
                }.font(.footnote).padding(.top, 14)
                Text(c.confirmUsingBonus
                     ? (en ? "Welcome passes used first · free to re-read later" : "解锁后永久免费再读")
                     : (en ? "Free to re-read after unlock" : "解锁后永久免费再读"))
                    .font(.caption2).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 16).padding(.top, 6)

                // ★★★【需求5】勾选后：下次直接扣点、不再弹窗（音频可连贯播放）
                NewsPointsAutoDeductToggle()
                    .padding(.horizontal, 22)
                    .padding(.top, 10)

                Divider().padding(.top, 8)
                HStack(spacing: 0) {
                    Button { c.confirmNo() } label: {
                        Text(en ? "Cancel" : "取消").frame(maxWidth: .infinity).padding(.vertical, 14).foregroundColor(.secondary)
                    }
                    Divider().frame(height: 46)
                    Button { c.confirmYes() } label: {
                        Text(en ? "Confirm" : "确认").fontWeight(.bold).frame(maxWidth: .infinity).padding(.vertical, 14).foregroundColor(.blue)
                    }
                }
            }
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(18).padding(.horizontal, 50).shadow(radius: 20)
            .transition(.scale.combined(with: .opacity))
        }
    }

    // MARK: - 醒目订阅按钮（订阅统一）
    private var subscribeButton: some View {
        Button(action: { c.goSubscribe() }) {
            HStack(spacing: 10) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 20)).foregroundColor(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text(en ? "Go Premium · Unlimited" : "升级 VIP 尊享会员")
                        .font(.system(size: 15, weight: .bold))
                    Text(en ? "No more point limits" : "告别点数烦恼，一步到位")
                        .font(.system(size: 11)).opacity(0.9)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("¥").font(.system(size: 10))
                        Text("24")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.7))
                            .strikethrough(color: .white.opacity(0.7))
                    }
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
        .onAppear {
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) {
                subShine = true
            }
        }
    }

    private var insufficientTitle: String {
        if c.insufficientNeedLogin { return en ? "Sign in to unlock" : "登录后免费阅览" }
        if c.insufficientIsShortage { return en ? "Out of points" : "点数不足" }
        return en ? "Get more points" : "获取更多点数"
    }

    @ViewBuilder
    private var insufficientMessageView: some View {
        if c.insufficientNeedLogin {
            Text(en ? "Sign in (free, no purchase needed) to get a welcome gift plus free daily passes. Invite friends for even more!"
                    : "登录成功即可领取新人礼包和每日免费点数，登录无需付费！")
        } else if c.insufficientIsShortage {
            HStack(spacing: 3) {
                Text(en ? "You need " : "本次需要 ").foregroundColor(.secondary)
                Text("1").foregroundColor(.orange).fontWeight(.bold)
                Text(en ? " point, only " : " 点，当前仅剩 ").foregroundColor(.secondary)
                Text("\(c.insufficientRemaining)").foregroundColor(.blue).fontWeight(.bold)
                Text(en ? " left." : " 点。").foregroundColor(.secondary)
            }
        } else {
            Text(en ? "Invite friends for free points, or subscribe for unlimited access."
                    : "邀请好友得免费点数，或直接付费订阅畅享全部内容")
        }
    }
    
    // MARK: - ⭐ 恢复紧凑自适应的弹窗（无多余空白）
    private var insufficientDialog: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 0) {
                Text(insufficientTitle).font(.headline).padding(.top, 22)
                insufficientMessageView
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20).padding(.top, 8)
                
                // 主推按钮：未登录→登录；已登录→邀请拉新
                Button {
                    if c.insufficientNeedLogin { c.doLoginFromInsufficient() }
                    else { c.openInviteForContext() }
                } label: {
                    HStack {
                        Image(systemName: c.insufficientNeedLogin ? "person.fill.checkmark" : "party.popper.fill")
                        Text(c.insufficientNeedLogin
                            ? (en ? "Sign in · Get points" : "现在就登录")
                            : (en ? "Invite friends · Free points" : "邀请好友 · 免费领点数"))
                            .font(.subheadline).fontWeight(.bold)
                    }
                    .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(LinearGradient(colors: [.pink, .orange], startPoint: .leading, endPoint: .trailing))
                    .cornerRadius(12)
                }
                .padding(.horizontal, 20).padding(.top, 18)
                
                // 次级按钮：未登录展示免登录订阅按钮；已登录展示 VIP 升级按钮
                if c.insufficientNeedLogin {
                    AnonymousSubscribeButton(reason: "news-guest-paywall")
                        .padding(.horizontal, 20).padding(.top, 12)
                } else {
                    subscribeButton
                        .padding(.horizontal, 20).padding(.top, 12)
                }
                
                Divider().padding(.top, 16)
                
                Button { c.dismissInsufficient() } label: {
                    Text(en ? "Maybe later" : "再等等")
                        .frame(maxWidth: .infinity).padding(.vertical, 14).foregroundColor(.secondary)
                }
            }
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(18).padding(.horizontal, 40).shadow(radius: 20)
            .transition(.scale.combined(with: .opacity))
        }
    }
}

// MARK: - Banner 点数胶囊（SourceList / 复用）
struct NewsPointsPill: View {
    @ObservedObject var quota = NewsQuotaManager.shared
    @ObservedObject var coordinator = NewsPointsCoordinator.shared
    @EnvironmentObject var authManager: AuthManager
    @AppStorage("isGlobalEnglishMode") private var en = false

    var body: some View {
        if authManager.isLoggedIn && !authManager.isSubscribed {
            HStack(spacing: 6) {
                Text(en ? "Points \(quota.remaining)" : "点数 \(quota.remaining)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                Button {
                    coordinator.authRef = authManager
                    coordinator.presentInsufficient(needLogin: false, context: .news, isShortage: false)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.orange)
                }
                .buttonStyle(BorderlessButtonStyle())
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Color(.tertiarySystemFill))
                .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5)))
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

enum NewsPointsPrefs {
    static let storageKey = "NewsPoints_AutoDeduct"

    /// 是否已勾选「直接扣除，不再询问」
    static var autoDeduct: Bool {
        get { UserDefaults.standard.bool(forKey: storageKey) }
        set { UserDefaults.standard.set(newValue, forKey: storageKey) }
    }

    static func reset() { UserDefaults.standard.set(false, forKey: storageKey) }
}

// MARK: - 剩余点数别名（对齐 NewsQuotaManager 的真实属性）

extension NewsQuotaManager {
    /// 剩余可用点数（= 赠送点 + 每日点，服务端已合并到 remaining）
    var remainingPointsForAutoDeduct: Int { remaining }
}

// MARK: - 放在「扣点确认弹窗」里的勾选控件

struct NewsPointsAutoDeductToggle: View {
    @AppStorage(NewsPointsPrefs.storageKey) private var autoDeduct = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { autoDeduct.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: autoDeduct ? "checkmark.square.fill" : "square")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(autoDeduct ? .blue : .secondary)
                Text(Localized.isEnglish ? "Deduct automatically, don't ask again"
                                         : "直接扣除，不再询问")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 供音频/自动播放判断「会不会弹窗」（只有真的弹窗才需要打断音频）

extension NewsPointsCoordinator {
    /// 解锁这篇文章是否会弹出任何阻塞式 UI
    func willPromptForUnlock(_ article: Article,
                             auth: AuthManager,
                             viewModel: NewsViewModel) -> Bool {
        if NewsPointsCoordinator.canAccess(article, auth: auth, viewModel: viewModel) { return false }
        if !auth.isLoggedIn { return true }                                   // 未登录 → 登录/订阅门禁
        if !NewsPointsPrefs.autoDeduct { return true }                        // 需要确认弹窗
        return NewsQuotaManager.shared.remainingPointsForAutoDeduct <= 0      // 点数不足 → 邀请/订阅弹窗
    }
}