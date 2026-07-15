import SwiftUI

@MainActor
final class NewsQuotaManager: ObservableObject {
    static let shared = NewsQuotaManager()
    private init() {}

    private static let base = "http://106.15.183.158:5001/api/ONews"
    
    // 与 FreeQuotaManager 保持一致的用户 ID 解析（新闻各处复用）
    static func currentUserId(auth: AuthManager) -> String {
        return FreeQuotaManager.currentUserId(auth: auth)
    }

    @Published var dailyQuota: Int = 0
    @Published var remaining: Int = 0
    @Published var bonusRemaining: Int = 0
    @Published var dailyRemaining: Int = 0
    @Published private(set) var unlockedNewsKeys: Set<String> = []
    @Published var pendingBonusWelcome: Int = 0

    @Published var inviteCode: String = ""
    @Published var inviteRewardCount: Int = 0
    @Published var hasRedeemedInvite: Bool = false
    @Published var inviteRewardPoints: Int = 28
    @Published var loggedIn: Bool = false

    func isNewsUnlocked(_ key: String) -> Bool { unlockedNewsKeys.contains(key) }
    func clearBonusWelcome() { pendingBonusWelcome = 0 }

    func refresh(userId: String) async {
        guard let enc = userId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(Self.base)/quota/status?user_id=\(enc)") else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let resp = try JSONDecoder().decode(FreeQuotaManager.QuotaStatus.self, from: data)
            self.dailyQuota      = resp.daily_quota
            self.dailyRemaining  = resp.daily_remaining ?? resp.remaining
            self.bonusRemaining  = resp.bonus_remaining ?? 0
            self.remaining       = resp.total_remaining ?? resp.remaining
            self.unlockedNewsKeys = Set(resp.unlocked_news ?? [])
            self.inviteCode      = resp.invite_code ?? ""
            self.inviteRewardCount = resp.invite_reward_count ?? 0
            self.hasRedeemedInvite = resp.has_redeemed_invite ?? false
            self.inviteRewardPoints = resp.invite_reward_points ?? self.inviteRewardPoints
            self.loggedIn        = resp.logged_in ?? true
            if (resp.bonus_just_granted ?? false), (resp.bonus_remaining ?? 0) > 0 {
                self.pendingBonusWelcome = resp.bonus_remaining ?? 0
            }
        } catch { }
    }

    enum NewsUnlockResult { case success, alreadyUnlocked, quotaExceeded, failed(String) }

    func unlockNews(userId: String, articleKey: String, topic: String) async -> NewsUnlockResult {
        guard let url = URL(string: "\(Self.base)/quota/unlock") else { return .failed("地址无效") }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.timeoutInterval = 12
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "user_id": userId, "article_key": articleKey, "article_topic": topic])
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let resp = try JSONDecoder().decode(FreeQuotaManager.UnlockResponse.self, from: data)
            func apply() {
                self.remaining      = resp.total_remaining ?? resp.remaining
                self.bonusRemaining = resp.bonus_remaining ?? self.bonusRemaining
                self.dailyRemaining = resp.daily_remaining ?? self.dailyRemaining
            }
            switch resp.status {
            case "success":          unlockedNewsKeys.insert(articleKey); apply(); return .success
            case "already_unlocked": unlockedNewsKeys.insert(articleKey); apply(); return .alreadyUnlocked
            case "quota_exceeded":   remaining=0; bonusRemaining=0; dailyRemaining=0; return .quotaExceeded
            default: return .failed("未知状态")
            }
        } catch { return .failed(error.localizedDescription) }
    }

    func redeemInvite(userId: String, code: String) async throws -> Int {
        guard let url = URL(string: "\(Self.base)/invite/redeem") else { throw URLError(.badURL) }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.timeoutInterval = 15
        req.httpBody = try JSONSerialization.data(withJSONObject: ["user_id": userId, "invite_code": code])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode != 200 {
            if let obj = try? JSONDecoder().decode([String: String].self, from: data), let msg = obj["error"] {
                throw NSError(domain: "Invite", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
            }
            throw URLError(.badServerResponse)
        }
        struct R: Codable { let reward_points: Int?; let bonus_remaining: Int?; let remaining_total: Int? }
        let r = try JSONDecoder().decode(R.self, from: data)
        if let b = r.bonus_remaining { self.bonusRemaining = b }
        if let t = r.remaining_total { self.remaining = t }
        return r.reward_points ?? 0
    }
}
