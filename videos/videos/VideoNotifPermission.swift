import SwiftUI
import UserNotifications

extension Notification.Name {
    static let notificationPermissionGranted = Notification.Name("notificationPermissionGranted")
}

/// 只保留视频类互动事件
enum NotifEngageEvent {
    case videoLineSwitch      // 切线路（准备播放，不打扰）
    case videoEpisodeTap      // 点选剧集（权重高，不打扰）
    case videoHomeReturn      // 返回视频首页（可弹）
    case videoDetailReturn    // 返回详情页（可弹）

    var weight: Int {
        switch self {
        case .videoEpisodeTap: return 2
        default: return 1
        }
    }
    var allowsPrompt: Bool {
        switch self {
        case .videoHomeReturn, .videoDetailReturn: return true
        default: return false
        }
    }
}

@MainActor
final class NotificationPermissionManager: ObservableObject {
    static let shared = NotificationPermissionManager()

    @Published var showPreAsk = false
    @Published private(set) var status: UNAuthorizationStatus = .notDetermined

    var isSuppressed = false        // 播放器等临时场景
    var isGlobalBlocked = false     // 首启引导 / 强更 / 迁移

    private let d = UserDefaults.standard
    private let kAskCount  = "notifPreAskCount"
    private let kLastAskAt = "notifPreAskLastAt"
    private let kScore     = "notifEngageScore"
    private let kThreshold = "notifEngageThreshold"

    private let maxAskCount = 3
    private let cooldown: TimeInterval = 3 * 24 * 3600
    private let firstThreshold = 3
    private let thresholdStep = 8
    private var lastAttemptAt: Date?

    private init() {}

    func refreshStatus() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func suppress(_ on: Bool) { isSuppressed = on }
    func setGlobalBlocked(_ on: Bool) { isGlobalBlocked = on }

    private var askCount: Int { d.integer(forKey: kAskCount) }
    private var lastAskAt: Date? { d.object(forKey: kLastAskAt) as? Date }
    private var score: Int { d.integer(forKey: kScore) }
    private var threshold: Int { let t = d.integer(forKey: kThreshold); return t <= 0 ? firstThreshold : t }

    func record(_ event: NotifEngageEvent) {
        // 「免登录订阅」引导优先级更高，让它先弹
        if event.allowsPrompt, AnonymousSubscribePromptManager.shared.hasPending {
            AnonymousSubscribePromptManager.shared.flushIfNeeded()
            return
        }
        guard status == .notDetermined else { return }
        d.set(score + event.weight, forKey: kScore)
        guard event.allowsPrompt else { return }
        attemptPrompt(after: 0.8)
    }

    func attemptPrompt(after delay: TimeInterval = 0) {
        guard canPrompt else { return }
        if let l = lastAttemptAt, Date().timeIntervalSince(l) < 5 { return }
        lastAttemptAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.canPrompt else { return }
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
        if let l = lastAskAt, Date().timeIntervalSince(l) < cooldown { return false }

        let c = VideoPointsCoordinator.shared
        if c.showInsufficientSheet || c.showConfirmSheet || c.showErrorSheet
            || c.showVideoInviteSheet || c.showSubscriptionSheet
            || c.showVideoLoginPrompt { return false }
        if SeriesTrackManager.shared.showSheet { return false }
        if AnonymousSubscribePromptManager.shared.showSheet { return false }
        return true
    }

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

    func decline() { showPreAsk = false }
}

// MARK: - Soft-Ask UI
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
                Circle().fill(LinearGradient(colors: [.pink, .purple],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 70, height: 70)
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 30, weight: .bold)).foregroundColor(.white)
            }
            .padding(.top, 22)
            .shadow(color: .pink.opacity(0.3), radius: 10, y: 5)

            Text(isEnglish ? "Never miss a new episode?" : "剧集更新第一时间知道？")
                .font(.system(size: 21, weight: .heavy)).padding(.top, 16)

            Text(isEnglish
                 ? "Turn on notifications and we'll ping you the moment your show updates."
                 : "开启提醒，你在追的剧一更新就通知你，不再错过。")
                .font(.footnote).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32).padding(.top, 6)

            VStack(alignment: .leading, spacing: 14) {
                row("play.rectangle.fill", .pink,
                    isEnglish ? "New episodes" : "追剧更新提醒",
                    isEnglish ? "Know the second your show updates" : "你在追的剧一更新就知道")
                row("sparkles", .orange,
                    isEnglish ? "New arrivals" : "新片入库提醒",
                    isEnglish ? "Fresh titles every day" : "每天都有新内容上线")
                row("bubble.left.and.bubble.right.fill", .blue,
                    isEnglish ? "Support replies" : "客服回复提醒",
                    isEnglish ? "Get notified when we reply" : "寻片/报错有回复立刻知道")
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemGroupedBackground)))
            .padding(.horizontal, 20).padding(.top, 20)

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
                    Text(isEnglish ? "Turn On Notifications" : "开启提醒").fontWeight(.bold)
                }
                .font(.system(size: 16)).foregroundColor(.white)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(LinearGradient(colors: [.pink, .purple],
                                           startPoint: .leading, endPoint: .trailing))
                .cornerRadius(26)
            }
            .disabled(isRequesting).padding(.horizontal, 24)

            Button {
                manager.showPreAsk = false
                dismiss()
            } label: {
                Text(isEnglish ? "Maybe later" : "以后再说")
                    .font(.subheadline).foregroundColor(.secondary).padding(.vertical, 12)
            }
            .padding(.bottom, 12)
        }
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        .presentationDetents([.height(560), .large])
        .presentationDragIndicator(.hidden)
    }

    private func row(_ icon: String, _ c: Color, _ t: String, _ s: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 14, weight: .bold))
                .foregroundColor(.white).frame(width: 28, height: 28)
                .background(Circle().fill(c))
            VStack(alignment: .leading, spacing: 2) {
                Text(t).font(.system(size: 14, weight: .semibold))
                Text(s).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
        }
    }
}
