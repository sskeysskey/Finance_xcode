// /Users/yanzhang/Coding/Xcode/ONews/ONews/OVideoReportManager.swift

import SwiftUI

// MARK: - 举报管理器(含限流)
final class VideoReportManager {
    static let shared = VideoReportManager()
    private let endpoint = "http://106.15.183.158:5001/api/OVideo/report"

    private let reportedKey = "ONews_ReportedLinks"        // [episodeURL: timestamp]
    private let recentReportsKey = "ONews_RecentReportTimes" // 最近提交时间戳数组(滑动窗口)

    private let burstWindow: TimeInterval = 10             // ⭐ 滑动窗口 10 秒
    private let burstLimit = 2                             // ⭐ 窗口内最多 2 次（可连续举报两个坏链接）
    private let perVideoInterval: TimeInterval = 24 * 3600 // 同一链接 24h 内只能举报一次

    private init() {}

    enum ReportResultError: Error {
        case rateLimited(String)
        case network(String)
        var message: String {
            switch self {
            case .rateLimited(let m): return m
            case .network(let m):     return m
            }
        }
    }

    /// 提交前的本地限流检查
    func canReport(episodeURL: String) -> (ok: Bool, reason: String?) {
        let now = Date().timeIntervalSince1970

        // ⭐ 滑动窗口限流：burstWindow 秒内最多 burstLimit 次
        let recent = (UserDefaults.standard.array(forKey: recentReportsKey) as? [Double] ?? [])
            .filter { now - $0 < burstWindow }
        if recent.count >= burstLimit, let oldest = recent.min() {
            let wait = max(1, Int(ceil(burstWindow - (now - oldest))))
            return (false, "操作过于频繁，请 \(wait) 秒后再试")
        }

        // 同一链接 24h 内只能举报一次
        let reported = UserDefaults.standard.dictionary(forKey: reportedKey) as? [String: Double] ?? [:]
        if let last = reported[episodeURL], now - last < perVideoInterval {
            return (false, "你已举报过该链接，我们正在核实修复中")
        }
        return (true, nil)
    }

    func submitReport(videoTitle: String,
                      sourceURL: String,
                      episodeURL: String,
                      channelName: String?,
                      episodeName: String?,
                      realURL: String?,
                      reportType: String,
                      note: String,
                      userId: String?) async -> Result<Void, ReportResultError> {

        let check = canReport(episodeURL: episodeURL)
        if !check.ok { return .failure(.rateLimited(check.reason ?? "操作过于频繁")) }

        guard let url = URL(string: endpoint) else { return .failure(.network("地址无效")) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15

        let body: [String: Any] = [
            "user_id":      (userId?.isEmpty == false ? userId! : "guest_user"),
            "video_title":  videoTitle,
            "source_url":   sourceURL,
            "episode_url":  episodeURL,
            "channel_name": channelName ?? "",
            "episode_name": episodeName ?? "",
            "real_url":     realURL ?? "",
            "report_type":  reportType,
            "note":         note,
            "app_version":  Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .failure(.network("无响应")) }
            if http.statusCode == 200 {
                let now = Date().timeIntervalSince1970

                // ⭐ 记录到滑动窗口（只保留窗口内的时间戳）
                var recent = (UserDefaults.standard.array(forKey: recentReportsKey) as? [Double] ?? [])
                    .filter { now - $0 < burstWindow }
                recent.append(now)
                UserDefaults.standard.set(recent, forKey: recentReportsKey)

                // 记录该链接的举报时间
                var reported = UserDefaults.standard.dictionary(forKey: reportedKey) as? [String: Double] ?? [:]
                reported[episodeURL] = now
                UserDefaults.standard.set(reported, forKey: reportedKey)
                return .success(())
            } else if http.statusCode == 429 {
                return .failure(.rateLimited("操作过于频繁，请稍后再试"))
            } else {
                return .failure(.network("提交失败 (\(http.statusCode))"))
            }
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}

// MARK: - 入口卡片(高端样式)
struct ReportLinkCard: View {
    let videoTitle: String
    let sourceURL: String     // 影片页 url(唯一键);若没有就传 episodeURL
    let episodeURL: String    // 当前播放/缓存的播放页 url
    var channelName: String? = nil   // playlist 名,如「天堂」
    var episodeName: String? = nil   // 集数 key,如「HD国语」/「第01集」
    var realURL: String? = nil       // 已解析的 m3u8(可选)

    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color.orange.opacity(0.95), Color.red.opacity(0.7)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 30, height: 30)
                    Image(systemName: "exclamationmark.bubble.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(isGlobalEnglishMode ? "Report a broken link" : "提交修复错误链接")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.primary)
                    Spacer()
                    Text(isGlobalEnglishMode
                         ? "Can't play or cache? Let us know."
                         : "无法播放或缓存？点此反馈，我们会尽快修复")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.orange.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.orange.opacity(0.22), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.horizontal, 16)
        .sheet(isPresented: $showSheet) {
            ReportSheet(videoTitle: videoTitle,
                        sourceURL: sourceURL,
                        episodeURL: episodeURL,
                        channelName: channelName,
                        episodeName: episodeName,
                        realURL: realURL)
        }
    }
}

