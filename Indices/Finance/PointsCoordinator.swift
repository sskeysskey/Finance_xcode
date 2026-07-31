import SwiftUI

@MainActor
final class PointsCoordinator: ObservableObject {
    static let shared = PointsCoordinator()
    private init() {}

    // 确认弹窗
    @Published var showConfirmSheet = false
    @Published var confirmCost = 0
    @Published var confirmTitle = ""
    @Published var confirmRemaining = 0
    @Published var confirmUsingBonus = false
    @Published var confirmDataStale = false
    @Published var confirmDataTimestamp = ""
    private var confirmAction: (() -> Void)?

    // 点数不足 / 登录门禁弹窗
    @Published var showInsufficientSheet = false
    @Published var insufficientCost = 0
    @Published var insufficientRemaining = 0
    @Published var insufficientNeedLogin = false

    // 结算中 / 错误
    @Published var isProcessing = false
    @Published var showErrorSheet = false
    @Published var errorText = ""

    // 邀请 / 登录页面（由 MainContentView 绑定 sheet）
    @Published var showInviteSheet = false
    @Published var showLoginSheet = false

    // 旧数据免点日提示（每天只弹一次）
    @Published var showFreeDayTip = false
    private let freeDayTipDateKey = "FinanceFreeDayTipDate"

    weak var authManagerRef: AuthManager?
    private let usage = UsageManager.shared

    // MARK: - 【新增】纯登录门禁：不扣点，但必须已登录（用于"对比 / 搜索"等入口）
    func requireLogin(authManager: AuthManager, onSuccess: @escaping () -> Void) {
        self.authManagerRef = authManager
        if authManager.isSubscribed { onSuccess(); return }
        if isLoggedInStrict(authManager) { onSuccess(); return }
        presentInsufficient(cost: 0, needLogin: true)
    }

    /// 【新增】双重校验登录态：AuthManager 与 UsageManager 必须同时认为已登录
    private func isLoggedInStrict(_ authManager: AuthManager) -> Bool {
        guard authManager.isLoggedIn else { return false }
        guard let uid = authManager.userIdentifier, !uid.isEmpty else { return false }
        // dev_ / guest_ 前缀一律视为未登录（与服务器 is_real_login_user 保持一致）
        if uid.hasPrefix("dev_") || uid == "guest_user" { return false }
        guard usage.isLoggedIn else { return false }
        return true
    }

    /// 通用扣点入口
    func attempt(action: UsageAction,
                 itemKey: String? = nil,
                 displayName: String,
                 authManager: AuthManager,
                 onSuccess: @escaping () -> Void) {
        self.authManagerRef = authManager

        // 0. 订阅用户：无限制
        if authManager.isSubscribed { onSuccess(); return }

        // 1. 【核心修复】未登录一律拦截 —— 必须排在 cost<=0 / 已解锁 / 免点日 之前
        if !isLoggedInStrict(authManager) {
            let c = usage.cost(for: action, itemKey: itemKey)
            presentInsufficient(cost: max(c, 1), needLogin: true)
            return
        }

        let cost = usage.cost(for: action, itemKey: itemKey)
        if cost <= 0 { onSuccess(); return }
        if usage.isUnlocked(action: action, itemKey: itemKey) { onSuccess(); return }

        // 2. 旧数据免点日（只对已登录用户生效，且以服务器标志为准）
        if isFreeDayNow() {
            maybeShowFreeDayTip()
            onSuccess()
            return
        }

        if usage.hasEnough(cost) {
            presentConfirm(cost: cost, title: displayName) { [weak self] in
                guard let self = self else { return }
                self.isProcessing = true
                Task {
                    let result = await self.usage.consume(action: action, itemKey: itemKey)
                    self.isProcessing = false
                    switch result {
                    case .success, .alreadyUnlocked, .free:
                        onSuccess()
                    case .insufficient:
                        self.presentInsufficient(cost: cost, needLogin: false)
                    case .notLoggedIn:
                        self.presentInsufficient(cost: cost, needLogin: true)
                    case .networkError:
                        self.presentError("网络异常，扣点失败，请稍后再试")
                    }
                }
            }
        } else {
            presentInsufficient(cost: cost, needLogin: false)
        }
    }

