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

// MARK: - 举报 / 反馈修复
/// ⭐ Swift 不支持 \.0 这种元组 KeyPath，改成结构体
private struct ReportKind: Identifiable, Hashable {
    let id: String
    let zh: String
    let en: String
}

private let gwReportKinds: [ReportKind] = [
    .init(id: "playback_failed",  zh: "无法播放",       en: "Can't play"),
    .init(id: "download_failed",  zh: "无法下载",       en: "Can't download"),
    .init(id: "media_error",      zh: "画面或声音异常", en: "Audio/Video issue"),
    .init(id: "content_mismatch", zh: "内容与简介不符", en: "Wrong content"),
    .init(id: "other",            zh: "其他问题",       en: "Other")
]

struct ReportSheet: View {
    let title: String
    let sourceURL: String
    let episodeURL: String
    let channel: String?
    let episode: String?
    let realURL: String?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var lang: LanguageManager
    @State private var type = "playback_failed"
    @State private var note = ""
    @State private var working = false
    @State private var result: String?
    @State private var ok = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(lang.t("反馈修复", "Report an issue")).font(.headline)
            Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(2)

            Picker(lang.t("问题类型", "Issue"), selection: $type) {
                ForEach(gwReportKinds) { k in
                    Text(lang.t(k.zh, k.en)).tag(k.id)
                }
            }

            // ⭐ 用 TextEditor 代替 TextField(axis:)，彻底避开重载歧义
            VStack(alignment: .leading, spacing: 4) {
                Text(lang.t("补充说明（选填）", "Note (optional)"))
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $note)
                    .font(.body)
                    .frame(height: 68)
                    .padding(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            }

            if let r = result {
                Text(r).font(.caption).foregroundStyle(ok ? .green : .orange)
            }

            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button(lang.t("关闭", "Close")) { dismiss() }
                Button(lang.t("提交", "Submit")) { Task { await submit() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || ok)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func submit() async {
        working = true; result = nil
        let r = await ReportManager.shared.submit(
            title: title, sourceURL: sourceURL, episodeURL: episodeURL,
            channel: channel, episode: episode, realURL: realURL,
            type: type, note: note, userId: auth.userIdentifier)
        working = false
        switch r {
        case .success:
            ok = true
            result = lang.t("已收到，我们会尽快核实修复", "Received, we'll fix it soon")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { dismiss() }
        case .failure(let e):
            ok = false
            result = e.localizedDescription
        }
    }
}