// MARK: - 举报弹窗
struct ReportSheet: View {
    let videoTitle: String
    let sourceURL: String
    let episodeURL: String
    let channelName: String?
    let episodeName: String?
    let realURL: String?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var authManager: AuthManager
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    @State private var selectedType: ReportType = .playbackFailed
    @State private var note: String = ""
    @State private var isSubmitting = false
    @State private var resultMessage: String? = nil
    @State private var isSuccess = false

    enum ReportType: String, CaseIterable, Identifiable {
        case playbackFailed  = "playback_failed"
        case downloadFailed  = "download_failed"
        case mediaError      = "media_error"
        case contentMismatch = "content_mismatch"
        case other           = "other"
        var id: String { rawValue }

        func title(_ en: Bool) -> String {
            switch self {
            case .playbackFailed:  return en ? "Can't play"        : "无法播放"
            case .downloadFailed:  return en ? "Can't cache"       : "无法缓存/下载"
            case .mediaError:      return en ? "Audio/Video issue" : "画面或声音异常"
            case .contentMismatch: return en ? "Wrong content"     : "内容与简介不符"
            case .other:           return en ? "Other"             : "其他问题"
            }
        }
        var icon: String {
            switch self {
            case .playbackFailed:  return "play.slash.fill"
            case .downloadFailed:  return "arrow.down.circle.dotted"
            case .mediaError:      return "waveform.slash"
            case .contentMismatch: return "rectangle.badge.xmark"
            case .other:           return "ellipsis.circle"
            }
        }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    infoSummary
                    typeSelector
                    noteField

                    if let msg = resultMessage {
                        HStack(spacing: 8) {
                            Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(isSuccess ? .green : .orange)
                            Text(msg).font(.system(size: 13))
                                .foregroundColor(isSuccess ? .green : .orange)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill((isSuccess ? Color.green : Color.orange).opacity(0.1))
                        )
                    }
                    submitButton
                }
                .padding(16)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isGlobalEnglishMode ? "Close" : "关闭") { dismiss() }
                }
            }
        }
    }

    private var infoSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(videoTitle)
                .font(.system(size: 16, weight: .bold))
                .lineLimit(2)
            if let c = channelName, let e = episodeName, !c.isEmpty || !e.isEmpty {
                Text("\(c) · \(e)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))
    }

    private var typeSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isGlobalEnglishMode ? "What's wrong?" : "遇到了什么问题？")
                .font(.system(size: 14, weight: .semibold))
            VStack(spacing: 8) {
                ForEach(ReportType.allCases) { type in
                    Button {
                        selectedType = type
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: type.icon)
                                .font(.system(size: 15))
                                .foregroundColor(selectedType == type ? .white : .accentColor)
                                .frame(width: 28, height: 28)
                                .background(
                                    Circle().fill(selectedType == type
                                                  ? Color.accentColor
                                                  : Color.accentColor.opacity(0.12))
                                )
                            Text(type.title(isGlobalEnglishMode))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.primary)
                            Spacer()
                            if selectedType == type {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(selectedType == type
                                      ? Color.accentColor.opacity(0.08)
                                      : Color.primary.opacity(0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(selectedType == type
                                        ? Color.accentColor.opacity(0.4)
                                        : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isGlobalEnglishMode ? "Note (optional)" : "补充说明（选填）")
                .font(.system(size: 14, weight: .semibold))
            TextField(isGlobalEnglishMode ? "Describe the issue..." : "简单描述一下问题…",
                      text: $note, axis: .vertical)
                .lineLimit(3...5)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
        }
    }

    private var submitButton: some View {
        Button {
            submit()
        } label: {
            HStack {
                if isSubmitting { ProgressView().tint(.white) }
                Text(isSuccess
                     ? (isGlobalEnglishMode ? "Submitted" : "已提交")
                     : (isGlobalEnglishMode ? "Submit Report" : "提交修复"))
                    .font(.system(size: 15, weight: .bold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                LinearGradient(colors: isSuccess ? [Color.green, Color.green.opacity(0.7)]
                                                  : [Color.orange, Color.red.opacity(0.85)],
                               startPoint: .leading, endPoint: .trailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(isSubmitting || isSuccess)
    }

    private func submit() {
        let check = VideoReportManager.shared.canReport(episodeURL: episodeURL)
        guard check.ok else {
            isSuccess = false
            resultMessage = check.reason
            return
        }
        isSubmitting = true
        resultMessage = nil
        Task {
            let result = await VideoReportManager.shared.submitReport(
                videoTitle: videoTitle,
                sourceURL: sourceURL,
                episodeURL: episodeURL,
                channelName: channelName,
                episodeName: episodeName,
                realURL: realURL,
                reportType: selectedType.rawValue,
                note: note,
                userId: authManager.userIdentifier
            )
            await MainActor.run {
                isSubmitting = false
                switch result {
                case .success:
                    isSuccess = true
                    resultMessage = isGlobalEnglishMode
                        ? "Thanks! We've received your report."
                        : "感谢反馈，我们已收到并会尽快核实修复"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dismiss() }
                case .failure(let err):
                    isSuccess = false
                    resultMessage = err.message
                }
            }
        }
    }
}