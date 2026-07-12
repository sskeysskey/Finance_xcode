import SwiftUI
import Combine

// 用户行为类型
enum UsageAction: String {
    case viewChart = "view_chart"
    case openSector = "open_sector"
    case search = "search_with_results"
    case openEarnings = "open_earnings"
    case openList = "open_list"
    case compare = "compare_execution"
    case openSpecialList = "open_special_list"
    case viewOptionsDetail = "view_options_detail"
    case viewOptionsRank = "view_options_rank"
    case viewBigOrders = "view_big_orders"
    case openHistory = "open_history"
}

// 服务器扣点结果
enum ConsumeResult {
    case success
    case alreadyUnlocked
    case free
    case insufficient
    case notLoggedIn
    case networkError
}

@MainActor
class UsageManager: ObservableObject {
    static let shared = UsageManager()

    // 展示用（服务器权威）
    @Published var dailyCount: Int = 0        // 服务器 daily_used
    @Published var maxFreeLimit: Int = 25     // 服务器 daily_limit
    @Published var bonusRemaining: Int = 0

    // 邀请信息
    @Published var inviteCode: String = ""
    @Published var inviteRewardCount: Int = 0
    @Published var hasRedeemedInvite: Bool = false
    @Published var inviteRewardPoints: Int = 300   // 邀请奖励点数（服务器下发）

    // 登录状态（由 AuthManager 同步进来）
    @Published var isLoggedIn: Bool = false

    // 单价配置（本地缓存，用于弹窗显示与预判；真正扣点以服务器为准）
    @Published var actionCosts: [String: Int] = [
        UsageAction.viewChart.rawValue: 2,
        UsageAction.openSector.rawValue: 15,
        UsageAction.search.rawValue: 1,
        UsageAction.openEarnings.rawValue: 15,
        UsageAction.openList.rawValue: 15,
        UsageAction.compare.rawValue: 10,
        UsageAction.openSpecialList.rawValue: 10,
        UsageAction.viewOptionsDetail.rawValue: 0,
        UsageAction.viewOptionsRank.rawValue: 5,
        UsageAction.viewBigOrders.rawValue: 20,
        UsageAction.openHistory.rawValue: 20
    ]
    @Published var sectorCostOverrides: [String: Int] = [:]

    // 今日已解锁项（来自服务器）
    private(set) var unlockedKeys: Set<String> = []
    private var currentUserId: String? = nil

    private let serverBaseURL = "http://106.15.183.158:5001/api/Finance"
    private let costConfigKey = "FinanceCostConfig"
    private let sectorOverrideKey = "FinanceSectorCostOverrides"

    // 总剩余点数（未登录一律 0）
    var remainingTotal: Int {
        guard isLoggedIn else { return 0 }
        return bonusRemaining + max(0, maxFreeLimit - dailyCount)
    }

    private init() {
        loadLocalCosts()
        loadSectorOverrides()
    }

    // MARK: - 身份 & 刷新
    func setCurrentUser(_ userId: String?, isLoggedIn: Bool) {
        self.currentUserId = userId
        self.isLoggedIn = isLoggedIn
        Task { await refreshQuota() }
    }

    func refresh() { Task { await refreshQuota() } }

    /// 每日重置由服务器负责，这里仅触发刷新
    func checkResetWithServerDate(_ serverDate: String) {
        refresh()
    }

