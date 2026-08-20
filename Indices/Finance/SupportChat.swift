//  OSupportChat.swift
//  统一"在线客服"模块（ONews / 美股精灵 通用，仅需改 SupportAppConfig.appName）

import SwiftUI
import UIKit

// MARK: - 配置
enum SupportAppConfig {
    /// ⚠️ ONews 工程填 "ONews"；美股精灵工程填 "Finance"
    static let appName = "Finance"
    static let baseURL = "http://106.15.183.158:5001/api/support"
}

// MARK: - 用户标识（apple id 优先，未登录用 dev_ 设备号）
enum SupportIdentity {
    private static let deviceKey = "SupportDeviceID"

    static var deviceId: String {
        if let s = UserDefaults.standard.string(forKey: deviceKey), !s.isEmpty { return s }
        let vid = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        let id = "dev_" + vid
        UserDefaults.standard.set(id, forKey: deviceKey)
        return id
    }

    /// 传入 authManager.userIdentifier 即可
    static func userId(appleId: String?) -> String {
        if let uid = appleId, !uid.isEmpty { return uid }
        return deviceId
    }

    static func userType(_ id: String) -> String { id.hasPrefix("dev_") ? "device" : "apple" }
}

// MARK: - 模型
struct SupportThread: Codable, Hashable, Identifiable {
    let thread_key: String
    let thread_type: String
    let title: String?
    let subtitle: String?
    let status: String?
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
        case "wish":   return en ? "Request" : "寻片请求"
        case "report": return en ? "Bad link" : "坏链接反馈"
        default:       return en ? "Support"  : "在线咨询"
        }
    }
}

struct SupportMessage: Codable, Hashable, Identifiable {
    let id: Int
    let sender: String
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

    @Published var threads: [SupportThread] = []
    @Published var unreadTotal: Int = 0
    @Published var isLoading = false
    @Published var showChat = false
    /// 从横幅"回复"进来时，指定要自动打开的会话类型（wish / report）
    @Published var pendingOpenType: String? = nil

    private init() {}

    func generalThreadKey(userId: String) -> String {
        "\(SupportAppConfig.appName)|support|\(userId)"
    }

    /// 打开客服窗（type 为 nil 时只显示列表）
    func openChat(type: String? = nil) {
        pendingOpenType = type
        showChat = true
    }

    func refresh(userId: String?) async {
        guard let uid = userId, !uid.isEmpty else { return }
        guard var comp = URLComponents(string: "\(SupportAppConfig.baseURL)/threads") else { return }
        comp.queryItems = [.init(name: "app", value: SupportAppConfig.appName),
                           .init(name: "user_id", value: uid)]
        guard let url = comp.url else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let r = try JSONDecoder().decode(SupportThreadsResponse.self, from: data)
            self.threads = r.threads
            self.unreadTotal = r.unread_total
        } catch {
            // 静默失败，不打扰用户
        }
    }

    func messages(threadKey: String, userId: String) async -> [SupportMessage] {
        guard var comp = URLComponents(string: "\(SupportAppConfig.baseURL)/messages") else { return [] }
        comp.queryItems = [.init(name: "app", value: SupportAppConfig.appName),
                           .init(name: "user_id", value: userId),
                           .init(name: "thread_key", value: threadKey)]
        guard let url = comp.url else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let r = try JSONDecoder().decode(SupportMessagesResponse.self, from: data)
            return r.messages
        } catch { return [] }
    }

    @discardableResult
    func send(content: String, threadKey: String?, userId: String) async -> Bool {
        guard let url = URL(string: "\(SupportAppConfig.baseURL)/send") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        var body: [String: Any] = [
            "app": SupportAppConfig.appName,
            "user_id": userId,
            "user_type": SupportIdentity.userType(userId),
            "content": content,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        ]
        if let tk = threadKey { body["thread_key"] = tk }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return false }
            await refresh(userId: userId)
            return true
        } catch { return false }
    }
}

// MARK: - 悬浮客服按钮（长按可拖拽，类似 AssistiveTouch）
struct SupportBubbleOverlay: ViewModifier {
    let userId: String

    @ObservedObject private var manager = SupportChatManager.shared
    @AppStorage("SupportFAB_FX") private var fx: Double = 0.10   // 默认：左侧
    @AppStorage("SupportFAB_FY") private var fy: Double = 0.68   // 默认：偏下
    @State private var dragBase: CGPoint? = nil
    @State private var isDragging = false