    func isFree(action: UsageAction, itemKey: String?, authManager: AuthManager) -> Bool {
        if authManager.isSubscribed { return true }
        // 【核心修复】未登录永远不算"免费"
        if !isLoggedInStrict(authManager) { return false }
        if usage.cost(for: action, itemKey: itemKey) <= 0 { return true }
        if usage.isUnlocked(action: action, itemKey: itemKey) { return true }
        if isFreeDayNow() { return true }
        return false
    }

    /// 【核心修复】只信任服务器当日下发的免点日标志。
    /// 拿不到时保守返回 false（宁可多扣点，也不能让改系统日期的人白嫖）。
    private func isFreeDayNow() -> Bool {
        guard let auth = authManagerRef, isLoggedInStrict(auth) else { return false }
        if let serverFlag = DataService.shared.isFreeAccessDayServer {
            return serverFlag
        }
        return false
    }

    // MARK: - 免点日提示（每天只弹一次）
    private func maybeShowFreeDayTip() {
        let today = TradingDateHelper.beijingTodayString()
        let last = UserDefaults.standard.string(forKey: freeDayTipDateKey)
        guard last != today else { return }
        UserDefaults.standard.set(today, forKey: freeDayTipDateKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.showFreeDayTip = true
        }
    }

    func dismissFreeDayTip() { showFreeDayTip = false }

    // MARK: - 数据是否过期
    private func isDataStale() -> Bool {
        guard let ts = DataService.shared.ecoDataTimestamp, !ts.isEmpty else { return false }
        let datePart = ts.split(separator: " ").first.map(String.init) ?? ts
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let dataDate = formatter.date(from: datePart) else { return false }
        let cal = Calendar.current
        return cal.startOfDay(for: dataDate) < cal.startOfDay(for: Date())
    }

    // MARK: - 低层接口
    func presentConfirm(cost: Int, title: String, onConfirm: @escaping () -> Void) {
        self.confirmCost = cost
        self.confirmTitle = title
        self.confirmRemaining = usage.remainingTotal
        self.confirmUsingBonus = usage.bonusRemaining > 0
        self.confirmDataStale = isDataStale()
        self.confirmDataTimestamp = DataService.shared.ecoDataTimestamp ?? ""
        self.confirmAction = onConfirm
        self.showConfirmSheet = true
    }

    func presentInsufficient(cost: Int, needLogin: Bool = false) {
        self.insufficientCost = cost
        self.insufficientRemaining = usage.remainingTotal
        self.insufficientNeedLogin = needLogin
        self.showInsufficientSheet = true
    }

    func presentError(_ msg: String) {
        self.errorText = msg
        self.showErrorSheet = true
    }

    func confirmYes() {
        showConfirmSheet = false
        let act = confirmAction
        confirmAction = nil
        DispatchQueue.main.async { act?() }
    }

    func confirmNo() {
        showConfirmSheet = false
        confirmAction = nil
    }

    func goSubscribe() {
        showInsufficientSheet = false
        let auth = authManagerRef
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            auth?.showSubscriptionSheet = true
        }
    }

    func openInvite() {
        showInsufficientSheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showInviteSheet = true
        }
    }

    func goLogin() {
        showInsufficientSheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showLoginSheet = true
        }
    }

    func dismissInsufficient() { showInsufficientSheet = false }
}

// MARK: - 全局弹窗浮层
struct PointsOverlayView: View {
    @ObservedObject var coordinator = PointsCoordinator.shared

    @State private var subShine = false

