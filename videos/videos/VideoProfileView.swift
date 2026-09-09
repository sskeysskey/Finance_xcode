import SwiftUI

struct VideoProfileView: View {
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var resourceManager: ResourceManager
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var quota = FreeQuotaManager.shared
    @ObservedObject private var support = SupportChatManager.shared
    @AppStorage("isGlobalEnglishMode") private var en = false

    @State private var showSubscriptionSheet = false
    @State private var showSupportChat = false
    @State private var showInviteSheet = false
    @State private var showLogoutConfirm = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var deleteError = ""
    @State private var showDeleteError = false

    private var supportUserId: String {
        SupportIdentity.userId(appleId: authManager.userIdentifier)
    }
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var body: some View {
        ZStack {
            NavigationView {
                List {
                    accountSection
                    if !authManager.isLoggedIn { guestSection }
                    if !authManager.isSubscribed { upgradeSection }
                    if authManager.isLoggedIn && !authManager.isSubscribed { pointsSection }
                    settingsSection
                    supportSection
                    aboutSection
                    if authManager.isLoggedIn { dangerSection }
                }
                .navigationTitle(Localized.profileTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(Localized.close) { dismiss() }
                    }
                }
                .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
                .sheet(isPresented: $showSupportChat) { SupportChatView(userId: supportUserId) }
                .sheet(isPresented: $showInviteSheet) { VideoInviteView() }
                .task {
                    await support.refresh(userId: supportUserId)
                    await quota.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager))
                }
                .alert(en ? "Sign Out" : "确认退出登录", isPresented: $showLogoutConfirm) {
                    Button(Localized.cancel, role: .cancel) { }
                    Button(en ? "Sign Out" : "退出登录", role: .destructive) {
                        authManager.signOut(); dismiss()
                    }
                } message: {
                    Text(en ? "After signing out you'll lose your free points and member access."
                            : "退出登录后将无法使用你的免费点数与会员权限。")
                }
                .alert(en ? "Delete Account" : "确认删除账号", isPresented: $showDeleteConfirm) {
                    Button(Localized.cancel, role: .cancel) { }
                    Button(en ? "Delete" : "永久删除", role: .destructive) { performDelete() }
                } message: {
                    Text(en ? "This cannot be undone. All your data will be removed from our servers."
                            : "此操作不可逆。你的所有数据将从服务器上永久删除。")
                }
                .alert(en ? "Error" : "删除失败", isPresented: $showDeleteError) {
                    Button(Localized.ok, role: .cancel) { }
                } message: { Text(deleteError) }
            }

            if isDeleting {
                Color.black.opacity(0.6).ignoresSafeArea()
                VStack(spacing: 18) {
                    ProgressView().scaleEffect(1.5).tint(.white)
                    Text(en ? "Deleting Account..." : "正在删除账号...").foregroundColor(.white)
                }
            }
        }
    }

    // MARK: 账号卡
    private var accountSection: some View {
        Section {
            HStack(spacing: 14) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 58)).foregroundColor(.gray.opacity(0.7))
                    if authManager.isSubscribed {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 15)).foregroundColor(.yellow)
                            .padding(4).background(Circle().fill(Color(UIColor.systemBackground)))
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    if authManager.isSubscribed {
                        Text(Localized.premiumUser).font(.subheadline.bold()).foregroundColor(.orange)
                        if let e = authManager.subscriptionExpiryDate {
                            Text("\(Localized.validUntil): \(formatDate(e))")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        if authManager.isAnonymousSubscribed {
                            Text(en ? "Subscribed without sign-in" : "免登录订阅")
                                .font(.caption2).foregroundColor(.blue)
                        }
                    } else {
                        Text(Localized.freeUser).font(.subheadline).foregroundColor(.secondary)
                    }
                    if let uid = authManager.userIdentifier {
                        Text("ID: \(uid.prefix(8))…").font(.caption2).foregroundColor(.gray)
                    } else {
                        Text(Localized.notLoggedIn).font(.caption2).foregroundColor(.gray)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: 游客
    private var guestSection: some View {
        Section {
            Button { authManager.signInWithApple() } label: {
                HStack {
                    Image(systemName: "apple.logo")
                    Text(Localized.loginAccount).fontWeight(.medium)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.gray)
                }
            }
            Button { PurchaseFlowManager.shared.restore(auth: authManager) } label: {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text(Localized.restorePurchase)
                    Spacer()
                }
            }
        } footer: {
            Text(en ? "Sign in (free) to get a welcome gift and free daily passes. Subscribed without signing in? Tap Restore Purchases after changing devices."
                    : "登录（免费）即可领取新人礼包与每日免费点数。免登录订阅的用户换设备后，用同一 Apple ID 点「恢复购买」即可。")
        }
    }

    // MARK: 升级
    private var upgradeSection: some View {
        Section {
            Button { showSubscriptionSheet = true } label: {
                HStack {
                    Image(systemName: "crown.fill").foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(en ? "Upgrade to Premium" : "升级尊享会员")
                            .foregroundColor(.primary).fontWeight(.medium)
                        Text(Localized.planProDesc).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(Localized.cachedDisplayPrice).font(.subheadline.bold()).foregroundColor(.orange)
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.gray)
                }
            }
        }
    }

    // MARK: 免费点数
    private var pointsSection: some View {
        Section(header: Text(en ? "Free Points" : "免费点数")) {
            HStack {
                Image(systemName: "bolt.circle.fill").foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(quota.remaining)")
                            .font(.system(size: 26, weight: .heavy, design: .rounded))
                            .foregroundColor(.orange)
                        Text(en ? "points left" : "点可用").font(.caption).foregroundColor(.secondary)
                    }
                    Text(quota.remainingSummary(english: en))
                        .font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    Task { await quota.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager)) }
                } label: {
                    Image(systemName: "arrow.clockwise").foregroundColor(.blue)
                }
                .buttonStyle(BorderlessButtonStyle())
            }
            .padding(.vertical, 4)

            Button { showInviteSheet = true } label: {
                HStack {
                    Image(systemName: "gift.fill").foregroundColor(.pink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(en ? "Invite friends · Free points" : "邀请好友 · 免费领点数")
                            .foregroundColor(.primary).fontWeight(.medium)
                        Text(en ? "You both get \(quota.inviteRewardPoints) points"
                                : "双方各得 \(quota.inviteRewardPoints) 点")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.gray)
                }
            }
        }
    }

    // MARK: 设置
    private var settingsSection: some View {
        Section(header: Text(en ? "Settings" : "设置")) {
            HStack {
                Image(systemName: "globe").foregroundColor(.blue)
                Text(en ? "Language" : "界面语言")
                Spacer()
                Picker("", selection: $en) {
                    Text("中文").tag(false)
                    Text("English").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 160)
            }
        }
    }

    // MARK: 客服 / 反馈
    private var supportSection: some View {
        Section(header: Text(Localized.feedback)) {
            Button {
                support.pendingOpenType = nil
                showSupportChat = true
            } label: {
                HStack {
                    ZStack {
                        Circle().fill(LinearGradient(colors: [.blue, .purple],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 26, height: 26)
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(en ? "Online Support" : "在线客服")
                            .foregroundColor(.primary).fontWeight(.medium)
                        Text(en ? "Playback, subscription, points — ask anything."
                                : "播放、订阅、点数、找片…任何问题都可以问")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    if support.unreadTotal > 0 {
                        Text(support.unreadTotal > 99 ? "99+" : "\(support.unreadTotal)")
                            .font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.red))
                    }
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.gray)
                }
            }

            Button {
                if let u = URL(string: "mailto:728308386@qq.com"),
                   UIApplication.shared.canOpenURL(u) { UIApplication.shared.open(u) }
            } label: {
                HStack {
                    Image(systemName: "envelope.fill").foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Localized.feedback).foregroundColor(.primary)
                        Text("728308386@qq.com").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption).foregroundColor(.gray)
                }
            }
            .contextMenu {
                Button { UIPasteboard.general.string = "728308386@qq.com" } label: {
                    Label(en ? "Copy Email" : "复制邮箱", systemImage: "doc.on.doc")
                }
            }
        }
    }

    // MARK: 关于
    private var aboutSection: some View {
        Section(header: Text(en ? "About" : "关于")) {
            HStack {
                Image(systemName: "info.circle.fill").foregroundColor(.gray)
                Text(en ? "Version" : "版本号")
                Spacer()
                Text("v\(appVersion)").foregroundColor(.secondary).monospacedDigit()
            }
            if authManager.isLoggedIn || authManager.isSubscribed {
                Button { PurchaseFlowManager.shared.restore(auth: authManager) } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise").foregroundColor(.blue)
                        Text(Localized.restorePurchase).foregroundColor(.primary)
                        Spacer()
                    }
                }
            }
            Link(destination: URL(string: "https://sskeysskey.github.io/website/privacy.html")!) {
                HStack {
                    Image(systemName: "hand.raised.fill").foregroundColor(.green)
                    Text(Localized.privacy).foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption).foregroundColor(.gray)
                }
            }
            Link(destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!) {
                HStack {
                    Image(systemName: "doc.text.fill").foregroundColor(.gray)
                    Text(Localized.terms).foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption).foregroundColor(.gray)
                }
            }
        }
    }

    private var dangerSection: some View {
        Section {
            Button(role: .destructive) { showLogoutConfirm = true } label: {
                HStack {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                    Text(Localized.logout)
                }
            }
            Button(role: .destructive) { showDeleteConfirm = true } label: {
                HStack {
                    Image(systemName: "trash.fill")
                    Text(en ? "Delete Account" : "删除账号")
                    Spacer()
                }
            }
        }
    }

    private func performDelete() {
        isDeleting = true
        Task {
            do {
                try await authManager.deleteAccount()
                await MainActor.run { isDeleting = false; dismiss() }
            } catch {
                await MainActor.run {
                    isDeleting = false
                    deleteError = error.localizedDescription
                    showDeleteError = true
                }
            }
        }
    }

    private func formatDate(_ iso: String) -> String {
        guard let d = AuthManager.parseServerDate(iso) else { return iso }
        let f = DateFormatter()
        f.locale = Locale(identifier: en ? "en_US" : "zh_CN")
        f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: d)
    }
}