    private let diameter: CGFloat = 52

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    let size = geo.size
                    bubble(size: size)
                        .position(current(in: size))
                }
                .ignoresSafeArea(.keyboard)
            )
            .sheet(isPresented: $manager.showChat) {
                SupportChatView(userId: userId)
            }
            .task { await manager.refresh(userId: userId) }
    }

    private func current(in size: CGSize) -> CGPoint {
        let x = min(max(CGFloat(fx) * size.width, diameter/2 + 6), size.width - diameter/2 - 6)
        let y = min(max(CGFloat(fy) * size.height, diameter/2 + 10), size.height - diameter/2 - 10)
        return CGPoint(x: x, y: y)
    }

    private func bubble(size: CGSize) -> some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color.blue, Color.purple],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: diameter, height: diameter)
                .shadow(color: Color.black.opacity(0.28), radius: 8, x: 0, y: 4)

            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)

            if manager.unreadTotal > 0 {
                Text(manager.unreadTotal > 99 ? "99+" : "\(manager.unreadTotal)")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.red))
                    .overlay(Capsule().stroke(Color.white.opacity(0.9), lineWidth: 1.2))
                    .offset(x: diameter/2 - 4, y: -diameter/2 + 4)
            }
        }
        .opacity(isDragging ? 0.9 : 0.94)
        .scaleEffect(isDragging ? 1.14 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDragging)
        .contentShape(Circle())
        .onTapGesture { manager.openChat() }
        .simultaneousGesture(dragGesture(in: size))
        .accessibilityLabel("在线客服")
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .onEnded { _ in
                isDragging = true
                dragBase = current(in: size)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                if case .second(true, let drag?) = value {
                    let base = dragBase ?? current(in: size)
                    let nx = base.x + drag.translation.width
                    let ny = base.y + drag.translation.height
                    fx = Double(min(max(nx, diameter/2 + 6), size.width - diameter/2 - 6) / max(size.width, 1))
                    fy = Double(min(max(ny, diameter/2 + 10), size.height - diameter/2 - 10) / max(size.height, 1))
                }
            }
            .onEnded { _ in
                isDragging = false
                dragBase = nil
                // 贴边吸附
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    fx = fx < 0.5 ? 0.08 : 0.92
                }
            }
    }
}

extension View {
    /// 给任意页面挂上"在线客服"悬浮按钮
    func supportBubble(userId: String) -> some View {
        self.modifier(SupportBubbleOverlay(userId: userId))
    }
}

// MARK: - 客服主界面（会话列表）
struct SupportChatView: View {
    let userId: String

    @ObservedObject private var manager = SupportChatManager.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("isGlobalEnglishMode") private var en = false
    @State private var path: [SupportThread] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Button {
                        path = [generalThread]
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(LinearGradient(colors: [.blue, .purple],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 38, height: 38)
                                Image(systemName: "plus.bubble.fill")
                                    .foregroundColor(.white).font(.system(size: 16, weight: .bold))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(en ? "Ask a new question" : "有问题？直接问客服")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.primary)
                                Text(en ? "Playback, subscription, points, anything."
                                        : "播放、订阅、点数、建议…任何问题都可以")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundColor(.gray)
                        }
                        .padding(.vertical, 4)
                    }
                }

                if !manager.threads.isEmpty {
                    Section(header: Text(en ? "My conversations" : "我的对话")) {
                        ForEach(manager.threads) { t in
                            NavigationLink(value: t) { row(t) }
                        }
                    }
                }
                // else if !manager.isLoading {
                //     Section {
                //         Text(en ? "No conversations yet." : "还没有对话记录")
                //             .font(.footnote).foregroundColor(.secondary)
                //             .frame(maxWidth: .infinity, alignment: .center)
                //             .padding(.vertical, 18)
                //     }
                // }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(en ? "Support" : "在线客服")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(en ? "Close" : "关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .navigationDestination(for: SupportThread.self) { t in
                SupportThreadDetailView(thread: t, userId: userId)
            }
        }
        .task { await load() }
    }

    private var generalThread: SupportThread {
        if let exist = manager.threads.first(where: { $0.thread_type == "support" }) { return exist }
        return SupportThread(thread_key: manager.generalThreadKey(userId: userId),
                             thread_type: "support",
                             title: en ? "Support" : "在线咨询",
                             subtitle: nil, status: "pending",
                             last_sender: nil, last_message: nil,
                             unread_user: 0, updated_at: nil)
    }

    private func row(_ t: SupportThread) -> some View {
        HStack(spacing: 12) {
            Image(systemName: t.icon).font(.system(size: 26)).foregroundColor(t.tint)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(t.typeName(en))
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(t.tint.opacity(0.15)).foregroundColor(t.tint)
                        .cornerRadius(4)
                    Text(t.title ?? "-")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary).lineLimit(1)
                }
                Text(((t.last_sender == "admin") ? (en ? "Support: " : "客服: ") : (en ? "You: " : "我: "))
                     + (t.last_message ?? ""))
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if t.unread > 0 {
                Text("\(t.unread)")
                    .font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.red))
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        manager.isLoading = true
        await manager.refresh(userId: userId)
        manager.isLoading = false
        // 横幅"回复"进来时自动定位会话
        if let type = manager.pendingOpenType {
            manager.pendingOpenType = nil
            let candidates = manager.threads.filter { $0.thread_type == type }
            if let target = candidates.first(where: { $0.unread > 0 }) ?? candidates.first {
                path = [target]
            }
        }
    }
}

