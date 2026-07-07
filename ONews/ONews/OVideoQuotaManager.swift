import SwiftUI

@MainActor
final class FreeQuotaManager: ObservableObject {
    static let shared = FreeQuotaManager()
    private init() {}
    
    private var lastSyncDay: String = ""   // 上次成功同步的北京日期

    // 读取时即校验：今天没成功同步过，本地解锁状态一律不可信
    func isUnlocked(_ episodeKey: String) -> Bool {
        guard lastSyncDay == Self.localDayString() else { return false }
        return unlockedKeys.contains(episodeKey)
    }

    private static func localDayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: Date())
    }

    @Published var dailyQuota: Int = 0
    @Published var remaining: Int = 0            // ⭐ 现在表示「总剩余」= 赠送 + 每日（门禁用它）
    @Published var bonusRemaining: Int = 0       // ⭐ 新人一次性赠送剩余
    @Published var dailyRemaining: Int = 0       // ⭐ 今日免费剩余
    @Published private(set) var unlockedKeys: Set<String> = []
    // ⭐ 新人礼包刚发放（>0 表示需要弹一次欢迎提示）
    @Published var pendingBonusWelcome: Int = 0

    /// 与打点完全一致的用户身份
    static func currentUserId(auth: AuthManager) -> String {
        if let appleId = auth.userIdentifier, !appleId.isEmpty { return appleId }
        if let idfv = UIDevice.current.identifierForVendor?.uuidString { return "dev_" + idfv }
        return "guest_user"
    }

    // ⭐ 文案助手：清晰展示剩余点数构成
    func remainingSummary(english: Bool) -> String {
        if bonusRemaining > 0 && dailyRemaining > 0 {
            return english
                ? "\(bonusRemaining) welcome + \(dailyRemaining) daily passes left"
                : "新人赠送剩 \(bonusRemaining) 点 + 今日免费 \(dailyRemaining) 点"
        } else if bonusRemaining > 0 {
            return english
                ? "\(bonusRemaining) welcome passes left"
                : "新人赠送还剩 \(bonusRemaining) 点"
        } else {
            return english
                ? "\(dailyRemaining) daily passes left"
                : "今日免费还剩 \(dailyRemaining) 点"
        }
    }

    // ⭐ 本次消耗来自哪个池的文案（赠送优先）
    func consumeSourceNote(english: Bool) -> String {
        if bonusRemaining > 0 {
            return english
                ? "This will use 1 welcome pass (used first)."
                : "本次将消耗 1 点"
        } else {
            return english
                ? "This will use 1 daily free pass."
                : "本次将消耗 1 点今日免费点数"
        }
    }

    func clearBonusWelcome() { pendingBonusWelcome = 0 }

    /// 拉取今日配额
    func refresh(userId: String) async {
        let todayLocal = Self.localDayString()
        guard let enc = userId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(OVideoAPI.baseURL)/quota/status?user_id=\(enc)") else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let resp = try JSONDecoder().decode(QuotaStatus.self, from: data)
            self.dailyQuota     = resp.daily_quota
            self.dailyRemaining = resp.daily_remaining ?? resp.remaining
            self.bonusRemaining = resp.bonus_remaining ?? 0
            self.remaining      = resp.total_remaining ?? resp.remaining
            self.unlockedKeys   = Set(resp.unlocked_episodes)
            self.lastSyncDay    = todayLocal
            if (resp.bonus_just_granted ?? false), (resp.bonus_remaining ?? 0) > 0 {
                self.pendingBonusWelcome = resp.bonus_remaining ?? 0
            }
        } catch {
            if lastSyncDay != todayLocal {
                self.unlockedKeys = []
                self.remaining = 0
                self.bonusRemaining = 0
                self.dailyRemaining = 0
            }
        }
    }

    enum UnlockResult {
        case success(remaining: Int)
        case alreadyUnlocked
        case quotaExceeded
        case failed(String)
    }

    func unlock(userId: String, episodeKey: String, videoTitle: String) async -> UnlockResult {
        guard let url = URL(string: "\(OVideoAPI.baseURL)/quota/unlock") else { return .failed("地址无效") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 12
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "user_id": userId, "episode_key": episodeKey, "video_title": videoTitle
        ])
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let resp = try JSONDecoder().decode(UnlockResponse.self, from: data)

            func applyCounts() {
                self.remaining      = resp.total_remaining ?? resp.remaining
                self.bonusRemaining = resp.bonus_remaining ?? self.bonusRemaining
                self.dailyRemaining = resp.daily_remaining ?? self.dailyRemaining
            }

            switch resp.status {
            case "success":
                unlockedKeys.insert(episodeKey); applyCounts()
                lastSyncDay = Self.localDayString()
                return .success(remaining: resp.total_remaining ?? resp.remaining)
            case "already_unlocked":
                unlockedKeys.insert(episodeKey); applyCounts()
                lastSyncDay = Self.localDayString()
                return .alreadyUnlocked
            case "quota_exceeded":
                remaining = 0; bonusRemaining = 0; dailyRemaining = 0
                return .quotaExceeded
            default:
                return .failed("未知状态")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    struct QuotaStatus: Codable {
        let daily_quota: Int
        let used_today: Int
        let remaining: Int
        let unlocked_episodes: [String]
        let bonus_remaining: Int?
        let daily_remaining: Int?
        let total_remaining: Int?
        let bonus_just_granted: Bool?
    }
    struct UnlockResponse: Codable {
        let status: String
        let remaining: Int
        let bonus_remaining: Int?
        let daily_remaining: Int?
        let total_remaining: Int?
    }
}

// MARK: - 统一门禁决策
enum VideoAccessDecision {
    case allowed
    case needLogin
    case needConsume(remaining: Int)
    case exhausted
}

@MainActor
func decideVideoAccess(episodeKey: String,
                       auth: AuthManager,
                       quota: FreeQuotaManager) -> VideoAccessDecision {
    if auth.isSubscribed { return .allowed }
    if quota.isUnlocked(episodeKey) { return .allowed }
    // 未登录不享受免费点数，必须先登录拿到 Apple ID
    if !auth.isLoggedIn { return .needLogin }
    if quota.remaining > 0 { return .needConsume(remaining: quota.remaining) }
    return .exhausted
}