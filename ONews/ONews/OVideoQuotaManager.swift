import SwiftUI

@MainActor
final class FreeQuotaManager: ObservableObject {
    static let shared = FreeQuotaManager()
    private init() {}

    private static let onewsBase = "http://106.15.183.158:5001/api/ONews"

    private var lastSyncDay: String = ""   // 上次成功同步的北京日期

    @Published var dailyQuota: Int = 0
    @Published var remaining: Int = 0            // 总剩余（赠送 + 每日）
    @Published var bonusRemaining: Int = 0
    @Published var dailyRemaining: Int = 0
    @Published private(set) var unlockedKeys: Set<String> = []       // 视频（当天）
    @Published var pendingBonusWelcome: Int = 0

    // 邀请
    @Published var inviteCode: String = ""
    @Published var inviteRewardCount: Int = 0
    @Published var hasRedeemedInvite: Bool = false
    @Published var inviteRewardPoints: Int = 18
    @Published var loggedIn: Bool = false

    static func currentUserId(auth: AuthManager) -> String {
        if let appleId = auth.userIdentifier, !appleId.isEmpty { return appleId }
        if let idfv = UIDevice.current.identifierForVendor?.uuidString { return "dev_" + idfv }
        return "guest_user"
    }

    // 新闻文章的稳定 key
    static func newsKey(_ article: Article) -> String {
        return "\(article.timestamp)|\(article.source_id ?? "na")|\(article.topic)"
    }

    private static func localDayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: Date())
    }

    // 视频：当天同步过才可信
    func isUnlocked(_ episodeKey: String) -> Bool {
        guard lastSyncDay == Self.localDayString() else { return false }
        return unlockedKeys.contains(episodeKey)
    }

    func remainingSummary(english: Bool) -> String {
        if bonusRemaining > 0 && dailyRemaining > 0 {
            return english
                ? "\(bonusRemaining) welcome + \(dailyRemaining) daily passes left"
                : "赠送剩 \(bonusRemaining) 点 + 今日免费 \(dailyRemaining) 点"
        } else if bonusRemaining > 0 {
            return english ? "\(bonusRemaining) welcome passes left" : "还剩 \(bonusRemaining) 点"
        } else {
            return english ? "\(dailyRemaining) daily passes left" : "还剩 \(dailyRemaining) 点"
        }
    }

    func consumeSourceNote(english: Bool) -> String {
        if bonusRemaining > 0 {
            return english ? "This will use 1 welcome pass (used first)." : "本次将消耗 1 点"
        } else {
            return english ? "This will use 1 daily free pass." : "本次将消耗 1 点"
        }
    }

    func clearBonusWelcome() { pendingBonusWelcome = 0 }

    // MARK: - 同步
    func refresh(userId: String) async {
        let todayLocal = Self.localDayString()
        guard let enc = userId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(OVideoAPI.baseURL)/quota/status?user_id=\(enc)") else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let resp = try JSONDecoder().decode(QuotaStatus.self, from: data)
            self.dailyQuota      = resp.daily_quota
            self.dailyRemaining  = resp.daily_remaining ?? resp.remaining
            self.bonusRemaining  = resp.bonus_remaining ?? 0
            self.remaining       = resp.total_remaining ?? resp.remaining
            self.unlockedKeys    = Set(resp.unlocked_episodes)
            self.inviteCode      = resp.invite_code ?? ""
            self.inviteRewardCount = resp.invite_reward_count ?? 0
            self.hasRedeemedInvite = resp.has_redeemed_invite ?? false
            self.inviteRewardPoints = resp.invite_reward_points ?? self.inviteRewardPoints
            self.loggedIn        = resp.logged_in ?? true
            self.lastSyncDay     = todayLocal
            if (resp.bonus_just_granted ?? false), (resp.bonus_remaining ?? 0) > 0 {
                self.pendingBonusWelcome = resp.bonus_remaining ?? 0
            }
        } catch {
            if lastSyncDay != todayLocal {
                self.unlockedKeys = []; self.remaining = 0
                self.bonusRemaining = 0; self.dailyRemaining = 0
            }
        }
    }

    // MARK: - 视频解锁
    enum UnlockResult {
        case success(remaining: Int)
        case alreadyUnlocked
        case quotaExceeded
        case failed(String)
    }

    func unlock(userId: String, episodeKey: String, videoTitle: String) async -> UnlockResult {
        guard let url = URL(string: "\(OVideoAPI.baseURL)/quota/unlock") else { return .failed("地址无效") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 12
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "user_id": userId, "episode_key": episodeKey, "video_title": videoTitle
        ])
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let resp = try JSONDecoder().decode(UnlockResponse.self, from: data)
            func apply() {
                self.remaining      = resp.total_remaining ?? resp.remaining
                self.bonusRemaining = resp.bonus_remaining ?? self.bonusRemaining
                self.dailyRemaining = resp.daily_remaining ?? self.dailyRemaining
            }
            switch resp.status {
            case "success":
                unlockedKeys.insert(episodeKey); apply(); lastSyncDay = Self.localDayString()
                return .success(remaining: resp.total_remaining ?? resp.remaining)
            case "already_unlocked":
                unlockedKeys.insert(episodeKey); apply(); lastSyncDay = Self.localDayString()
                return .alreadyUnlocked
            case "quota_exceeded":
                remaining = 0; bonusRemaining = 0; dailyRemaining = 0
                return .quotaExceeded
            default: return .failed("未知状态")
            }
        } catch { return .failed(error.localizedDescription) }
    }

    // MARK: - 新闻解锁（永久）
    enum NewsUnlockResult { case success, alreadyUnlocked, quotaExceeded, failed(String) }

    // MARK: - 邀请码兑换
    func redeemInvite(userId: String, code: String) async throws -> Int {
        guard let url = URL(string: "\(OVideoAPI.baseURL)/invite/redeem") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try JSONSerialization.data(withJSONObject: ["user_id": userId, "invite_code": code])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode != 200 {
            if let obj = try? JSONDecoder().decode([String: String].self, from: data),
               let msg = obj["error"] {
                throw NSError(domain: "Invite", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: msg])
            }
            throw URLError(.badServerResponse)
        }
        struct R: Codable { let reward_points: Int?; let bonus_remaining: Int?; let remaining_total: Int? }
        let r = try JSONDecoder().decode(R.self, from: data)
        if let b = r.bonus_remaining { self.bonusRemaining = b }
        if let t = r.remaining_total { self.remaining = t }
        return r.reward_points ?? 0
    }

    struct QuotaStatus: Codable {
        let daily_quota: Int
        let used_today: Int
        let remaining: Int
        let unlocked_episodes: [String]
        let unlocked_news: [String]?
        let bonus_remaining: Int?
        let daily_remaining: Int?
        let total_remaining: Int?
        let bonus_just_granted: Bool?
        let invite_code: String?
        let invite_reward_count: Int?
        let has_redeemed_invite: Bool?
        let invite_reward_points: Int?
        let logged_in: Bool?
    }
    struct UnlockResponse: Codable {
        let status: String
        let remaining: Int
        let bonus_remaining: Int?
        let daily_remaining: Int?
        let total_remaining: Int?
    }
}

// MARK: - 视频统一门禁决策（保持原有视频逻辑不变）
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
    if !auth.isLoggedIn { return .needLogin }
    if quota.remaining > 0 { return .needConsume(remaining: quota.remaining) }
    return .exhausted
}