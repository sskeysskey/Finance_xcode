import SwiftUI
import Combine

// 【修改】定义用户行为类型
enum UsageAction: String {
    case viewChart = "view_chart"           // 查看图表详情 (点击 Symbol)
    case openSector = "open_sector"         // 打开板块分组 (Indices 标题)
    case search = "search_with_results"     // 搜索 (仅当有结果时)
    case openEarnings = "open_earnings"     // 打开财报入口
    case openList = "open_list"             // 打开榜单 (Gainers/Losers/High/Low)
    case compare = "compare_execution"      // 【新增】执行比较 (点击开始比较按钮)
}

@MainActor
class UsageManager: ObservableObject {
    static let shared = UsageManager()
    
    @Published var dailyCount: Int = 0
    @Published var maxFreeLimit: Int = 5
    
    // 【新增】默认扣点配置 (如果服务器没返回，用这个兜底)
    @Published var actionCosts: [String: Int] = [
        UsageAction.viewChart.rawValue: 1,
        UsageAction.openSector.rawValue: 1,
        UsageAction.search.rawValue: 1,
        UsageAction.openEarnings.rawValue: 1,
        UsageAction.openList.rawValue: 1,
        UsageAction.compare.rawValue: 1     // 【新增】默认比较扣1点
    ]
    
    private let countKey = "FinanceDailyUsageCount"
    private let dateKey = "FinanceLastUsageDate"
    // 【新增】持久化存储配置的 Key
    private let costConfigKey = "FinanceCostConfig"
    
    private init() {
        checkReset()
        loadLocalCosts() // 初始化时加载本地缓存的配置
    }
    
    // 检查是否需要重置计数（新的一天）
    private func checkReset() {
        let lastDate = UserDefaults.standard.object(forKey: dateKey) as? Date ?? Date.distantPast
        if !Calendar.current.isDateInToday(lastDate) {
            // 是新的一天，重置
            dailyCount = 0
            UserDefaults.standard.set(0, forKey: countKey)
            UserDefaults.standard.set(Date(), forKey: dateKey)
        } else {
            // 是今天，加载计数
            dailyCount = UserDefaults.standard.integer(forKey: countKey)
        }
    }
    
    // 更新最大限制（从 UpdateManager 调用）
    func updateLimit(_ limit: Int) {
        self.maxFreeLimit = limit
    }
    
    // 【新增】更新扣点配置
    func updateCosts(_ costs: [String: Int]) {
        self.actionCosts = costs
        // 持久化存储，以便下次冷启动时使用
        if let data = try? JSONEncoder().encode(costs) {
            UserDefaults.standard.set(data, forKey: costConfigKey)
        }
    }
    
    // 【新增】加载本地缓存的配置
    private func loadLocalCosts() {
        if let data = UserDefaults.standard.data(forKey: costConfigKey),
           let cachedCosts = try? JSONDecoder().decode([String: Int].self, from: data) {
            self.actionCosts = cachedCosts
        }
    }
    
    // 【修改】核心方法：尝试执行操作
    // 参数 action: 指定要执行的行为，用于计算扣点
    // 参数 performDeduction: 是否立即扣除 (用于搜索这种需要先检查再执行的场景)
    func canProceed(authManager: AuthManager, action: UsageAction, performDeduction: Bool = true) -> Bool {
        // 1. 如果已订阅，无限制
        if authManager.isSubscribed {
            return true
        }
        
        // 2. 检查并重置日期
        checkReset()
        
        // 获取该行为的扣点数 (默认为 1)
        let cost = actionCosts[action.rawValue] ?? 1
        
        // 如果 cost 为 0，直接允许，不走扣费逻辑
        if cost == 0 { return true }
        
        if dailyCount + cost <= maxFreeLimit {
            if performDeduction {
                dailyCount += cost
                UserDefaults.standard.set(dailyCount, forKey: countKey)
                UserDefaults.standard.set(Date(), forKey: dateKey)
                print("UsageManager: 操作允许 [\(action.rawValue)]。扣除: \(cost), 今日已用: \(dailyCount)/\(maxFreeLimit)")
            }
            return true
        } else {
            print("UsageManager: 操作拦截 [\(action.rawValue)]。需要: \(cost), 剩余: \(maxFreeLimit - dailyCount)")
            return false
        }
    }
    
    // 手动扣除方法
    func deduct(action: UsageAction) {
        if let cost = actionCosts[action.rawValue], cost > 0 {
            checkReset()
            dailyCount += cost
            UserDefaults.standard.set(dailyCount, forKey: countKey)
            UserDefaults.standard.set(Date(), forKey: dateKey)
            print("UsageManager: 手动扣除 [\(action.rawValue)]。扣除: \(cost), 今日已用: \(dailyCount)/\(maxFreeLimit)")
        }
    }
}