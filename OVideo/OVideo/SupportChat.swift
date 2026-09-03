//  SupportChat.swift
//  OVideo (macOS) —— 在线客服中心
//  与 iOS ONews 共用服务器接口 /api/support/*
//  ⚠️ 记得把本文件加入 OVideo 的 Target Membership

import SwiftUI
import Combine
import AppKit

// MARK: - 配置
enum SupportAppConfig {
    /// ⚠️ 必须是 "ONews"！
    /// 服务器把「寻片 / 坏链接举报」的会话统一写在 app='ONews' 下，
    /// Mac 端只有用同一个 app 名，才能看到并继续这些历史对话。
    static let appName = "ONews"
    static let baseURL = "http://106.15.183.158:5001/api/support"
    /// 让后台一眼分辨出这是 Mac 客户端
    static var clientVersion: String { "mac-\(DeviceIdentity.appVersion)" }
}

// MARK: - 用户标识（Apple ID 优先，未登录用设备号，必须与举报/寻片保持一致）
enum SupportIdentity {
    static func userId(appleId: String?) -> String {
        if let u = appleId, !u.isEmpty { return u }
        return DeviceIdentity.deviceId          // "dev_xxxxxxxx"
    }
    static func userType(_ id: String) -> String { id.hasPrefix("dev_") ? "device" : "apple" }
}

// MARK: - 模型
struct SupportThread: Codable, Hashable, Identifiable {
    let thread_key: String
    let thread_type: String            // wish / report / support
    let title: String?
    let subtitle: String?
    let status: String?                // pending / replied / resolved
    let last_sender: String?
    let last_message: String?
    let unread_user: Int?
    let updated_at: String?

    var id: String { thread_key }
    var unread: Int { unread_user ?? 0 }

    var icon: String {
        switch thread_type {
        case "wish":   return "magnifyingglass.circle.fill"
        case "report": return "exclamationmark.bubble.fill"
        default:       return "headphones.circle.fill"
        }
    }
    var tint: Color {
        switch thread_type {
        case "wish":   return .orange
        case "report": return .green
        default:       return .blue
        }
    }
    func typeName(_ en: Bool) -> String {
        switch thread_type {
        case "wish":   return en ? "Request"  : "寻片请求"
        case "report": return en ? "Bad link" : "坏链接反馈"
        default:       return en ? "Support"  : "在线咨询"
        }
    }
}

struct SupportMessage: Codable, Hashable, Identifiable {
    let id: Int
    let sender: String                 // user / admin
    let content: String
    let created_at: String?
    var isUser: Bool { sender == "user" }
}

private struct SupportThreadsResponse: Codable {
    let threads: [SupportThread]
    let unread_total: Int
}
private struct SupportMessagesResponse: Codable {
    let messages: [SupportMessage]
}

// MARK: - 管理器
@MainActor
final class SupportChatManager: ObservableObject {
    static let shared = SupportChatManager()

    @Published private(set) var threads: [SupportThread] = []
    @Published private(set) var unreadTotal = 0
    @Published var isLoading = false
    /// 外部跳转用：设置后客服页会自动选中该会话
    @Published var focusThreadKey: String?
    /// 外部跳转用：只知道类型（wish / report）时，自动挑一条最近的
    @Published var focusType: String?

    private var boundUser: String = ""
    private var poller: Task<Void, Never>?

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

    private init() {}

    var currentUserId: String {
        boundUser.isEmpty
            ? SupportIdentity.userId(appleId: AuthManager.shared.userIdentifier)
            : boundUser
    }

    /// 登录状态变化时调用（切换用户 = 切换会话空间）
    func bind(appleId: String?) {
        let uid = SupportIdentity.userId(appleId: appleId)
        guard uid != boundUser else { return }
        boundUser = uid
        threads = []
        unreadTotal = 0
        updateDockBadge()
        Task { await refresh() }
    }

    func generalThreadKey(userId: String? = nil) -> String {
        "\(SupportAppConfig.appName)|support|\(userId ?? currentUserId)"
    }

    /// 「直接问客服」的通用会话（不存在就返回一个本地占位，发第一条消息时服务器自动建）
    func generalThread(english: Bool) -> SupportThread {
        if let e = threads.first(where: { $0.thread_type == "support" }) { return e }
        return SupportThread(thread_key: generalThreadKey(),
                             thread_type: "support",
                             title: english ? "Support" : "在线咨询",
                             subtitle: nil, status: "pending",
                             last_sender: nil, last_message: nil,
                             unread_user: 0, updated_at: nil)
    }

    // MARK: 网络
    func refresh() async {
        let uid = currentUserId
        guard !uid.isEmpty,
              var c = URLComponents(string: "\(SupportAppConfig.baseURL)/threads")
        else { return }
        c.queryItems = [.init(name: "app", value: SupportAppConfig.appName),
                        .init(name: "user_id", value: uid)]
        guard let url = c.url else { return }
        do {
            let (d, _) = try await Self.session.data(from: url)
            let r = try JSONDecoder().decode(SupportThreadsResponse.self, from: d)
            threads = r.threads
            unreadTotal = r.unread_total
            updateDockBadge()
        } catch {
            // 静默失败，不打扰用户
        }
    }

