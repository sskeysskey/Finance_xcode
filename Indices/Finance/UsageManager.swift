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
    // 【新增】复盘历史
    case openHistory = "open_history"
}

@MainActor
class UsageManager: ObservableObject {
    static let shared = UsageManager()

    @Published var dailyCount: Int = 0
    @Published var maxFreeLimit: Int = 55
    // 【新增】一次性赠送点数余额（消耗时优先扣它）
    @Published var bonusRemaining: Int = 0

    // 默认扣点配置（服务器没返回时兜底）
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

    // 【新增】各分组独立扣点覆盖（如 "Short": 20, "PE_Hot": 5）
    @Published var sectorCostOverrides: [String: Int] = [:]

    // 【新增】今日已解锁的项（当天免费再次访问）
    @Published private(set) var unlockedKeys: Set<String> = []

    // 【新增】总剩余点数
    var remainingTotal: Int {
        bonusRemaining + max(0, maxFreeLimit - dailyCount)
    }

    private let countKey = "FinanceDailyUsageCount"
    private let dateKey = "FinanceLastUsageDate"
    private let costConfigKey = "FinanceCostConfig"
    private let sectorOverrideKey = "FinanceSectorCostOverrides"
    private let lastServerDateKey = "LastServerDate"
    // 【新增】
    private let bonusRemainingKey = "FinanceBonusRemaining"
    private let bonusGrantedKey = "FinanceBonusGranted"
    private let bonusAmountKey = "FinanceBonusAmount"
    private let unlockedKeysKey = "FinanceUnlockedKeys"

    private var configuredBonusAmount = 200

    private init() {
        self.dailyCount = UserDefaults.standard.integer(forKey: countKey)
        loadLocalCosts()
        loadSectorOverrides()

        // 赠送点数初始化
        self.configuredBonusAmount = UserDefaults.standard.object(forKey: bonusAmountKey) as? Int ?? 200
        self.bonusRemaining = UserDefaults.standard.integer(forKey: bonusRemainingKey)
        ensureBonusGranted()

        // 已解锁项
        if let arr = UserDefaults.standard.array(forKey: unlockedKeysKey) as? [String] {
            self.unlockedKeys = Set(arr)
        }
    }

    // MARK: - 每日重置（服务器日期驱动）
    func checkResetWithServerDate(_ serverDate: String) {
        let lastServerDate = UserDefaults.standard.string(forKey: lastServerDateKey) ?? ""
        if lastServerDate != serverDate {
            dailyCount = 0
            UserDefaults.standard.set(0, forKey: countKey)
            UserDefaults.standard.set(serverDate, forKey: lastServerDateKey)
            UserDefaults.standard.set(Date(), forKey: dateKey)
            // 清空今日已解锁项（新的一天重新扣点）
            unlockedKeys = []
            persistUnlocked()
            print("UsageManager: 依据服务器日期 [\(serverDate)] 重置计数与解锁记录")
        } else {
            print("UsageManager: 服务器日期未变，维持计数: \(dailyCount)，赠送余额: \(bonusRemaining)")
        }
    }

    // MARK: - 赠送点数
    private func ensureBonusGranted() {
        let granted = UserDefaults.standard.bool(forKey: bonusGrantedKey)
        if !granted {
            bonusRemaining = configuredBonusAmount
            UserDefaults.standard.set(bonusRemaining, forKey: bonusRemainingKey)
            UserDefaults.standard.set(true, forKey: bonusGrantedKey)
            print("UsageManager: 首次启动，一次性赠送 \(bonusRemaining) 点")
        }
    }

    // 服务器下发赠送额度（仅影响尚未发放过的设备）
    func updateBonus(_ amount: Int) {
        configuredBonusAmount = amount
        UserDefaults.standard.set(amount, forKey: bonusAmountKey)
        ensureBonusGranted()
    }

    // MARK: - 配置更新
    func updateLimit(_ limit: Int) { self.maxFreeLimit = limit }

    func updateCosts(_ costs: [String: Int]) {
        // 合并，保证新加的 open_history 等默认项不会被服务器缺失覆盖丢失
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

    // MARK: - 查询
    /// 计算某动作/条目的扣点数
    func cost(for action: UsageAction, itemKey: String?) -> Int {
        // 分组级别的独立扣点覆盖（仅对板块类动作生效）
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

    private func unlockKey(_ action: UsageAction, _ itemKey: String?) -> String {
        if let k = itemKey, !k.isEmpty { return "\(action.rawValue)|\(k.uppercased())" }
        return action.rawValue
    }

    // MARK: - 扣点 + 记录解锁
    func commitDeduction(action: UsageAction, itemKey: String?) {
        let cost = cost(for: action, itemKey: itemKey)
        if cost > 0 { deductPoints(cost) }
        markUnlocked(action: action, itemKey: itemKey)
        print("UsageManager: 扣点 [\(action.rawValue)] key=\(itemKey ?? "-") cost=\(cost) 剩余=\(remainingTotal)")
    }

    func markUnlocked(action: UsageAction, itemKey: String?) {
        unlockedKeys.insert(unlockKey(action, itemKey))
        persistUnlocked()
    }

    private func deductPoints(_ cost: Int) {
        var remaining = cost
        // 优先消耗赠送点数
        if bonusRemaining > 0 {
            let useBonus = min(bonusRemaining, remaining)
            bonusRemaining -= useBonus
            remaining -= useBonus
            UserDefaults.standard.set(bonusRemaining, forKey: bonusRemainingKey)
        }
        // 剩余从每日额度扣
        if remaining > 0 {
            dailyCount += remaining
            UserDefaults.standard.set(dailyCount, forKey: countKey)
            UserDefaults.standard.set(Date(), forKey: dateKey)
        }
    }

    private func persistUnlocked() {
        UserDefaults.standard.set(Array(unlockedKeys), forKey: unlockedKeysKey)
    }
}