    func refreshQuota() async {
        guard isLoggedIn, let uid = currentUserId,
              let encoded = uid.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(serverBaseURL)/quota/status?user_id=\(encoded)") else {
            // 未登录 → 全部清零
            self.dailyCount = 0
            self.bonusRemaining = 0
            self.unlockedKeys = []
            self.inviteCode = ""
            self.inviteRewardCount = 0
            self.hasRedeemedInvite = false
            return
        }
        struct S: Codable {
            let logged_in: Bool?
            let daily_limit: Int?
            let daily_used: Int?
            let bonus_remaining: Int?
            let invite_code: String?
            let invite_reward_count: Int?
            let has_redeemed_invite: Bool?
            let unlocked_keys: [String]?
            let invite_reward_points: Int?
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let s = try? JSONDecoder().decode(S.self, from: data) else { return }
            if let l = s.daily_limit { self.maxFreeLimit = l }
            self.dailyCount = s.daily_used ?? 0
            self.bonusRemaining = s.bonus_remaining ?? 0
            self.inviteCode = s.invite_code ?? ""
            self.inviteRewardCount = s.invite_reward_count ?? 0
            self.hasRedeemedInvite = s.has_redeemed_invite ?? false
            self.inviteRewardPoints = s.invite_reward_points ?? self.inviteRewardPoints
            self.unlockedKeys = Set(s.unlocked_keys ?? [])
        } catch {
            // 网络失败保持旧值即可
        }
    }

    // MARK: - 扣点（服务器权威）
    func consume(action: UsageAction, itemKey: String?) async -> ConsumeResult {
        guard isLoggedIn, let uid = currentUserId else { return .notLoggedIn }
        guard let url = URL(string: "\(serverBaseURL)/quota/consume") else { return .networkError }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 12
        let body: [String: Any] = ["user_id": uid, "action": action.rawValue, "item_key": itemKey ?? ""]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return .networkError }
        req.httpBody = data

        struct R: Codable {
            let status: String
            let remaining_total: Int?
            let bonus_remaining: Int?
            let daily_used: Int?
            let daily_limit: Int?
        }
        do {
            let (respData, _) = try await URLSession.shared.data(for: req)
            guard let r = try? JSONDecoder().decode(R.self, from: respData) else { return .networkError }
            if let b = r.bonus_remaining { self.bonusRemaining = b }
            if let d = r.daily_used { self.dailyCount = d }
            if let l = r.daily_limit { self.maxFreeLimit = l }
            switch r.status {
            case "success":
                markUnlocked(action: action, itemKey: itemKey); return .success
            case "already_unlocked":
                markUnlocked(action: action, itemKey: itemKey); return .alreadyUnlocked
            case "free":
                return .free
            case "insufficient":
                return .insufficient
            case "not_logged_in":
                return .notLoggedIn
            default:
                return .networkError
            }
        } catch {
            return .networkError
        }
    }

    /// 兼容旧的同步调用（若有其他页面仍在用）：本地标记 + 服务器结算
    func commitDeduction(action: UsageAction, itemKey: String?) {
        markUnlocked(action: action, itemKey: itemKey)
        Task { _ = await consume(action: action, itemKey: itemKey) }
    }

    // MARK: - 查询
    func cost(for action: UsageAction, itemKey: String?) -> Int {
        if let key = itemKey,
           [.openSector, .openSpecialList, .viewBigOrders].contains(action),
           let override = sectorCostOverrides[key] {
            return override
        }
        return actionCosts[action.rawValue] ?? 1
    }

    func isUnlocked(action: UsageAction, itemKey: String?) -> Bool {
        unlockedKeys.contains(unlockKey(action, itemKey))
    }

    func hasEnough(_ cost: Int) -> Bool { remainingTotal >= cost }

    func markUnlocked(action: UsageAction, itemKey: String?) {
        unlockedKeys.insert(unlockKey(action, itemKey))
    }

    private func unlockKey(_ action: UsageAction, _ itemKey: String?) -> String {
        if let k = itemKey, !k.isEmpty { return "\(action.rawValue)|\(k.uppercased())" }
        return action.rawValue
    }

    // MARK: - 配置更新（版本接口下发）
    func updateLimit(_ limit: Int) { self.maxFreeLimit = limit }

    // 服务器已按 version.json 发放，客户端不再本地发放；保留空实现兼容调用
    func updateBonus(_ amount: Int) { }

    func updateCosts(_ costs: [String: Int]) {
        var merged = self.actionCosts
        for (k, v) in costs { merged[k] = v }
        self.actionCosts = merged
        if let data = try? JSONEncoder().encode(merged) {
            UserDefaults.standard.set(data, forKey: costConfigKey)
        }
    }

    func updateSectorOverrides(_ overrides: [String: Int]) {
        self.sectorCostOverrides = overrides
        if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: sectorOverrideKey)
        }
    }

    private func loadLocalCosts() {
        if let data = UserDefaults.standard.data(forKey: costConfigKey),
           let cached = try? JSONDecoder().decode([String: Int].self, from: data) {
            for (k, v) in cached { self.actionCosts[k] = v }
        }
    }

    private func loadSectorOverrides() {
        if let data = UserDefaults.standard.data(forKey: sectorOverrideKey),
           let cached = try? JSONDecoder().decode([String: Int].self, from: data) {
            self.sectorCostOverrides = cached
        }
    }
}