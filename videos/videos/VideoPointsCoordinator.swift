import SwiftUI

/// 兼容别名：拷贝过来的视频文件里写的 NewsPointsCoordinator 无需改动
typealias NewsPointsCoordinator = VideoPointsCoordinator

@MainActor
final class VideoPointsCoordinator: ObservableObject {
    static let shared = VideoPointsCoordinator()
    private init() {}

    private let quota = FreeQuotaManager.shared
    weak var authRef: AuthManager?

    enum PointsContext { case video }

    // 扣点确认（预留）
    @Published var showConfirmSheet = false
    @Published var confirmTitle = ""
    @Published var confirmRemaining = 0
    @Published var confirmUsingBonus = false
    private var confirmAction: (() -> Void)?

    // 点数不足 / 登录门禁
    @Published var showInsufficientSheet = false
    @Published var insufficientNeedLogin = false
    @Published var insufficientRemaining = 0
    @Published var insufficientContext: PointsContext = .video
    @Published var insufficientIsShortage = true

    @Published var isProcessing = false
    @Published var showErrorSheet = false
    @Published var errorText = ""

    // 全局 sheet
    @Published var showVideoInviteSheet = false
    @Published var showSubscriptionSheet = false
    @Published var showVideoLoginPrompt = false

    /// 兼容旧调用点：置 true 会自动改写成"直接拉起苹果登录"
    @Published var showLoginSheet = false {
        didSet {
            guard showLoginSheet else { return }
            showLoginSheet = false
            let auth = authRef ?? AuthManager.shared
            DispatchQueue.main.async { auth.signInWithApple() }
        }
    }

    // MARK: 弹窗
    func presentConfirm(title: String, onConfirm: @escaping () -> Void) {
        confirmTitle = title
        confirmRemaining = quota.remaining
        confirmUsingBonus = quota.bonusRemaining > 0
        confirmAction = onConfirm
        showConfirmSheet = true
    }
    func confirmYes() {
        showConfirmSheet = false
        let a = confirmAction; confirmAction = nil
        DispatchQueue.main.async { a?() }
    }
    func confirmNo() { showConfirmSheet = false; confirmAction = nil }

    func presentInsufficient(needLogin: Bool,
                             context: PointsContext = .video,
                             isShortage: Bool = true) {
        insufficientContext = context
        insufficientNeedLogin = needLogin
        insufficientIsShortage = isShortage
        insufficientRemaining = quota.remaining
        showInsufficientSheet = true
        if needLogin { AnonymousSubscribePromptManager.shared.noteGuestPaywall() }
    }

    func presentError(_ m: String) { errorText = m; showErrorSheet = true }
    func dismissInsufficient() { showInsufficientSheet = false }

    func goSubscribe() {
        showInsufficientSheet = false
        let auth = authRef ?? AuthManager.shared
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if PurchaseFlowManager.useDirectPurchase {
                PurchaseFlowManager.shared.startPurchase(auth: auth, reason: "video-points-insufficient")
            } else {
                self.showSubscriptionSheet = true
            }
        }
    }

    func openInviteForContext() {
        showInsufficientSheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.showVideoInviteSheet = true }
    }
    func openInvite() { openInviteForContext() }

    func doLoginFromInsufficient() {
        showInsufficientSheet = false
        let auth = authRef ?? AuthManager.shared
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { auth.signInWithApple() }
    }
    func goLogin() { doLoginFromInsufficient() }
}

// MARK: - 全局弹窗浮层
struct VideoPointsOverlayView: View {
    @ObservedObject var c = VideoPointsCoordinator.shared
    @AppStorage("isGlobalEnglishMode") private var en = false
    @State private var subShine = false

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
                    Text(en ? "OK" : "知道了").fontWeight(.bold)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                }
            }
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(18).padding(.horizontal, 60).shadow(radius: 20)
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var videoLoginDialog: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button { c.showVideoLoginPrompt = false } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 24))
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
                    .background(LinearGradient(colors: [.pink, .orange],
                                               startPoint: .leading, endPoint: .trailing))
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
                Text(en ? "Use 1 Point" : "点数消耗确认")
                    .font(.subheadline).foregroundColor(.secondary).padding(.top, 12)
                Text(c.confirmTitle)
                    .font(.headline).multilineTextAlignment(.center).lineLimit(2)
                    .padding(.horizontal, 20).padding(.top, 6)
                HStack(spacing: 4) {
                    Text(en ? "Cost" : "本次将消耗")
                    Text("1").fontWeight(.bold).foregroundColor(.orange)
                    Text(en ? "· Left" : "点 · 剩余")
                    Text("\(c.confirmRemaining)").fontWeight(.bold).foregroundColor(.blue)
                }.font(.footnote).padding(.top, 14)
                Divider().padding(.top, 16)
                HStack(spacing: 0) {
                    Button { c.confirmNo() } label: {
                        Text(en ? "Cancel" : "取消").frame(maxWidth: .infinity)
                            .padding(.vertical, 14).foregroundColor(.secondary)
                    }
                    Divider().frame(height: 46)
                    Button { c.confirmYes() } label: {
                        Text(en ? "Confirm" : "确认").fontWeight(.bold)
                            .frame(maxWidth: .infinity).padding(.vertical, 14).foregroundColor(.blue)
                    }
                }
            }
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(18).padding(.horizontal, 50).shadow(radius: 20)
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var insufficientTitle: String {
        if c.insufficientNeedLogin { return en ? "Sign in to watch" : "登录后免费观看" }
        if c.insufficientIsShortage { return en ? "Out of points" : "点数不足" }
        return en ? "Get more points" : "获取更多点数"
    }

    @ViewBuilder
    private var insufficientMessageView: some View {
        if c.insufficientNeedLogin {
            Text(en ? "Sign in (free, no purchase needed) to get a welcome gift plus free daily passes."
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
                    : "邀请好友得免费点数，或直接订阅畅享全部内容")
        }
    }

    private var insufficientDialog: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 0) {
                Text(insufficientTitle).font(.headline).padding(.top, 22)
                insufficientMessageView
                    .font(.subheadline).multilineTextAlignment(.center)
                    .padding(.horizontal, 20).padding(.top, 8)

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
                    .background(LinearGradient(colors: [.pink, .orange],
                                               startPoint: .leading, endPoint: .trailing))
                    .cornerRadius(12)
                }
                .padding(.horizontal, 20).padding(.top, 18)

                if c.insufficientNeedLogin {
                    AnonymousSubscribeButton(reason: "video-guest-paywall")
                        .padding(.horizontal, 20).padding(.top, 12)
                } else {
                    subscribeButton.padding(.horizontal, 20).padding(.top, 12)
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

    private var subscribeButton: some View {
        Button { c.goSubscribe() } label: {
            HStack(spacing: 10) {
                Image(systemName: "crown.fill").font(.system(size: 20)).foregroundColor(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text(en ? "Go Premium · Unlimited" : "升级 VIP 尊享会员")
                        .font(.system(size: 15, weight: .bold))
                    Text(en ? "No more point limits" : "告别点数烦恼，一步到位")
                        .font(.system(size: 11)).opacity(0.9)
                }
                Spacer()
                Text(Localized.cachedDisplayPrice).font(.system(size: 22, weight: .heavy))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(LinearGradient(colors: [Color.indigo, Color.blue, Color.cyan],
                                       startPoint: .leading, endPoint: .trailing))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.35), lineWidth: 1))
            .shadow(color: .blue.opacity(0.45), radius: subShine ? 12 : 6, y: 4)
            .scaleEffect(subShine ? 1.02 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .onAppear {
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { subShine = true }
        }
    }
}