    var body: some View {
        ZStack {
            if coordinator.showConfirmSheet { confirmDialog }
            if coordinator.showInsufficientSheet { insufficientDialog }
            if coordinator.showErrorSheet { errorDialog }
            if coordinator.showFreeDayTip { freeDayTipDialog }
            if coordinator.isProcessing { processingOverlay }
        }
        .animation(.easeInOut(duration: 0.2), value: coordinator.showConfirmSheet)
        .animation(.easeInOut(duration: 0.2), value: coordinator.showInsufficientSheet)
        .animation(.easeInOut(duration: 0.2), value: coordinator.showErrorSheet)
        .animation(.easeInOut(duration: 0.2), value: coordinator.showFreeDayTip)
        .animation(.easeInOut(duration: 0.2), value: coordinator.isProcessing)
    }

    private var freeDayTipDialog: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture { coordinator.dismissFreeDayTip() }
            VStack(spacing: 0) {
                Image(systemName: "gift.fill")
                    .font(.system(size: 44)).foregroundStyle(.green).padding(.top, 24)
                Text("今日免费畅览").font(.headline).padding(.top, 12)
                Text("今天美股休市（周末 / 节假日），数据与上一交易日相同、尚未更新。\n为避免浪费点数，今日全部内容均可免费查看，不消耗任何点数。")
                    .font(.subheadline).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20).padding(.top, 8)
                Divider().padding(.top, 18)
                Button(action: { coordinator.dismissFreeDayTip() }) {
                    Text("好的，开始免费查看")
                        .fontWeight(.bold).frame(maxWidth: .infinity).padding(.vertical, 14)
                        .foregroundColor(.green)
                }
            }
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(18).padding(.horizontal, 50).shadow(radius: 20)
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().scaleEffect(1.3).tint(.white)
                Text("处理中...").font(.footnote).foregroundColor(.white)
            }
            .padding(24)
            .background(Color.black.opacity(0.6))
            .cornerRadius(14)
        }
    }

    private var errorDialog: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture { coordinator.showErrorSheet = false }
            VStack(spacing: 0) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 42)).foregroundStyle(.orange).padding(.top, 24)
                Text("操作失败").font(.headline).padding(.top, 12)
                Text(coordinator.errorText)
                    .font(.subheadline).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 20).padding(.top, 8)
                Divider().padding(.top, 18)
                Button(action: { coordinator.showErrorSheet = false }) {
                    Text("知道了").fontWeight(.bold).frame(maxWidth: .infinity).padding(.vertical, 14)
                }
            }
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(18).padding(.horizontal, 60).shadow(radius: 20)
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var confirmDialog: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture { coordinator.confirmNo() }
            VStack(spacing: 0) {
                Image(systemName: "bolt.circle.fill")
                    .font(.system(size: 44)).foregroundStyle(.orange).padding(.top, 24)
                Text("确认消耗点数").font(.headline).padding(.top, 12)
                Text(coordinator.confirmTitle)
                    .font(.subheadline).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).lineLimit(2)
                    .padding(.horizontal, 20).padding(.top, 6)

                HStack(spacing: 4) {
                    Text("本次消耗")
                    Text("\(coordinator.confirmCost)").fontWeight(.bold).foregroundColor(.orange)
                    Text("点 · 剩余")
                    Text("\(coordinator.confirmRemaining)").fontWeight(.bold).foregroundColor(.blue)
                    Text("点")
                }
                .font(.footnote).padding(.top, 14)

                Text(coordinator.confirmUsingBonus ? "将优先扣除赠送点数 · 今日再次访问此项免费"
                                                   : "今日再次访问此项将不再扣点")
                    .font(.caption2).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 16).padding(.top, 6)

                if coordinator.confirmDataStale {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange).font(.system(size: 15)).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("今日数据尚未更新").font(.caption).fontWeight(.bold).foregroundColor(.orange)
                            Text(dataStaleMessage)
                                .font(.caption2).foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.35), lineWidth: 0.5))
                    )
                    .padding(.horizontal, 16).padding(.top, 14)
                }

                Divider().padding(.top, 18)
                HStack(spacing: 0) {
                    Button(action: { coordinator.confirmNo() }) {
                        Text("取消").frame(maxWidth: .infinity).padding(.vertical, 14).foregroundColor(.secondary)
                    }
                    Divider().frame(height: 46)
                    Button(action: { coordinator.confirmYes() }) {
                        Text(coordinator.confirmDataStale ? "仍要查看" : "确认")
                            .fontWeight(.bold).frame(maxWidth: .infinity).padding(.vertical, 14)
                            .foregroundColor(coordinator.confirmDataStale ? .orange : .blue)
                    }
                }
            }
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(18).padding(.horizontal, 50).shadow(radius: 20)
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var dataStaleMessage: String {
        let base = "当前显示的仍是上一交易日的数据，今天的新数据一般在上午更新。建议数据更新后再查看，以免白白消耗点数。"
        return coordinator.confirmDataTimestamp.isEmpty ? base
             : "数据截至 \(coordinator.confirmDataTimestamp)。\(base)"
    }

    private var subscribeButton: some View {
        Button(action: { coordinator.goSubscribe() }) {
            HStack(spacing: 10) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text("升级专业版 · 免费畅看")
                        .font(.system(size: 15, weight: .bold))
                    Text("告别点数烦恼，一步到位")
                        .font(.system(size: 11))
                        .opacity(0.9)
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("¥").font(.system(size: 13, weight: .bold))
                    Text("6").font(.system(size: 24, weight: .heavy))
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
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
                Text("超值")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(.white)
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

    private var insufficientDialog: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 0) {
                Image(systemName: coordinator.insufficientNeedLogin ? "person.crop.circle.badge.plus" : "gift.fill")
                    .font(.system(size: 44)).foregroundStyle(.orange).padding(.top, 24)

                Text(coordinator.insufficientNeedLogin ? "登录后即可免费领取大量点数" : "今日点数不足")
                    .font(.headline).padding(.top, 12)

                Text(coordinator.insufficientNeedLogin
                    ? "该功能需要登录后使用。登录即可一次性获赠大量免费点数，每天打卡还有免费点数赠送；参与「邀请中大奖」活动，双方还将各获得大量免费点数！"
                    : "本次需要 \(coordinator.insufficientCost) 点，当前仅剩 \(coordinator.insufficientRemaining) 点。")
                    .font(.subheadline).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 20).padding(.top, 8)

                Button(action: {
                    if coordinator.insufficientNeedLogin {
                        coordinator.goLogin()
                    } else {
                        coordinator.openInvite()
                    }
                }) {
                    HStack {
                        Image(systemName: coordinator.insufficientNeedLogin ? "person.fill.checkmark" : "party.popper.fill")
                        Text(coordinator.insufficientNeedLogin ? "立即登录 · 免费领取点数" : "邀请中大奖 · 免费领点数")
                            .font(.subheadline)
                            .fontWeight(.bold)
                    }
                    .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(LinearGradient(colors: [.pink, .orange], startPoint: .leading, endPoint: .trailing))
                    .cornerRadius(12)
                }
                .padding(.horizontal, 20).padding(.top, 18)

                if !coordinator.insufficientNeedLogin {
                    subscribeButton
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }

                Divider().padding(.top, 16)

                if coordinator.insufficientNeedLogin {
                    HStack(spacing: 0) {
                        Button(action: { coordinator.dismissInsufficient() }) {
                            Text("再等等").frame(maxWidth: .infinity).padding(.vertical, 14).foregroundColor(.secondary)
                        }
                        Divider().frame(height: 46)
                        Button(action: { coordinator.openInvite() }) {
                            Text("了解活动").fontWeight(.bold).frame(maxWidth: .infinity).padding(.vertical, 14).foregroundColor(.blue)
                        }
                    }
                } else {
                    Button(action: { coordinator.dismissInsufficient() }) {
                        Text("再等等")
                            .frame(maxWidth: .infinity).padding(.vertical, 14).foregroundColor(.secondary)
                    }
                }
            }
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(18).padding(.horizontal, 40).shadow(radius: 20)
            .transition(.scale.combined(with: .opacity))
        }
    }
}