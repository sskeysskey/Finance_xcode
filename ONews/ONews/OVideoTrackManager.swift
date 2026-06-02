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
    
    /// 通用上报。失败不抛错，不影响主流程 (移除了 category 字段)
    func track(event: EventType,
               userId: String?,
               userType: String? = nil,          // 【新增】
               videoURL: String,
               videoTitle: String) {
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
                userType: resolvedType,           // 【新增】
                videoURL: videoURL,
                videoTitle: videoTitle,
                eventType: event.rawValue
            )
        }
    }

    private static func send(userId: String, userType: String, videoURL: String,
                             videoTitle: String, eventType: String) async {
        guard let url = URL(string: "http://106.15.183.158:5001/api/OVideo/track") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        
        // 移除了 "category" 键值对
        let body: [String: Any] = [
            "user_id": userId,
            "user_type": userType,                // 【新增】
            "video_url": videoURL,
            "video_title": videoTitle,
            "event_type": eventType
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }
}