    func messages(threadKey: String) async -> [SupportMessage] {
        let uid = currentUserId
        guard var c = URLComponents(string: "\(SupportAppConfig.baseURL)/messages") else { return [] }
        c.queryItems = [.init(name: "app", value: SupportAppConfig.appName),
                        .init(name: "user_id", value: uid),
                        .init(name: "thread_key", value: threadKey)]
        guard let url = c.url else { return [] }
        do {
            let (d, _) = try await Self.session.data(from: url)
            let r = try JSONDecoder().decode(SupportMessagesResponse.self, from: d)
            // 服务器在这一步已把 unread 清零，并同步把老的举报/寻片回复标记为已读
            await refresh()
            return r.messages
        } catch { return [] }
    }

    @discardableResult
    func send(content: String, threadKey: String?) async -> Bool {
        let uid = currentUserId
        guard let url = URL(string: "\(SupportAppConfig.baseURL)/send") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "app": SupportAppConfig.appName,
            "user_id": uid,
            "user_type": SupportIdentity.userType(uid),
            "content": content,
            "app_version": SupportAppConfig.clientVersion
        ]
        if let tk = threadKey { body["thread_key"] = tk }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, resp) = try await Self.session.data(for: req)
            guard let h = resp as? HTTPURLResponse, h.statusCode == 200 else { return false }
            await refresh()
            return true
        } catch { return false }
    }

    // MARK: 轮询（45 秒一次，窗口活跃时也会额外刷新）
    func startPolling() {
        guard poller == nil else { return }
        poller = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                if Task.isCancelled { break }
                await refresh()
            }
        }
    }
    func stopPolling() { poller?.cancel(); poller = nil }

    private func updateDockBadge() {
        NSApp.dockTile.badgeLabel = unreadTotal > 0 ? "\(min(unreadTotal, 99))" : nil
    }
}

