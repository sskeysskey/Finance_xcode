import SwiftUI
import UIKit
import UserNotifications

/// 端标识：后台统计用它区分「原 ONews 内的视频模块」/「独立 iPhone 视频 App」/「Mac 视频 App」
enum OVideoClient {
    static let id = "ios_ovideo"          // ONews 里请改成 "ios_onews"；Mac 端建议 "mac_ovideo"
    static let appName = "OVideo"
}

extension Color {
    static let viewBackground = Color(UIColor.systemGroupedBackground)
    static let cardBackground = Color(UIColor.secondarySystemGroupedBackground)
}

final class AppDelegate: NSObject, UIApplicationDelegate {

    // 播放器全屏依赖它
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }

    // 后台下载回调
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        print("✨ [AppDelegate] 后台下载事件: \(identifier)")
        HLSDownloadManager.shared.backgroundCompletionHandler = completionHandler
    }

    let authManager      = AuthManager.shared
    let resourceManager  = ResourceManager()
    let videoDataManager = OVideoDataManager()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {

        initializeLanguagePreference()

        Task { @MainActor in
            await NotificationPermissionManager.shared.refreshStatus()
            await StorePriceStore.shared.load()
        }

        // 预热：先拿配置（决定审核年份），再拉分类 + 第一页
        Task(priority: .userInitiated) { @MainActor in
            await resourceManager.refreshServerConfig(minInterval: 0,
                                                      userId: authManager.userIdentifier)
            videoDataManager.reviewMaxYear = resourceManager.effectiveReviewVideoMaxYear

            let uid = authManager.userIdentifier
            await videoDataManager.bootstrap(userId: uid)

            let idx = UserDefaults.standard.integer(forKey: "OVideo_SelectedCategoryIndex")
            let sortRaw = UserDefaults.standard.string(forKey: "OVideo_SortOption")
                ?? VideoSortOption.date.rawValue
            let sort = VideoSortOption(rawValue: sortRaw) ?? .date
            let names = videoDataManager.categoryNames
            if idx >= 0, idx < names.count {
                await videoDataManager.loadFirstPageIfNeeded(category: names[idx],
                                                             sort: sort, userId: uid)
            }
            await SeriesTrackManager.shared.refresh(force: true)
            print("📺 [预加载] 视频首页已预热")
        }

        let tv = UITableView.appearance()
        tv.backgroundColor = .clear
        tv.separatorStyle = .none
        return true
    }

    private func initializeLanguagePreference() {
        let d = UserDefaults.standard
        let key = "hasInitializedLanguage"
        guard !d.bool(forKey: key) else { return }
        let pref = Locale.preferredLanguages.first ?? "en"
        d.set(!pref.hasPrefix("zh"), forKey: "isGlobalEnglishMode")
        d.set(true, forKey: key)
    }
}

@main
struct OVideoAppMain: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            VideoRootView()
                .environmentObject(appDelegate.authManager)
                .environmentObject(appDelegate.resourceManager)
                .environmentObject(appDelegate.videoDataManager)
        }
        .onChange(of: scenePhase) { phase in
            let auth = appDelegate.authManager
            let res  = appDelegate.resourceManager
            let data = appDelegate.videoDataManager

            switch phase {
            case .active:
                auth.handleAppDidBecomeActive()
                Task {
                    await NotificationPermissionManager.shared.refreshStatus()
                    await FreeQuotaManager.shared.refresh(
                        userId: FreeQuotaManager.currentUserId(auth: auth))
                    await SeriesTrackManager.shared.refresh(force: true)
                    await res.refreshServerConfig(minInterval: 60, userId: auth.userIdentifier)
                    data.reviewMaxYear = res.effectiveReviewVideoMaxYear
                    await data.silentRefreshCurrentSelection(userId: auth.userIdentifier,
                                                             minInterval: 30)
                    await WishReplyManager.shared.refresh(userId: auth.userIdentifier)
                    await ReportReplyManager.shared.refresh(userId: auth.userIdentifier)
                    await SupportChatManager.shared.refresh(
                        userId: SupportIdentity.userId(appleId: auth.userIdentifier))
                }
            case .background:
                Task { @MainActor in OImageCache.shared.clearAll() }
            default: break
            }
        }
    }
}
