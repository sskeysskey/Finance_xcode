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

    weak var authManagerRef: AuthManager?
    private let usage = UsageManager.shared

    /// 通用扣点入口
    func attempt(action: UsageAction,
                 itemKey: String? = nil,
                 displayName: String,
                 authManager: AuthManager,
                 onSuccess: @escaping () -> Void) {
        self.authManagerRef = authManager

        if authManager.isSubscribed { onSuccess(); return }

        let cost = usage.cost(for: action, itemKey: itemKey)
        if cost <= 0 { onSuccess(); return }
        if usage.isUnlocked(action: action, itemKey: itemKey) { onSuccess(); return }

        // 免费点数只发给登录用户 → 未登录直接引导
        if !authManager.isLoggedIn {
            presentInsufficient(cost: cost, needLogin: true)
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
        if usage.cost(for: action, itemKey: itemKey) <= 0 { return true }
        if usage.isUnlocked(action: action, itemKey: itemKey) { return true }
        return false
    }

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

    var body: some View {
        ZStack {
            if coordinator.showConfirmSheet { confirmDialog }
            if coordinator.showInsufficientSheet { insufficientDialog }
            if coordinator.showErrorSheet { errorDialog }
            if coordinator.isProcessing { processingOverlay }
        }
        .animation(.easeInOut(duration: 0.2), value: coordinator.showConfirmSheet)
        .animation(.easeInOut(duration: 0.2), value: coordinator.showInsufficientSheet)
        .animation(.easeInOut(duration: 0.2), value: coordinator.showErrorSheet)
        .animation(.easeInOut(duration: 0.2), value: coordinator.isProcessing)
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

    private var insufficientDialog: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 0) {
                Image(systemName: coordinator.insufficientNeedLogin ? "person.crop.circle.badge.plus" : "gift.fill")
                    .font(.system(size: 44)).foregroundStyle(.orange).padding(.top, 24)

                Text(coordinator.insufficientNeedLogin ? "登录后免费领取点数" : "今日点数不足")
                    .font(.headline).padding(.top, 12)

                Text(coordinator.insufficientNeedLogin
                     ? "登录后每天可领取免费点数，还能参与「邀请中大奖」，邀请好友双方各得 30 天会员！"
                     : "本次需要 \(coordinator.insufficientCost) 点，当前仅剩 \(coordinator.insufficientRemaining) 点。\n不想花钱？邀请好友即可白拿会员！")
                    .font(.subheadline).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 20).padding(.top, 8)

                // 主推：邀请中大奖
                Button(action: { coordinator.openInvite() }) {
                    HStack {
                        Image(systemName: "party.popper.fill")
                        Text("邀请中大奖 · 免费领会员").fontWeight(.bold)
                    }
                    .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(LinearGradient(colors: [.pink, .orange], startPoint: .leading, endPoint: .trailing))
                    .cornerRadius(12)
                }
                .padding(.horizontal, 20).padding(.top, 18)

                Divider().padding(.top, 16)
                HStack(spacing: 0) {
                    Button(action: { coordinator.dismissInsufficient() }) {
                        Text("再等等").frame(maxWidth: .infinity).padding(.vertical, 14).foregroundColor(.secondary)
                    }
                    Divider().frame(height: 46)
                    if coordinator.insufficientNeedLogin {
                        Button(action: { coordinator.goLogin() }) {
                            Text("去登录").fontWeight(.bold).frame(maxWidth: .infinity).padding(.vertical, 14).foregroundColor(.blue)
                        }
                    } else {
                        Button(action: { coordinator.goSubscribe() }) {
                            Text("去订阅").fontWeight(.bold).frame(maxWidth: .infinity).padding(.vertical, 14).foregroundColor(.blue)
                        }
                    }
                }
            }
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(18).padding(.horizontal, 40).shadow(radius: 20)
            .transition(.scale.combined(with: .opacity))
        }
    }
}