import SwiftUI
import Combine

@MainActor
final class QuotaManager: ObservableObject {
    static let shared = QuotaManager()
    private init() {}

    @Published var dailyQuota = 0
    @Published var remaining = 0
    @Published var bonusRemaining = 0
    @Published var dailyRemaining = 0
    @Published private(set) var unlockedKeys: Set<String> = []
    @Published var pendingBonusWelcome = 0
    @Published var inviteCode = ""
    @Published var inviteRewardCount = 0
    @Published var hasRedeemedInvite = false
    @Published var inviteRewardPoints = 20
    @Published var loggedIn = false

    private var lastSyncDay = ""

    static func currentUserId(auth: AuthManager) -> String {
        if let a = auth.userIdentifier, !a.isEmpty { return a }
        return DeviceIdentity.deviceId
    }
    private static func today() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai"); return f.string(from: Date())
    }

    func isUnlocked(_ key: String) -> Bool {
        lastSyncDay == Self.today() && unlockedKeys.contains(key)
    }
    func remainingSummary(_ en: Bool) -> String {
        if bonusRemaining > 0 && dailyRemaining > 0 {
            return en ? "\(bonusRemaining) welcome + \(dailyRemaining) daily left"
                      : "赠送剩 \(bonusRemaining) 点 + 今日免费 \(dailyRemaining) 点"
        } else if bonusRemaining > 0 {
            return en ? "\(bonusRemaining) welcome passes left" : "还剩 \(bonusRemaining) 点"
        }
        return en ? "\(dailyRemaining) daily passes left" : "还剩 \(dailyRemaining) 点"
    }
    func consumeNote(_ en: Bool) -> String { en ? "This will use 1 pass." : "本次将消耗 1 点" }
    func clearBonusWelcome() { pendingBonusWelcome = 0 }

    struct Status: Codable {
        let daily_quota: Int, used_today: Int, remaining: Int
        let unlocked_episodes: [String]
        let bonus_remaining: Int?, daily_remaining: Int?, total_remaining: Int?
        let bonus_just_granted: Bool?
        let invite_code: String?, invite_reward_count: Int?
        let has_redeemed_invite: Bool?, invite_reward_points: Int?, logged_in: Bool?
    }

    func refresh(userId: String) async {
        let today = Self.today()
        guard let e = userId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let u = URL(string: "\(VideoAPI.baseURL)/quota/status?user_id=\(e)") else { return }
        var r = URLRequest(url: u); r.timeoutInterval = 12
        do {
            let (d, _) = try await URLSession.shared.data(for: r)
            let s = try JSONDecoder().decode(Status.self, from: d)
            dailyQuota = s.daily_quota
            dailyRemaining = s.daily_remaining ?? s.remaining
            bonusRemaining = s.bonus_remaining ?? 0
            remaining = s.total_remaining ?? s.remaining
            unlockedKeys = Set(s.unlocked_episodes)
            inviteCode = s.invite_code ?? ""
            inviteRewardCount = s.invite_reward_count ?? 0
            hasRedeemedInvite = s.has_redeemed_invite ?? false
            inviteRewardPoints = s.invite_reward_points ?? inviteRewardPoints
            loggedIn = s.logged_in ?? true
            lastSyncDay = today
            if (s.bonus_just_granted ?? false), (s.bonus_remaining ?? 0) > 0 {
                pendingBonusWelcome = s.bonus_remaining ?? 0
            }
        } catch {
            if lastSyncDay != today {
                unlockedKeys = []; remaining = 0; bonusRemaining = 0; dailyRemaining = 0
            }
        }
    }

    enum UnlockResult { case success, alreadyUnlocked, quotaExceeded, failed(String) }

    func unlock(userId: String, episodeKey: String, title: String) async -> UnlockResult {
        guard let u = URL(string: "\(VideoAPI.baseURL)/quota/unlock") else { return .failed("bad url") }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 12
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject:
            ["user_id": userId, "episode_key": episodeKey, "video_title": title])
        struct R: Codable { let status: String; let remaining: Int
                            let bonus_remaining: Int?; let daily_remaining: Int?; let total_remaining: Int? }
        do {
            let (d, _) = try await URLSession.shared.data(for: r)
            let x = try JSONDecoder().decode(R.self, from: d)
            func apply() {
                remaining = x.total_remaining ?? x.remaining
                bonusRemaining = x.bonus_remaining ?? bonusRemaining
                dailyRemaining = x.daily_remaining ?? dailyRemaining
            }
            switch x.status {
            case "success":          unlockedKeys.insert(episodeKey); apply(); lastSyncDay = Self.today(); return .success
            case "already_unlocked": unlockedKeys.insert(episodeKey); apply(); lastSyncDay = Self.today(); return .alreadyUnlocked
            case "quota_exceeded":   remaining = 0; bonusRemaining = 0; dailyRemaining = 0; return .quotaExceeded
            default: return .failed("unknown")
            }
        } catch { return .failed(error.localizedDescription) }
    }

    func redeemInvite(userId: String, code: String) async throws -> Int {
        guard let u = URL(string: "\(VideoAPI.baseURL)/invite/redeem") else { throw URLError(.badURL) }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 15
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["user_id": userId, "invite_code": code])
        let (d, resp) = try await URLSession.shared.data(for: r)
        guard let h = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if h.statusCode != 200 {
            if let o = try? JSONDecoder().decode([String: String].self, from: d), let m = o["error"] {
                throw NSError(domain: "GW", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: m])
            }
            throw URLError(.badServerResponse)
        }
        struct R: Codable { let reward_points: Int?; let bonus_remaining: Int?; let remaining_total: Int? }
        let x = try JSONDecoder().decode(R.self, from: d)
        if let b = x.bonus_remaining { bonusRemaining = b }
        if let t = x.remaining_total { remaining = t }
        return x.reward_points ?? 0
    }
}

enum VideoAccess { case allowed, needLogin, needConsume(Int), exhausted }

@MainActor
func decideAccess(episodeKey: String, auth: AuthManager, quota: QuotaManager) -> VideoAccess {
    if auth.isSubscribed { return .allowed }
    if quota.isUnlocked(episodeKey) { return .allowed }
    if HLSDownloadManager.shared.localURL(forEpisodeKey: episodeKey) != nil { return .allowed }
    if !auth.isLoggedIn { return .needLogin }
    if quota.remaining > 0 { return .needConsume(quota.remaining) }
    return .exhausted
}