import SwiftUI
import AppKit

@main
struct GWVideoApp: App {
    @StateObject private var lang = LanguageManager.shared
    @StateObject private var auth = AuthManager.shared
    @StateObject private var data = VideoDataManager()
    @StateObject private var config = AppConfigManager.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                if config.showForceUpdate { ForceUpdateView(storeURL: config.storeURL) }
            }
            .environmentObject(lang)
            .environmentObject(auth)
            .environmentObject(data)
            .onAppear { NSWindow.allowsAutomaticWindowTabbing = false }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 820)
        .commands { AppCommands() }

        // 独立播放窗口
        WindowGroup(id: "player", for: PlayPayload.self) { $payload in
            if let payload {
                PlayerWindowView(payload: payload)
                    .environmentObject(lang)
                    .environmentObject(auth)
            }
        }
        .defaultSize(width: 1120, height: 660)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView().environmentObject(lang).environmentObject(auth)
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var app = AppState.shared
    @ObservedObject var lang = LanguageManager.shared
    var body: some Commands {
        CommandGroup(replacing: .newItem) { }
        CommandMenu(lang.t("浏览", "Browse")) {
            Button(lang.t("搜索", "Search")) { app.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
            Button(lang.t("分类检索", "Filter")) { app.go(.filter) }
                .keyboardShortcut("l", modifiers: .command)
            Divider()
            Button(lang.t("追剧提醒", "Following")) { app.go(.follow) }
                .keyboardShortcut("1", modifiers: [.command, .shift])
            Button(lang.t("下载管理", "Downloads")) { app.go(.downloads) }
                .keyboardShortcut("2", modifiers: [.command, .shift])
            Button(lang.t("观看记录", "History")) { app.go(.history) }
                .keyboardShortcut("3", modifiers: [.command, .shift])
            Divider()
            Button(lang.t("刷新", "Refresh")) {
                Task { await AppConfigManager.shared.refresh() }
            }.keyboardShortcut("r", modifiers: [.command, .shift])
        }
        CommandGroup(after: .appInfo) {
            Button(lang.t("会员与点数…", "Membership & Points…")) { app.showSubscription = true }
        }
        CommandGroup(replacing: .help) {
            Link(lang.t("问题反馈", "Send Feedback"),
                 destination: URL(string: "mailto:728308386@qq.com")!)
        }
    }
}

struct ForceUpdateView: View {
    let storeURL: String
    @EnvironmentObject var lang: LanguageManager
    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.85)).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 60)).foregroundStyle(.blue)
                Text(lang.t("需要更新", "Update Required")).font(.title.bold()).foregroundStyle(.white)
                Text(lang.t("当前版本已停止服务，请更新后继续使用。",
                            "This version is no longer supported."))
                    .foregroundStyle(.secondary)
                Button(lang.t("前往 App Store", "Open App Store")) {
                    if let u = URL(string: storeURL.isEmpty ? "macappstore://apps.apple.com" : storeURL) {
                        NSWorkspace.shared.open(u)
                    }
                }.buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
    }
}

/// 跨 macOS 13 / 14 / 15 的 onChange 替代品：
/// 不使用 macOS 14 已弃用的 onChange(of:perform:)，也不使用 macOS 14 才有的双参数 onChange。
struct GWChangeObserver<V: Equatable>: ViewModifier {
    let value: V
    let action: (V) -> Void
    @State private var last: V?

    func body(content: Content) -> some View {
        content.task(id: value) {
            if let l = last, l != value { action(value) }
            last = value
        }
    }
}

extension View {
    /// 用法与旧的 .onChange(of:) { newValue in } 完全一致
    func onChangeCompat<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        modifier(GWChangeObserver(value: value, action: action))
    }
}