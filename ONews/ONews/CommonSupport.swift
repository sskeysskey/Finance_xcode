//  CommonSupport.swift
//  统一放：锁定天数计算规则 + 通知授权（Soft-Ask）管理器 + 预弹窗 UI

import SwiftUI
import UserNotifications

// MARK: - ============ 1. 统一的「锁定天数」计算规则 ============
/// 【核心修复 1】原实现用 UTC 解析 yyMMdd，却用 Calendar.current（设备时区）算天差，
///   在 UTC+8 会整体偏移，导致 locked_days=2 实际锁 3 天；不同设备时区表现还不一致。
/// 【核心修复 2】基准日期只依赖 server_date / 本地缓存，一旦缓存过期（比如很久没联网），
///   gap 会算成负数 → 全部保守锁定；现在额外把「本地已下载新闻中的最新日期」也纳入候选，
///   三者取最大值，得到一个设备无关、且永远不落后的"今天"代理。
enum NewsLockRule {

    static let kLastServerDate  = "LastKnownServerDate"
    static let kNewestLocalDate = "NewestLocalArticleDate"

    static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    static let parser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyMMdd"
        f.locale = Locale(identifier: "en_US_POSIX")   // 防止某些地区历法/数字影响解析
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()

    static func date(from timestamp: String) -> Date? {
        parser.date(from: timestamp)
    }

    /// 文章日期距参考日期的自然日差：同一天 = 0，昨天 = 1，前天 = 2 …（未来日期为负）
    static func dayGap(article: String, reference: String) -> Int? {
        guard let a = date(from: article), let r = date(from: reference) else { return nil }
        return utcCalendar.dateComponents([.day], from: a, to: r).day
    }

    /// 【新增】每次 loadNews 后记录本地最新一天，作为设备无关的"今天"代理
    static func noteNewestLocalArticleDate(_ timestamp: String?) {
        guard let t = timestamp, let d = date(from: t) else { return }
        if let old = UserDefaults.standard.string(forKey: kNewestLocalDate),
           let od = date(from: old), od >= d { return }
        UserDefaults.standard.set(t, forKey: kNewestLocalDate)
    }

    /// 参考日期：server_date / 上次缓存 / 本地最新新闻日期 —— 三者取「最新的那个」
    static func referenceDate(_ serverDate: String?) -> String? {
        var candidates: [String] = []
        if let s = serverDate, !s.isEmpty { candidates.append(s) }
        if let c = UserDefaults.standard.string(forKey: kLastServerDate), !c.isEmpty { candidates.append(c) }
        if let n = UserDefaults.standard.string(forKey: kNewestLocalDate), !n.isEmpty { candidates.append(n) }

        let valid = candidates.compactMap { ts -> (ts: String, d: Date)? in
            guard let d = date(from: ts) else { return nil }
            return (ts, d)
        }
        return valid.max(by: { $0.d < $1.d })?.ts
    }

    /// 唯一判定入口：全 App 只能用这一个函数判断「某天是否受限」
    /// locked_days = 2 → 只锁 gap 0、1 两天（今天 + 昨天）
    static func isLocked(timestamp: String, lockedDays: Int, serverDate: String?) -> Bool {
        guard lockedDays > 0 else { return false }
        guard let ref = referenceDate(serverDate),
              let gap = dayGap(article: timestamp, reference: ref) else {
            return true                    // 拿不到基准，保守锁定
        }
        return gap < lockedDays             // 负数（把设备时间调到未来）同样锁定
    }

    #if DEBUG
    /// 排查用：一行打印判定过程
    static func debugDescribe(timestamp: String, lockedDays: Int, serverDate: String?) -> String {
        let ref = referenceDate(serverDate) ?? "nil"
        let gap = dayGap(article: timestamp, reference: ref).map(String.init) ?? "nil"
        let locked = isLocked(timestamp: timestamp, lockedDays: lockedDays, serverDate: serverDate)
        return "🔒 ts=\(timestamp) ref=\(ref) gap=\(gap) lockedDays=\(lockedDays) → \(locked ? "LOCKED" : "free")"
    }
    #endif
}

