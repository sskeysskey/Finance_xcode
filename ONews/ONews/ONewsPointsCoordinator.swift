import SwiftUI

@MainActor
final class NewsPointsCoordinator: ObservableObject {
    static let shared = NewsPointsCoordinator()
    private init() {}

    private let quota = NewsQuotaManager.shared 
    weak var authRef: AuthManager?

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

    // 结算中 / 错误
    @Published var isProcessing = false
    @Published var showErrorSheet = false
    @Published var errorText = ""

    // 全局 sheet（由 MainAppView 绑定）
    @Published var showInviteSheet = false
    @Published var showVideoInviteSheet = false     // 视频邀请
    @Published var showLoginSheet = false
    @Published var showSubscriptionSheet = false
    // 【新增】视频首页(commonview)首启登录弹窗（对应“未登录点击视频线路”弹窗）
    @Published var showVideoLoginPrompt = false

    // MARK: - 是否可免费访问一篇新闻
    static func canAccess(_ article: Article, auth: AuthManager, viewModel: NewsViewModel) -> Bool {
        if auth.isSubscribed { return true }
        if !viewModel.isTimestampLocked(timestamp: article.timestamp) { return true } // 老新闻免费
        return NewsQuotaManager.shared.isNewsUnlocked(FreeQuotaManager.newsKey(article))
    }

    // MARK: - 尝试解锁一篇新闻
    func attemptUnlockArticle(_ article: Article,
                              auth: AuthManager,
                              viewModel: NewsViewModel,
                              onSuccess: @escaping () -> Void) {
        self.authRef = auth
        if Self.canAccess(article, auth: auth, viewModel: viewModel) { onSuccess(); return }

        if !auth.isLoggedIn { presentInsufficient(needLogin: true); return }
        if quota.remaining <= 0 { presentInsufficient(needLogin: false); return }

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
                case .quotaExceeded:             self.presentInsufficient(needLogin: false)
                case .failed:                    self.presentError("网络异常，扣点失败，请稍后再试")
                }
            }
        }
    }

    // MARK: - 首启登录引导弹窗
    // isVideoHome: 首页是否为“只看视频”的 commonview
    func maybeShowFirstLaunchInvitePrompt(auth: AuthManager,
                                          reviewMode: Bool,
                                          isNewUser: Bool,
                                          isVideoHome: Bool) {
        guard !auth.isSubscribed else { return }
        guard !auth.isLoggedIn else { return }          // 已登录用户不弹
        let key = "hasShownNewsInvitePrompt"
        if UserDefaults.standard.bool(forKey: key) { return }  // 只弹一次
        if reviewMode && isNewUser { return }           // 审核模式下：新用户不弹（也不标记）
        UserDefaults.standard.set(true, forKey: key)
        self.authRef = auth
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            if isVideoHome {
                self.showVideoLoginPrompt = true          // 视频首页 → 视频登录弹窗
            } else {
                self.presentInsufficient(needLogin: true) // 新闻首页 → 未登录付费新闻弹窗
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
    func presentInsufficient(needLogin: Bool) {
        insufficientNeedLogin = needLogin
        insufficientRemaining = quota.remaining
        showInsufficientSheet = true
    }
    func presentError(_ msg: String) { errorText = msg; showErrorSheet = true }

    func confirmYes() {
        showConfirmSheet = false
        let a = confirmAction; confirmAction = nil
        DispatchQueue.main.async { a?() }
    }
    func confirmNo() { showConfirmSheet = false; confirmAction = nil }

    func goSubscribe() {
        showInsufficientSheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.showSubscriptionSheet = true }
    }
    func openInvite() {
        showInsufficientSheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.showInviteSheet = true }
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

    var body: some View {
        ZStack {
            if c.showConfirmSheet { confirmDialog }
            if c.showInsufficientSheet { insufficientDialog }
            if c.showVideoLoginPrompt { videoLoginDialog }   // 【新增】
            if c.showErrorSheet { errorDialog }
            if c.isProcessing { processingOverlay }
        }
        .animation(.easeInOut(duration: 0.2), value: c.showConfirmSheet)
        .animation(.easeInOut(duration: 0.2), value: c.showInsufficientSheet)
        .animation(.easeInOut(duration: 0.2), value: c.showVideoLoginPrompt)  // 【新增】
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

    // 【新增】视频首页登录引导弹窗（对应“未登录点击视频线路”弹窗）
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

    private var insufficientDialog: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 0) {
                // 右上角关闭 X
                HStack {
                    Spacer()
                    Button {
                        c.dismissInsufficient()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .padding(.trailing, 16)
                    .padding(.top, 16)
                }

                Text(c.insufficientNeedLogin
                    ? (en ? "Sign in to unlock" : "登录后免费阅览")
                    : (en ? "Out of points" : "点数不足"))
                    .font(.headline).padding(.top, 12)
                if c.insufficientNeedLogin {
                    Text(en ? "Viewing the latest news needs points. Sign in (free) to get a welcome gift plus free daily passes. Invite friends for even more!"
                            : "登录成功即可领取新人礼包和每日免费点数，登录无需付费！")
                        .font(.subheadline).foregroundColor(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 20).padding(.top, 8)
                } else {
                    VStack(spacing: 4) {
                        HStack(spacing: 3) {
                            Text("本次需要 ").foregroundColor(.secondary)
                            Text("1").foregroundColor(.orange).fontWeight(.bold)
                            Text(" 点，当前仅剩 ").foregroundColor(.secondary)
                            Text("\(c.insufficientRemaining)").foregroundColor(.blue).fontWeight(.bold)
                            Text(" 点。").foregroundColor(.secondary)
                        }
                        Text("不想付费？邀请好友即可白拿点数！")
                            .foregroundColor(.secondary)
                    }
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                }

                // ========== 分支1：未登录 只展示橙色登录按钮 ==========
                if c.insufficientNeedLogin {
                    Button {
                        // 复用VideoDetail成熟登录逻辑，替换原有c.goLogin()
                        c.dismissInsufficient()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            // 这里需要把AuthManager传入Coordinator，新增全局auth引用
                            NewsPointsCoordinator.shared.authRef?.signInWithApple()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "person.fill.checkmark")
                            Text(en ? "Sign in · Get points" : "现在就登录")
                                .fontWeight(.bold)
                        }
                        .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(LinearGradient(colors: [.pink, .orange], startPoint: .leading, endPoint: .trailing))
                        .cornerRadius(12)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 24) // 新增底部间距，拉开和弹窗底边距离
                }
                else {
                    Divider().padding(.top, 16)
                    HStack(spacing: 0) {
                        // 左侧：邀请好友 - 蓝色字体
                        Button { c.openInvite() } label: {
                            Text(en ? "Invite friends · Free points" : "邀请好友\n得免费点数")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .foregroundColor(.blue)
                        }
                        Divider().frame(height: 46)
                        // 右侧：去订阅 - 橙色背景仅包裹文字
                        Button { c.goSubscribe() } label: {
                            Text(en ? "Subscribe for unlimited" : "直接订阅")
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                // 内边距控制背景留白：上下小间距、左右适中
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    LinearGradient(colors: [.orange, .pink], startPoint: .leading, endPoint: .trailing)
                                )
                                .cornerRadius(8)
                        }
                        // 取消整行拉伸，让按钮内容自适应宽度
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 14)
                    }
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
                if authManager.isLoggedIn {
                    coordinator.showInviteSheet = true              // 已登录 → 拉新活动
                } else {
                    coordinator.presentInsufficient(needLogin: true) // 未登录 → 同付费新闻弹窗
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