// MARK: - 客服中心（左：会话列表 / 右：聊天）
struct SupportCenterView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var lang: LanguageManager
    @ObservedObject private var manager = SupportChatManager.shared
    @State private var selection: String?

    var body: some View {
        HSplitView {
            threadList
                .frame(minWidth: 250, idealWidth: 290, maxWidth: 380)
            detailPane
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(lang.t("在线客服", "Support"))
        .toolbar {
            ToolbarItemGroup {
                Button {
                    selection = manager.generalThread(english: lang.isEnglish).thread_key
                } label: {
                    Label(lang.t("新的咨询", "New"), systemImage: "plus.bubble")
                }
                Button {
                    Task { await manager.refresh() }
                } label: {
                    Label(lang.t("刷新", "Refresh"), systemImage: "arrow.clockwise")
                }
            }
        }
        .task {
            manager.bind(appleId: auth.userIdentifier)
            await manager.refresh()
            locate()
        }
        .onChangeCompat(of: manager.focusThreadKey ?? "") { _ in locate() }
        .onChangeCompat(of: manager.focusType ?? "") { _ in locate() }
    }

    /// 处理外部跳转 / 首次进入的默认选中
    private func locate() {
        if let k = manager.focusThreadKey {
            selection = k
            manager.focusThreadKey = nil
            return
        }
        if let t = manager.focusType {
            let list = manager.threads.filter { $0.thread_type == t }
            selection = (list.first(where: { $0.unread > 0 }) ?? list.first)?.thread_key
            manager.focusType = nil
            if selection != nil { return }
        }
        if selection == nil {
            selection = (manager.threads.first(where: { $0.unread > 0 }) ?? manager.threads.first)?
                .thread_key ?? manager.generalThread(english: lang.isEnglish).thread_key
        }
    }

    // MARK: 左栏
    private var threadList: some View {
        VStack(spacing: 0) {
            Button {
                selection = manager.generalThread(english: lang.isEnglish).thread_key
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus.bubble.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(
                            LinearGradient(colors: [.blue, .purple],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(lang.t("有问题？直接问客服", "Ask a new question"))
                            .font(.callout.weight(.semibold))
                        Text(lang.t("找片、播放、订阅、点数…任何问题",
                                    "Playback, subscription, points, anything."))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            Divider()

            List(selection: $selection) {
                if manager.threads.isEmpty {
                    Text(lang.t("还没有对话记录", "No conversations yet."))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                } else {
                    Section(lang.t("我的对话", "My conversations")) {
                        ForEach(manager.threads) { t in
                            row(t).tag(t.thread_key)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .background(Color.cardBG)
    }

    private func row(_ t: SupportThread) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: t.icon).font(.system(size: 20)).foregroundStyle(t.tint)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(t.typeName(lang.isEnglish))
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(t.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(t.tint)
                    Text(t.title ?? "-").font(.callout.weight(.medium)).lineLimit(1)
                }
                Text(((t.last_sender == "admin") ? lang.t("客服: ", "Support: ")
                                                 : lang.t("我: ", "You: "))
                     + (t.last_message ?? ""))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                if let u = t.updated_at {
                    Text(supportShortTime(u)).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 2)
            if t.unread > 0 {
                Text("\(t.unread)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.red, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: 右栏
    @ViewBuilder private var detailPane: some View {
        if let key = selection {
            let thread = manager.threads.first(where: { $0.thread_key == key })
                ?? manager.generalThread(english: lang.isEnglish)
            SupportThreadPane(thread: thread)
                .id(key)
        } else {
            ContentUnavailableViewCompat(
                title: lang.t("选择一个对话", "Pick a conversation"),
                message: lang.t("你提交过的「坏链接反馈」和「寻片请求」的回复，也会出现在这里。",
                                "Replies to your reports and requests appear here too."),
                systemImage: "bubble.left.and.bubble.right")
        }
    }
}

// MARK: - 聊天面板
struct SupportThreadPane: View {
    let thread: SupportThread
    @EnvironmentObject var lang: LanguageManager
    @ObservedObject private var manager = SupportChatManager.shared
    @State private var messages: [SupportMessage] = []
    @State private var draft = ""
    @State private var sending = false
    @State private var loaded = false

    private let ticker = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if !loaded {
                            ProgressView().padding(.top, 40)
                        } else if messages.isEmpty {
                            Text(lang.t("发送第一条消息开始对话", "Send your first message."))
                                .font(.callout).foregroundStyle(.secondary).padding(.top, 40)
                        }
                        ForEach(messages) { m in bubble(m).id(m.id) }
                        Color.clear.frame(height: 1).id("BOTTOM")
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChangeCompat(of: messages.count) { _ in
                    withAnimation { proxy.scrollTo("BOTTOM", anchor: .bottom) }
                }
                .task {
                    await reload()
                    proxy.scrollTo("BOTTOM", anchor: .bottom)
                }
            }
            Divider()
            composer
        }
        .background(Color.winBG)
        .onReceive(ticker) { _ in Task { await reload(silent: true) } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: thread.icon).font(.title3).foregroundStyle(thread.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.title ?? lang.t("在线咨询", "Support"))
                    .font(.headline).lineLimit(1)
                if let s = thread.subtitle, !s.isEmpty {
                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(thread.typeName(lang.isEnglish))
                .font(.caption2.bold())
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(thread.tint.opacity(0.15), in: Capsule())
                .foregroundStyle(thread.tint)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Color.cardBG)
    }

    private func bubble(_ m: SupportMessage) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            if !m.isUser {
                Image(systemName: "headphones.circle.fill")
                    .font(.title3).foregroundStyle(.blue)
            } else { Spacer(minLength: 60) }

            VStack(alignment: m.isUser ? .trailing : .leading, spacing: 3) {
                Text(m.content)
                    .font(.callout)
                    .textSelection(.enabled)
                    .foregroundStyle(m.isUser ? Color.white : Color.primary)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background {
                        if m.isUser {
                            LinearGradient(colors: [.blue, .blue.opacity(0.82)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing)
                        } else {
                            Color.cardBG
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(m.isUser ? Color.clear : Color.secondary.opacity(0.18),
                                    lineWidth: 1))
                    .frame(maxWidth: 520, alignment: m.isUser ? .trailing : .leading)
                Text(supportShortTime(m.created_at))
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }

            if m.isUser {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title3).foregroundStyle(.secondary)
            } else { Spacer(minLength: 60) }
        }
        .frame(maxWidth: .infinity, alignment: m.isUser ? .trailing : .leading)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            // ⭐ 用 TextEditor 避免 TextField(axis:) 在 macOS 13 上的重载歧义
            TextEditor(text: $draft)
                .font(.body)
                .frame(height: 62)
                .padding(6)
                .background(Color.cardBG, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1))
            VStack(spacing: 4) {
                Button {
                    Task { await sendMessage() }
                } label: {
                    if sending {
                        ProgressView().controlSize(.small).frame(width: 54)
                    } else {
                        Text(lang.t("发送", "Send")).frame(width: 54)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
                Text("⌘↩").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color.cardBG)
    }

    private var canSend: Bool {
        !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func reload(silent: Bool = false) async {
        if !silent { loaded = false }
        let list = await manager.messages(threadKey: thread.thread_key)
        // 静默刷新时避免无变化的重绘
        if !silent || list.count != messages.count { messages = list }
        loaded = true
    }

    private func sendMessage() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        draft = ""
        let ok = await manager.send(content: text, threadKey: thread.thread_key)
        if ok { await reload(silent: true) } else { draft = text }
        sending = false
    }
}

// MARK: - 工具
func supportShortTime(_ s: String?) -> String {
    guard let s = s, !s.isEmpty else { return "" }
    return String(s.replacingOccurrences(of: "T", with: " ").prefix(16))
}