// MARK: - ============ 2. 通知授权 Soft-Ask 管理器 ============

extension Notification.Name {
    static let notificationPermissionGranted = Notification.Name("notificationPermissionGranted")
}

/// 互动事件：weight = 互动权重；allowsPrompt = 是否允许在该时刻弹预弹窗
enum NotifEngageEvent {
    case newsOpenArticle        // 打开一篇新闻（阅读中不打扰）
    case newsNextArticle        // 点击「阅读下一篇」（完成时刻，可弹）
    case newsListReturn         // 从详情返回列表（可弹）
    case newsHomeReturn         // 返回新闻大首页（可弹）
    case videoLineSwitch        // 切换线路（准备播放，不打扰）
    case videoEpisodeTap        // 点选剧集（不打扰，但权重高）
    case videoHomeReturn        // 返回视频首页（可弹）

    var weight: Int {
        switch self {
        case .videoEpisodeTap: return 2
        case .newsNextArticle: return 2
        default: return 1
        }
    }
    var allowsPrompt: Bool {
        switch self {
        case .newsNextArticle, .newsListReturn, .newsHomeReturn, .videoHomeReturn: return true
        default: return false
        }
    }
}

@MainActor
final class NotificationPermissionManager: ObservableObject {
    static let shared = NotificationPermissionManager()

    @Published var showPreAsk = false
    @Published private(set) var status: UNAuthorizationStatus = .notDetermined

    /// 【临时屏蔽】全屏播放器 / 播放页等场景，期间绝不打扰
    var isSuppressed = false
    /// 【长期屏蔽】首启引导 / 强制更新 / 迁移弹窗期间，绝不打扰
    var isGlobalBlocked = false

    private let d = UserDefaults.standard
    private let kAskCount   = "notifPreAskCount"
    private let kLastAskAt  = "notifPreAskLastAt"
    private let kScore      = "notifEngageScore"
    private let kThreshold  = "notifEngageThreshold"

    private let maxAskCount = 3                        // 最多骚扰 3 次
    private let cooldown: TimeInterval = 3 * 24 * 3600 // 被拒后冷静 3 天
    private let firstThreshold = 3                     // 首次门槛：累计 3 分互动
    private let thresholdStep  = 8                     // 每次被拒后门槛递增

    /// 同一次会话里，两次「尝试弹窗」的最小间隔，避免连续返回导致抖动
    private var lastAttemptAt: Date?

    private init() {}

    // MARK: 状态
    func refreshStatus() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        self.status = s.authorizationStatus
    }

    /// 播放器等临时场景
    func suppress(_ on: Bool) { isSuppressed = on }
    /// 引导 / 强更 / 迁移等长期场景
    func setGlobalBlocked(_ on: Bool) { isGlobalBlocked = on }

    private var askCount: Int { d.integer(forKey: kAskCount) }
    private var lastAskAt: Date? { d.object(forKey: kLastAskAt) as? Date }
    private var score: Int { d.integer(forKey: kScore) }
    private var threshold: Int {
        let t = d.integer(forKey: kThreshold)
        return t <= 0 ? firstThreshold : t
    }

    // MARK: 记录互动
    func record(_ event: NotifEngageEvent) {
        // 已授权 / 已拒绝（系统层）就不用再累加了
        guard status == .notDetermined else { return }
        d.set(score + event.weight, forKey: kScore)
        guard event.allowsPrompt else { return }
        // 稍作延迟，等转场动画/列表刷新完成，体验更顺
        attemptPrompt(after: 0.8)
    }

    /// 主动尝试（例如从播放器返回后）
    func attemptPrompt(after delay: TimeInterval = 0.0) {
        guard canPrompt else { return }
        if let last = lastAttemptAt, Date().timeIntervalSince(last) < 5 { return }
        lastAttemptAt = Date()

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.canPrompt else { return }
            // 计入一次「已打扰」：即便用户直接下滑关闭，也走退避
            self.d.set(self.askCount + 1, forKey: self.kAskCount)
            self.d.set(Date(), forKey: self.kLastAskAt)
            self.d.set(self.threshold + self.thresholdStep, forKey: self.kThreshold)
            withAnimation { self.showPreAsk = true }
        }
    }

    private var canPrompt: Bool {
        if showPreAsk || isSuppressed || isGlobalBlocked { return false }
        if status != .notDetermined { return false }
        if askCount >= maxAskCount { return false }
        if score < threshold { return false }
        if let last = lastAskAt, Date().timeIntervalSince(last) < cooldown { return false }

        // 避免和点数/订阅/邀请等弹窗撞车
        let pc = NewsPointsCoordinator.shared
        if pc.showInviteSheet || pc.showLoginSheet
            || pc.showSubscriptionSheet || pc.showVideoInviteSheet
            || pc.showInsufficientSheet || pc.showConfirmSheet
            || pc.showVideoLoginPrompt { return false }

        // 【新增】避免和「追剧更新」弹窗撞车
        if SeriesTrackManager.shared.showSheet { return false }

        return true
    }

    // MARK: 用户操作
    /// 点「开启提醒」→ 调起系统弹窗
    @discardableResult
    func accept() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshStatus()
        if granted {
            NotificationCenter.default.post(name: .notificationPermissionGranted, object: nil)
        }
        return granted
    }

    /// 点「以后再说」
    func decline() {
        showPreAsk = false
    }
}

