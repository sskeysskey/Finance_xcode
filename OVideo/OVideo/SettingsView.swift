import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("通用", systemImage: "gear") }
            PlaybackSettings().tabItem { Label("播放", systemImage: "play.rectangle") }
            DownloadSettings().tabItem { Label("下载", systemImage: "arrow.down.circle") }
            AccountSettings().tabItem { Label("账号", systemImage: "person.crop.circle") }
        }
        .frame(width: 520, height: 340)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var lang: LanguageManager
    @ObservedObject var config = AppConfigManager.shared
    var body: some View {
        Form {
            Toggle(lang.t("英文界面", "English UI"), isOn: $lang.isEnglish)
            LabeledContent(lang.t("内容更新时间", "Content updated"), value: config.updateTime)
            LabeledContent(lang.t("版本", "Version"), value: DeviceIdentity.appVersion)
            Button(lang.t("清理图片内存缓存", "Clear image cache")) { ImageCache.shared.clear() }
        }.padding(20).formStyle(.grouped)
    }
}

private struct PlaybackSettings: View {
    @EnvironmentObject var lang: LanguageManager
    @AppStorage("GW_AutoNext") private var autoNext = true
    @AppStorage("GW_EpAsc") private var asc = true
    var body: some View {
        Form {
            Toggle(lang.t("播完自动下一集", "Auto play next episode"), isOn: $autoNext)
            Toggle(lang.t("剧集正序排列", "Episodes ascending"), isOn: $asc)
            LabeledContent(lang.t("默认倍速", "Default speed"),
                value: String(format: "%g", SpeedStore.rate) + "x")
            Text(lang.t("播放窗口支持全屏、画中画、⌘[ / ⌘] 切换集数。",
                        "Player supports full screen, PiP and ⌘[ / ⌘] to switch episodes."))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).formStyle(.grouped)
    }
}

private struct DownloadSettings: View {
    @EnvironmentObject var lang: LanguageManager
    @ObservedObject var dm = HLSDownloadManager.shared
    @AppStorage("GW_SegConcurrency") private var seg = 6
    var body: some View {
        Form {
            Stepper(lang.t("分片并发数：\(seg)", "Segment concurrency: \(seg)"), value: $seg, in: 2...12)
            LabeledContent(lang.t("已占用空间", "Disk usage"), value: formatBytes(dm.totalDiskUsage))
            Button(lang.t("在 Finder 中打开下载目录", "Open downloads folder")) {
                NSWorkspace.shared.open(dm.storageRoot)
            }
            Text(lang.t("退出应用会暂停下载，下次启动可继续（断点续传）。",
                        "Quitting pauses downloads; they resume next launch."))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).formStyle(.grouped)
    }
}

private struct AccountSettings: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var lang: LanguageManager
    @State private var confirmDelete = false
    var body: some View {
        Form {
            if auth.isLoggedIn {
                LabeledContent("ID", value: String((auth.userIdentifier ?? "").prefix(10)) + "…")
                LabeledContent(lang.t("会员", "Membership"),
                               value: auth.isSubscribed
                                ? (auth.isPermanentVIP ? lang.t("长期有效", "Lifetime")
                                                       : (auth.subscriptionExpiryDate ?? "-"))
                                : lang.t("免费版", "Free"))
                Button(lang.t("退出登录", "Sign Out")) { auth.signOut() }
                Button(lang.t("删除账号", "Delete Account"), role: .destructive) { confirmDelete = true }
            } else {
                Button(lang.t("使用 Apple 登录", "Sign in with Apple")) { auth.signInWithApple() }
            }
            Button(lang.t("恢复购买", "Restore Purchases")) { Task { try? await auth.restorePurchases() } }
            Link(lang.t("问题反馈：728308386@qq.com", "Feedback: 728308386@qq.com"),
                 destination: URL(string: "mailto:728308386@qq.com")!)
        }
        .padding(20).formStyle(.grouped)
        .alert(lang.t("确认删除账号？", "Delete account?"), isPresented: $confirmDelete) {
            Button(lang.t("取消", "Cancel"), role: .cancel) {}
            Button(lang.t("永久删除", "Delete"), role: .destructive) {
                Task { try? await auth.deleteAccount() }
            }
        } message: {
            Text(lang.t("此操作不可恢复，您的数据与订阅记录将从服务器删除。",
                        "This cannot be undone."))
        }
    }
}