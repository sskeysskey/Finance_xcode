import SwiftUI
import Combine

final class ReportManager {
    static let shared = ReportManager()
    private let endpoint = "\(VideoAPI.baseURL)/report"
    private let reportedKey = "GW_ReportedLinks"
    private let recentKey = "GW_RecentReportTimes"
    private let burstWindow: TimeInterval = 10
    private let burstLimit = 2
    private let perVideo: TimeInterval = 24 * 3600
    private init() {}

    func canReport(_ episodeURL: String) -> (Bool, String?) {
        let now = Date().timeIntervalSince1970
        let recent = (UserDefaults.standard.array(forKey: recentKey) as? [Double] ?? []).filter { now - $0 < burstWindow }
        if recent.count >= burstLimit, let o = recent.min() {
            return (false, T("操作过于频繁，请 \(Int(ceil(burstWindow - (now - o)))) 秒后再试",
                             "Too frequent, retry in \(Int(ceil(burstWindow - (now - o))))s"))
        }
        let map = UserDefaults.standard.dictionary(forKey: reportedKey) as? [String: Double] ?? [:]
        if let l = map[episodeURL], now - l < perVideo {
            return (false, T("你已举报过该链接，我们正在核实修复", "Already reported, we're on it"))
        }
        return (true, nil)
    }

    func submit(title: String, sourceURL: String, episodeURL: String, channel: String?,
                episode: String?, realURL: String?, type: String, note: String,
                userId: String?) async -> Result<Void, NSError> {
        let (ok, reason) = canReport(episodeURL)
        if !ok { return .failure(NSError(domain: "GW", code: 429,
                userInfo: [NSLocalizedDescriptionKey: reason ?? ""])) }
        guard let u = URL(string: endpoint) else { return .failure(NSError(domain: "GW", code: -1)) }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 15
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: [
            "user_id": userId?.isEmpty == false ? userId! : DeviceIdentity.deviceId,
            "video_title": title, "source_url": sourceURL, "episode_url": episodeURL,
            "channel_name": channel ?? "", "episode_name": episode ?? "", "real_url": realURL ?? "",
            "report_type": type, "note": note, "app_version": DeviceIdentity.appVersion])
        do {
            let (_, resp) = try await URLSession.shared.data(for: r)
            guard let h = resp as? HTTPURLResponse, h.statusCode == 200 else {
                return .failure(NSError(domain: "GW", code: 0,
                    userInfo: [NSLocalizedDescriptionKey: T("提交失败", "Submit failed")]))
            }
            let now = Date().timeIntervalSince1970
            var recent = (UserDefaults.standard.array(forKey: recentKey) as? [Double] ?? []).filter { now - $0 < burstWindow }
            recent.append(now); UserDefaults.standard.set(recent, forKey: recentKey)
            var map = UserDefaults.standard.dictionary(forKey: reportedKey) as? [String: Double] ?? [:]
            map[episodeURL] = now; UserDefaults.standard.set(map, forKey: reportedKey)
            return .success(())
        } catch {
            return .failure(error as NSError)
        }
    }
}

@MainActor
final class ReplyCenter: ObservableObject {
    static let shared = ReplyCenter()
    @Published var wishReplies: [WishReply] = []
    @Published var reportReplies: [ReportReply] = []
    private init() {}
    func refresh(userId: String?) async {
        guard let u = userId, !u.isEmpty else { return }
        wishReplies = await VideoAPI.fetchWishReplies(userId: u)
        reportReplies = await VideoAPI.fetchReportReplies(userId: u)
    }
    func ack(wish: WishReply, userId: String?) async {
        guard let u = userId else { return }
        await VideoAPI.ackWishReply(id: wish.id, userId: u)
        wishReplies.removeAll { $0.id == wish.id }
    }
    func ack(report: ReportReply, userId: String?) async {
        guard let u = userId else { return }
        await VideoAPI.ackReportReply(id: report.id, userId: u)
        reportReplies.removeAll { $0.id == report.id }
    }
}
