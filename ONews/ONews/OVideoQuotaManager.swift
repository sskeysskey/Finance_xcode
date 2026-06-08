import SwiftUI

@MainActor
final class FreeQuotaManager: ObservableObject {
    static let shared = FreeQuotaManager()
    private init() {}

    @Published var dailyQuota: Int = 0
    @Published var remaining: Int = 0
    @Published private(set) var unlockedKeys: Set<String> = []

    /// 与打点完全一致的用户身份
    static func currentUserId(auth: AuthManager) -> String {
        if let appleId = auth.userIdentifier, !appleId.isEmpty { return appleId }
        if let idfv = UIDevice.current.identifierForVendor?.uuidString { return "dev_" + idfv }
        return "guest_user"
    }

    func isUnlocked(_ episodeKey: String) -> Bool { unlockedKeys.contains(episodeKey) }

    /// 拉取今日配额（进入视频模块、App 回前台时调用）
    func refresh(userId: String) async {
        guard let enc = userId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(OVideoAPI.baseURL)/quota/status?user_id=\(enc)") else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let resp = try JSONDecoder().decode(QuotaStatus.self, from: data)
            self.dailyQuota   = resp.daily_quota
            self.remaining    = resp.remaining
            self.unlockedKeys = Set(resp.unlocked_episodes)
        } catch {
            // 离线时保留上次缓存，不清空
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
            switch resp.status {
            case "success":
                unlockedKeys.insert(episodeKey); remaining = resp.remaining
                return .success(remaining: resp.remaining)
            case "already_unlocked":
                unlockedKeys.insert(episodeKey); remaining = resp.remaining
                return .alreadyUnlocked
            case "quota_exceeded":
                remaining = 0; return .quotaExceeded
            default:
                return .failed("未知状态")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    struct QuotaStatus: Codable {
        let daily_quota: Int; let used_today: Int
        let remaining: Int;   let unlocked_episodes: [String]
    }
    struct UnlockResponse: Codable { let status: String; let remaining: Int }
}

// MARK: - 统一门禁决策
enum VideoAccessDecision {
    case allowed
    case needConsume(remaining: Int)
    case exhausted
}

@MainActor
func decideVideoAccess(episodeKey: String,
                       auth: AuthManager,
                       quota: FreeQuotaManager) -> VideoAccessDecision {
    if auth.isSubscribed { return .allowed }
    if quota.isUnlocked(episodeKey) { return .allowed }
    if quota.remaining > 0 { return .needConsume(remaining: quota.remaining) }
    return .exhausted
}