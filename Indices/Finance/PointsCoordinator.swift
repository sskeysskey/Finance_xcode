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
    // 【新增】数据是否过期（今日尚未更新）
    @Published var confirmDataStale = false
    // 【新增】当前数据的时间戳文字（用于提醒展示）
    @Published var confirmDataTimestamp = ""
    private var confirmAction: (() -> Void)?

    // 点数不足弹窗
    @Published var showInsufficientSheet = false
    @Published var insufficientCost = 0
    @Published var insufficientRemaining = 0

    weak var authManagerRef: AuthManager?

    private let usage = UsageManager.shared

    /// 通用扣点入口
    /// - VIP / 今日已解锁 / 免费动作 → 直接执行 onSuccess
    /// - 点数够 → 弹确认框，确认后扣点并执行
    /// - 点数不够 → 弹"点数不足→去订阅"过渡框
    func attempt(action: UsageAction,
                 itemKey: String? = nil,
                 displayName: String,
                 authManager: AuthManager,
                 onSuccess: @escaping () -> Void) {
        self.authManagerRef = authManager

        if authManager.isSubscribed { onSuccess(); return }
        if usage.isUnlocked(action: action, itemKey: itemKey) { onSuccess(); return }

        let cost = usage.cost(for: action, itemKey: itemKey)
        if cost <= 0 { onSuccess(); return }

        if usage.hasEnough(cost) {
            presentConfirm(cost: cost, title: displayName) { [weak self] in
                self?.usage.commitDeduction(action: action, itemKey: itemKey)
                onSuccess()
            }
        } else {
            presentInsufficient(cost: cost)
        }
    }

    /// 判断某项今天是否免费（VIP / 已解锁 / 0 点动作）
    func isFree(action: UsageAction, itemKey: String?, authManager: AuthManager) -> Bool {
        if authManager.isSubscribed { return true }
        if usage.isUnlocked(action: action, itemKey: itemKey) { return true }
        if usage.cost(for: action, itemKey: itemKey) <= 0 { return true }
        return false
    }

    // MARK: - 【新增】判断当日数据是否尚未更新
    /// 以 version 中的 Eco_Data 时间戳为准（DataService.ecoDataTimestamp）
    /// 只要数据日期早于系统当天，即认为"今日数据尚未更新"
    private func isDataStale() -> Bool {
        guard let ts = DataService.shared.ecoDataTimestamp, !ts.isEmpty else { return false }
        // ts 形如 "2026-07-08 10:03"，只取日期部分做比较
        let datePart = ts.split(separator: " ").first.map(String.init) ?? ts
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let dataDate = formatter.date(from: datePart) else { return false }

        let cal = Calendar.current
        // 数据日期的“当天零点”严格早于系统“今天零点” → 说明今天的数据还没更新
        return cal.startOfDay(for: dataDate) < cal.startOfDay(for: Date())
    }

    // MARK: - 低层接口（供搜索等特殊场景）
    func presentConfirm(cost: Int, title: String, onConfirm: @escaping () -> Void) {
        self.confirmCost = cost
        self.confirmTitle = title
        self.confirmRemaining = usage.remainingTotal
        self.confirmUsingBonus = usage.bonusRemaining > 0
        // 【新增】计算数据是否过期，并记录时间戳
        self.confirmDataStale = isDataStale()
        self.confirmDataTimestamp = DataService.shared.ecoDataTimestamp ?? ""
        self.confirmAction = onConfirm
        self.showConfirmSheet = true
    }

    func presentInsufficient(cost: Int) {
        self.insufficientCost = cost
        self.insufficientRemaining = usage.remainingTotal
        self.showInsufficientSheet = true
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

    func dismissInsufficient() { showInsufficientSheet = false }
}

// MARK: - 全局弹窗浮层（挂在根 ZStack）
struct PointsOverlayView: View {
    @ObservedObject var coordinator = PointsCoordinator.shared