// MARK: - ============ 3. 预弹窗 UI（Soft-Ask） ============
struct NotificationPreAskView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("isGlobalEnglishMode") private var isEnglish = false
    @ObservedObject private var manager = NotificationPermissionManager.shared
    @State private var isRequesting = false

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.secondary.opacity(0.3))
                .frame(width: 40, height: 5).padding(.top, 10)

            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.blue, .purple],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 70, height: 70)
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.white)
            }
            .padding(.top, 22)
            .shadow(color: .blue.opacity(0.3), radius: 10, y: 5)

            Text(isEnglish ? "Never miss an update?" : "第一时间收到更新提醒？")
                .font(.system(size: 21, weight: .heavy))
                .padding(.top, 16)

            Text(isEnglish
                 ? "Turn on notifications and we'll ping you the moment fresh content lands."
                 : "开启提醒，内容更新的第一时间就通知你，不再错过。")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 14) {
                row("newspaper.fill", .blue,
                    isEnglish ? "Daily headlines" : "每日新闻上线提醒",
                    isEnglish ? "Global newsrooms, every morning" : "全球一线新闻源，每天清早送达")
                row("play.rectangle.fill", .pink,
                    isEnglish ? "New episodes" : "追剧更新提醒",
                    isEnglish ? "Know the second your show updates" : "你在追的剧一更新就知道")
                row("app.badge.fill", .orange,
                    isEnglish ? "Unread badge" : "未读角标",
                    isEnglish ? "See unread count on the icon" : "图标上直接显示未读数量")
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemGroupedBackground)))
            .padding(.horizontal, 20)
            .padding(.top, 20)

            Spacer(minLength: 12)

            Button {
                isRequesting = true
                Task {
                    await manager.accept()
                    isRequesting = false
                    manager.showPreAsk = false
                    dismiss()
                }
            } label: {
                HStack {
                    if isRequesting { ProgressView().tint(.white) }
                    Text(isEnglish ? "Turn On Notifications" : "开启提醒")
                        .fontWeight(.bold)
                }
                .font(.system(size: 16))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(LinearGradient(colors: [.blue, .purple],
                                           startPoint: .leading, endPoint: .trailing))
                .cornerRadius(26)
            }
            .disabled(isRequesting)
            .padding(.horizontal, 24)

            Button {
                manager.showPreAsk = false
                dismiss()
            } label: {
                Text(isEnglish ? "Maybe later" : "以后再说")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 12)
            }
            .padding(.bottom, 12)
        }
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        .presentationDetents([.height(560), .large])
        .presentationDragIndicator(.hidden)
    }

    private func row(_ icon: String, _ color: Color, _ title: String, _ sub: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(color))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(sub).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
        }
    }
}