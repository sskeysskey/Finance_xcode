import Foundation

final class TrackingManager {
    static let shared = TrackingManager()
    private let baseURL = "http://106.15.183.158:5001/api/OVideo/track"
    
    // 引入锁，保证多线程访问内存缓存时的线程安全
    private let lock = NSRecursiveLock()
    // 内存缓存：一次启动内不重复发同一事件，减少网络请求
    private var sentInSession: Set<String> = []
    
    private init() {}
    
    enum EventType: String {
        case play              = "play"
        case downloadStart     = "download_start"
        case downloadComplete  = "download_complete"
    }
    
    /// 通用上报。失败不抛错，不影响主流程
    /// - Parameter source: 播放来源（仅在线播放传入，如 "home"/"filter"/"search"）
    func track(event: EventType,
               userId: String?,
               userType: String? = nil,
               videoURL: String,
               videoTitle: String,
               source: String? = nil) {          // 【新增】播放来源
        guard let userId = userId, !userId.isEmpty else { return }
        // 没显式传 type 时，按 "dev_" 前缀推断（与新闻模块统一）
        let resolvedType = userType ?? (userId.hasPrefix("dev_") ? "device" : "apple")
        let key = "\(userId)|\(videoURL)|\(event.rawValue)"
        
        // 线程安全地检查并写入内存缓存
        lock.lock()
        if sentInSession.contains(key) {
            lock.unlock()
            return
        }
        sentInSession.insert(key)
        lock.unlock()
        
        // 使用 Task 异步发送，不阻塞当前线程
        Task {
            await Self.send(
                userId: userId,
                userType: resolvedType,
                videoURL: videoURL,
                videoTitle: videoTitle,
                eventType: event.rawValue,
                source: source                    // 【新增】
            )
        }
    }

    private static func send(userId: String, userType: String, videoURL: String,
                             videoTitle: String, eventType: String,
                             source: String?) async {      // 【新增】
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
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""  // 【新增】
        ]
        if let source = source, !source.isEmpty {     // 【新增】仅在线播放会带 source
            body["source"] = source
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }
}