    var body: some View {
        ZStack {
            if coordinator.showConfirmSheet { confirmDialog }
            if coordinator.showInsufficientSheet { insufficientDialog }
        }
        .animation(.easeInOut(duration: 0.2), value: coordinator.showConfirmSheet)
        .animation(.easeInOut(duration: 0.2), value: coordinator.showInsufficientSheet)
    }

    private var confirmDialog: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture { coordinator.confirmNo() }
            VStack(spacing: 0) {
                Image(systemName: "bolt.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                    .padding(.top, 24)

                Text("确认消耗点数")
                    .font(.headline)
                    .padding(.top, 12)

                Text(coordinator.confirmTitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)

                HStack(spacing: 4) {
                    Text("本次消耗")
                    Text("\(coordinator.confirmCost)").fontWeight(.bold).foregroundColor(.orange)
                    Text("点 · 剩余")
                    Text("\(coordinator.confirmRemaining)").fontWeight(.bold).foregroundColor(.blue)
                    Text("点")
                }
                .font(.footnote)
                .padding(.top, 14)

                Text(coordinator.confirmUsingBonus ? "将优先扣除赠送点数 · 今日再次访问此项免费"
                                                   : "今日再次访问此项将不再扣点")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)

                // MARK: - 【新增】数据尚未更新的醒目提醒条
                if coordinator.confirmDataStale {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 15))
                            .padding(.top, 1)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("今日数据尚未更新")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.orange)

                            Text(dataStaleMessage)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.orange.opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.orange.opacity(0.35), lineWidth: 0.5)
                            )
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                }

                Divider().padding(.top, 18)
                HStack(spacing: 0) {
                    Button(action: { coordinator.confirmNo() }) {
                        Text("取消").frame(maxWidth: .infinity).padding(.vertical, 14)
                            .foregroundColor(.secondary)
                    }
                    Divider().frame(height: 46)
                    Button(action: { coordinator.confirmYes() }) {
                        // 数据过期时弱化“确认”，用文字引导用户再想想
                        Text(coordinator.confirmDataStale ? "仍要查看" : "确认")
                            .fontWeight(.bold).frame(maxWidth: .infinity).padding(.vertical, 14)
                            .foregroundColor(coordinator.confirmDataStale ? .orange : .blue)
                    }
                }
            }
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(18)
            .padding(.horizontal, 50)
            .shadow(radius: 20)
            .transition(.scale.combined(with: .opacity))
        }
    }

    // 【新增】拼装提醒文案
    private var dataStaleMessage: String {
        let base = "当前显示的仍是上一交易日的数据，今天的新数据一般在上午更新。建议数据更新后再查看，以免白白消耗点数。"
        if coordinator.confirmDataTimestamp.isEmpty {
            return base
        } else {
            return "数据截至 \(coordinator.confirmDataTimestamp)。\(base)"
        }
    }

    private var insufficientDialog: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 0) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.red)
                    .padding(.top, 24)

                Text("今日点数不足")
                    .font(.headline)
                    .padding(.top, 12)

                Text("本次需要 \(coordinator.insufficientCost) 点，当前仅剩 \(coordinator.insufficientRemaining) 点。\n订阅专业版即可无限畅享全部功能。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                Divider().padding(.top, 18)
                HStack(spacing: 0) {
                    Button(action: { coordinator.dismissInsufficient() }) {
                        Text("再等等").frame(maxWidth: .infinity).padding(.vertical, 14)
                            .foregroundColor(.secondary)
                    }
                    Divider().frame(height: 46)
                    Button(action: { coordinator.goSubscribe() }) {
                        Text("去订阅").fontWeight(.bold).frame(maxWidth: .infinity).padding(.vertical, 14)
                            .foregroundColor(.orange)
                    }
                }
            }
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(18)
            .padding(.horizontal, 50)
            .shadow(radius: 20)
            .transition(.scale.combined(with: .opacity))
        }
    }
}