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
    // ⭐ 新增：区分上下文 + 是否“真的点数不足”
    @Published var insufficientContext: PointsContext = .news
    @Published var insufficientIsShortage = true   // true=真不足(显示需要1点)；false=主动点“+”获取更多点数

    // 结算中 / 错误
    @Published var isProcessing = false
    @Published var showErrorSheet = false
    @Published var errorText = ""

    // 全局 sheet（由 MainAppView 绑定）
    @Published var showInviteSheet = false
    @Published var showVideoInviteSheet = false     // 视频邀请
    @Published var showLoginSheet = false
    @Published var showSubscriptionSheet = false
    // 视频首页首启登录弹窗
    @Published var showVideoLoginPrompt = false

    // MARK: - 是否可免费访问一篇新闻
    static func canAccess(_ article: Article, auth: AuthManager, viewModel: NewsViewModel) -> Bool {
        if auth.isSubscribed { return true }
        if !viewModel.isTimestampLocked(timestamp: article.timestamp) { return true } // 老新闻免费
        return NewsQuotaManager.shared.isNewsUnlocked(FreeQuotaManager.newsKey(article))
    }

    // MARK: - 列表锁标志显示规则
    /// 是否在列表/头部显示"锁"图标与"需要订阅"文字。
    /// 规则：
    ///  - 已订阅 → 不显示
    ///  - 免费(老)新闻 → 不显示
    ///  - 未登录 → 不显示
    ///  - 已登录且剩余点数 > 0 → 不显示
    ///  - 仅当"已登录 且 剩余点数为 0"时才显示
    static func shouldShowLock(timestamp: String, auth: AuthManager, viewModel: NewsViewModel) -> Bool {
        if auth.isSubscribed { return false }
        if !viewModel.isTimestampLocked(timestamp: timestamp) { return false }
        if !auth.isLoggedIn { return false }
        return NewsQuotaManager.shared.remaining <= 0
    }

    // MARK: - 尝试解锁一篇新闻
    func attemptUnlockArticle(_ article: Article,
                              auth: AuthManager,
                              viewModel: NewsViewModel,
                              onSuccess: @escaping () -> Void) {
        self.authRef = auth
        if Self.canAccess(article, auth: auth, viewModel: viewModel) { onSuccess(); return }

        if !auth.isLoggedIn { presentInsufficient(needLogin: true, context: .news); return }
        if quota.remaining <= 0 { presentInsufficient(needLogin: false, context: .news); return }

        presentConfirm(title: article.topic) { [weak self] in
            guard let self = self else { return }
            self.isProcessing = true
            Task {
                let uid = FreeQuotaManager.currentUserId(auth: auth)
                let key = FreeQuotaManager.newsKey(article)
                let r = await self.quota.unlockNews(userId: uid, articleKey: key, topic: article.topic)
                self.isProcessing = false
                switch r {
                case .success, .alreadyUnlocked: onSuccess()
                case .quotaExceeded:             self.presentInsufficient(needLogin: false, context: .news)
                case .failed:                    self.presentError("网络异常，扣点失败，请稍后再试")
                }
            }
        }
    }

    // MARK: - 首启登录引导弹窗
    func maybeShowFirstLaunchInvitePrompt(auth: AuthManager,
                                          reviewMode: Bool,
                                          isNewUser: Bool,
                                          isVideoHome: Bool) {
        guard !auth.isSubscribed else { return }
        guard !auth.isLoggedIn else { return }
        let key = "hasShownNewsInvitePrompt"
        if UserDefaults.standard.bool(forKey: key) { return }
        if reviewMode && isNewUser { return }
        UserDefaults.standard.set(true, forKey: key)
        self.authRef = auth
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            if isVideoHome {
                self.showVideoLoginPrompt = true
            } else {
                self.presentInsufficient(needLogin: true, context: .news)
            }
        }
    }

    // MARK: - 低层
    func presentConfirm(title: String, onConfirm: @escaping () -> Void) {
        confirmTitle = title
        confirmRemaining = quota.remaining
        confirmUsingBonus = quota.bonusRemaining > 0
        confirmAction = onConfirm
        showConfirmSheet = true
    }

    // ⭐ 统一入口：带上下文 + 是否真的点数不足
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

    // ⭐ 订阅：统一
    func goSubscribe() {
        showInsufficientSheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.showSubscriptionSheet = true }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.authRef?.signInWithApple()
        }
    }

    func goLogin() {
        showInsufficientSheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.showLoginSheet = true }
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
        }
        .animation(.easeInOut(duration: 0.2), value: c.showConfirmSheet)
        .animation(.easeInOut(duration: 0.2), value: c.showInsufficientSheet)
        .animation(.easeInOut(duration: 0.2), value: c.showVideoLoginPrompt)
        .animation(.easeInOut(duration: 0.2), value: c.showErrorSheet)
        .animation(.easeInOut(duration: 0.2), value: c.isProcessing)
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
                        c.authRef?.signInWithApple()
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

    private var confirmDialog: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { c.confirmNo() }
            VStack(spacing: 0) {
                Image(systemName: "bolt.circle.fill").font(.system(size: 44))
                    .foregroundStyle(.orange).padding(.top, 24)
                Text(en ? "Use 1 Point" : "点数消耗确认").font(.subheadline).foregroundColor(.secondary).padding(.top, 12)
                Text("标题：\(c.confirmTitle)")
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
                Divider().padding(.top, 18)
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

    // MARK: - ⭐ 借鉴 Finance 的醒目订阅按钮（订阅统一）
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
                    // 原价划线
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("¥")
                            .font(.system(size: 10))
                        Text("18")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.7))
                            .strikethrough(color: .white.opacity(0.7))
                    }
                    // 现价
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("¥")
                            .font(.system(size: 13, weight: .bold))
                        Text("12")
                            .font(.system(size: 24, weight: .heavy))
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

    // 标题（区分：需登录 / 真不足 / 主动获取更多）
    private var insufficientTitle: String {
        if c.insufficientNeedLogin { return en ? "Sign in to unlock" : "登录后免费阅览" }
        if c.insufficientIsShortage { return en ? "Out of points" : "点数不足" }
        return en ? "Get more points" : "获取更多点数"
    }

    // 说明文案（扣点文本保持原样）
    @ViewBuilder
    private var insufficientMessageView: some View {
        if c.insufficientNeedLogin {
            Text(en ? "Sign in (free, no purchase needed) to get a welcome gift plus free daily passes. Invite friends for even more!"
                    : "登录成功即可领取新人礼包和每日免费点数，登录无需付费！")
        } else if c.insufficientIsShortage {
            // ⭐ 保留原扣点文本（带彩色数字）
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

    // MARK: - ⭐ 统一复用的点数不足 / 获取更多点数弹窗（Finance 风格）
    private var insufficientDialog: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 0) {
                Image(systemName: c.insufficientNeedLogin ? "person.crop.circle.badge.plus" : "gift.fill")
                    .font(.system(size: 44)).foregroundStyle(.orange).padding(.top, 24)

                Text(insufficientTitle)
                    .font(.headline).padding(.top, 12)

                insufficientMessageView
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20).padding(.top, 8)

                // 主推按钮：未登录→登录；已登录→邀请拉新（按上下文分新闻/视频）
                Button {
                    if c.insufficientNeedLogin {
                        c.doLoginFromInsufficient()
                    } else {
                        c.openInviteForContext()
                    }
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

                // 订阅按钮（非登录门禁时展示；订阅统一）
                if !c.insufficientNeedLogin {
                    subscribeButton
                        .padding(.horizontal, 20).padding(.top, 12)
                }

                Divider().padding(.top, 16)

                // 「再等等」低调关闭
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
        HStack(spacing: 6) {
            Text(en ? "Points \(quota.remaining)" : "点数 \(quota.remaining)")
                .font(.system(size: 13, weight: .medium)).foregroundColor(.primary)
            Button {
                coordinator.authRef = authManager
                // ⭐ 复用统一弹窗（新闻上下文；主动点“+” → isShortage:false）
                if authManager.isLoggedIn {
                    coordinator.presentInsufficient(needLogin: false, context: .news, isShortage: false)
                } else {
                    coordinator.presentInsufficient(needLogin: true, context: .news, isShortage: false)
                }
            } label: {
                Image(systemName: "plus.circle.fill").font(.system(size: 16)).foregroundColor(.orange)
            }.buttonStyle(BorderlessButtonStyle())
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(Color(.tertiarySystemFill))
            .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5)))
        .fixedSize(horizontal: true, vertical: false)
    }
}