// MARK: - 会话详情（聊天）
struct SupportThreadDetailView: View {
    let thread: SupportThread
    let userId: String

    @ObservedObject private var manager = SupportChatManager.shared
    @AppStorage("isGlobalEnglishMode") private var en = false
    @State private var messages: [SupportMessage] = []
    @State private var draft = ""
    @State private var sending = false
    @State private var loaded = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let sub = thread.subtitle, !sub.isEmpty {
                Text(sub)
                    .font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if !loaded {
                            ProgressView().padding(.top, 40)
                        } else if messages.isEmpty {
                            Text(en ? "Send your first message." : "发送第一条消息开始对话")
                                .font(.footnote).foregroundColor(.secondary).padding(.top, 40)
                        }
                        ForEach(messages) { m in bubble(m).id(m.id) }
                        Color.clear.frame(height: 1).id("BOTTOM")
                    }
                    .padding(16)
                }
                .onChange(of: messages.count) { oldValue, newValue in
                    withAnimation { proxy.scrollTo("BOTTOM", anchor: .bottom) }
                }
                .onAppear {
                    Task {
                        await reload()
                        withAnimation { proxy.scrollTo("BOTTOM", anchor: .bottom) }
                    }
                }
            }

            Divider()
            HStack(spacing: 10) {
                TextField(en ? "Type a message…" : "输入消息…", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color(UIColor.secondarySystemBackground)))
                    .focused($focused)

                Button {
                    Task { await sendMessage() }
                } label: {
                    Image(systemName: sending ? "hourglass" : "paperplane.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(canSend ? Color.blue : Color.gray.opacity(0.4)))
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle(thread.title ?? (en ? "Support" : "在线客服"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var canSend: Bool {
        !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func bubble(_ m: SupportMessage) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            if m.isUser { Spacer(minLength: 40) }
            VStack(alignment: m.isUser ? .trailing : .leading, spacing: 3) {
                Text(m.content)
                    .font(.system(size: 15))
                    .foregroundColor(m.isUser ? .white : .primary)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(
                        Group {
                            if m.isUser {
                                LinearGradient(colors: [.blue, Color.blue.opacity(0.85)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            } else {
                                Color(UIColor.secondarySystemGroupedBackground)
                            }
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .fixedSize(horizontal: false, vertical: true)
                Text(shortTime(m.created_at))
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            if !m.isUser { Spacer(minLength: 40) }
        }
    }

    private func shortTime(_ s: String?) -> String {
        guard let s = s else { return "" }
        return String(s.replacingOccurrences(of: "T", with: " ").prefix(16))
    }

    private func reload() async {
        messages = await manager.messages(threadKey: thread.thread_key, userId: userId)
        loaded = true
        await manager.refresh(userId: userId)
    }

    private func sendMessage() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        draft = ""
        let ok = await manager.send(content: text, threadKey: thread.thread_key, userId: userId)
        if ok {
            await reload()
        } else {
            draft = text
        }
        sending = false
    }
}
