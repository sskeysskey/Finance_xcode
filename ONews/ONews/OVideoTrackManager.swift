import Foundation

final class TrackingManager {
    static let shared = TrackingManager()
    private let baseURL = "http://106.15.183.158:5001/api/OVideo/track"

    private let lock = NSRecursiveLock()
    private var sentInSession: Set<String> = []

    private init() {}

    enum EventType: String {
        case play              = "play"
        case downloadStart     = "download_start"
        case downloadComplete  = "download_complete"
    }

    /// 通用上报。失败不抛错，不影响主流程
    /// - Parameters:
    ///   - source: 播放来源（仅在线播放传入，如 "home"/"filter"/"search"）
    ///   - episodeKey: 【新增】本集的解锁 key（与 FreeQuotaManager.unlock 用的一致），
    ///                 传了服务端就能细分「赠送点数 / 每日免费点数」
    ///   - accessType: 【新增】权限来源；不传则自动推断
    func track(event: EventType,
               userId: String?,
               userType: String? = nil,
               videoURL: String,
               videoTitle: String,
               source: String? = nil,
               episodeKey: String? = nil,
               accessType: String? = nil) {
        guard let userId = userId, !userId.isEmpty else { return }
        let resolvedType = userType ?? (userId.hasPrefix("dev_") ? "device" : "apple")
        let key = "\(userId)|\(videoURL)|\(event.rawValue)"

        lock.lock()
        if sentInSession.contains(key) {
            lock.unlock()
            return
        }
        sentInSession.insert(key)
        lock.unlock()

        Task {
            // 【需求3】权限来源：优先用调用方传入，否则自动推断（避免在 ?? 自动闭包中 await）
            let access: String
            if let accessType = accessType {
                access = accessType
            } else {
                access = await Self.resolveAccessType(episodeKey: episodeKey)
            }

            await Self.send(
                userId: userId,
                userType: resolvedType,
                videoURL: videoURL,
                videoTitle: videoTitle,
                eventType: event.rawValue,
                source: source,
                episodeKey: episodeKey,
                accessType: access
            )
        }
    }

    /// 【新增】自动推断这次播放是"订阅看"还是"点数看"
    @MainActor
    private static func resolveAccessType(episodeKey: String?) -> String {
        let auth = AuthManager.shared
        if auth.isPermanentVIP { return "vip_permanent" }
        if auth.isSubscribed   { return "subscription" }
        // 未订阅：视频模块必须先解锁(扣点)才能播放
        if let k = episodeKey, FreeQuotaManager.shared.isUnlocked(k) { return "points" }
        return auth.isLoggedIn ? "points" : "free"
    }

    private static func send(userId: String, userType: String, videoURL: String,
                             videoTitle: String, eventType: String,
                             source: String?, episodeKey: String?,
                             accessType: String) async {
        guard let url = URL(string: "http://106.15.183.158:5001/api/OVideo/track") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        var body: [String: Any] = [
            "user_id": userId,
            "user_type": userType,
            "video_url": videoURL,
            "video_title": videoTitle,
            "event_type": eventType,
            "access_type": accessType,          // 【新增】
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        ]
        if let source = source, !source.isEmpty { body["source"] = source }
        if let ek = episodeKey, !ek.isEmpty { body["episode_key"] = ek }   // 【新增】

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }
}