import SwiftUI

struct VideoRootView: View {
    @AppStorage("hasCompletedInitialSetup") private var hasCompletedInitialSetup = false

    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var resourceManager: ResourceManager
    @EnvironmentObject var videoDataManager: OVideoDataManager

    @ObservedObject private var coordinator = VideoPointsCoordinator.shared
    @ObservedObject private var notif = NotificationPermissionManager.shared
    @ObservedObject private var anonPromo = AnonymousSubscribePromptManager.shared

    private func syncGlobalBlock() {
        notif.setGlobalBlocked(!hasCompletedInitialSetup
                               || resourceManager.showForceUpdate
                               || resourceManager.showMigrationSheet)
    }

    var body: some View {
        ZStack {
            if hasCompletedInitialSetup {
                VideoHomeRootView()
            } else {
                VideoWelcomeView(hasCompletedInitialSetup: $hasCompletedInitialSetup)
            }

            if resourceManager.showForceUpdate {
                ForceUpdateView(storeURL: resourceManager.appStoreURL)
                    .transition(.opacity).zIndex(998)
            }
            if resourceManager.showMigrationSheet, let cfg = resourceManager.activeMigration {
                MigrationView(config: cfg,
                              onDismiss: cfg.isForced ? nil : { resourceManager.dismissMigration() })
                    .transition(.opacity.combined(with: .move(edge: .bottom))).zIndex(999)
            }

            VideoPointsOverlayView().zIndex(1000)
            AppFlowOverlay().zIndex(1001)
        }
        .animation(.easeInOut, value: resourceManager.showForceUpdate)
        .animation(.easeInOut, value: resourceManager.showMigrationSheet)

        // 每个 sheet 挂在独立图层，避免 SwiftUI 多 sheet 互相覆盖
        .background(Color.clear.sheet(isPresented: $coordinator.showVideoInviteSheet) { VideoInviteView() })
        .background(Color.clear.sheet(isPresented: $authManager.showSubscriptionSheet) { SubscriptionView() })
        .background(Color.clear.sheet(isPresented: $coordinator.showSubscriptionSheet) { SubscriptionView() })
        .background(Color.clear.sheet(isPresented: $anonPromo.showSheet) { AnonymousSubscribeView() })
        .background(Color.clear.sheet(isPresented: $notif.showPreAsk) { NotificationPreAskView() })

        .onAppear { syncGlobalBlock(); coordinator.authRef = authManager }
        .onChange(of: hasCompletedInitialSetup) { _ in syncGlobalBlock() }
        .onChange(of: resourceManager.showForceUpdate) { _ in syncGlobalBlock() }
        .onChange(of: resourceManager.showMigrationSheet) { _ in syncGlobalBlock() }
        .onChange(of: authManager.isSubscribed) { if $0 { AnonymousSubscribePromptManager.shared.markPurchased() } }
        .onChange(of: authManager.isLoggedIn) { v in
            if v {
                Task {
                    await FreeQuotaManager.shared.refresh(
                        userId: FreeQuotaManager.currentUserId(auth: authManager))
                }
            }
        }
    }
}

struct VideoHomeRootView: View {
    @EnvironmentObject var resourceManager: ResourceManager
    @EnvironmentObject var authManager: AuthManager
    @ObservedObject private var supportManager = SupportChatManager.shared

    var body: some View {
        NavigationStack {
            if resourceManager.showVideoModule && !authManager.isVideoModuleBlocked {
                VideoModuleView(showBackButton: false)
            } else {
                VideoModuleClosedView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let msg = resourceManager.activeNotification {
                    NotificationBannerView(message: msg) { resourceManager.dismissNotification() }
                }
                WishReplyBanner(userId: authManager.userIdentifier)
                ReportReplyBanner(userId: authManager.userIdentifier)
            }
        }
        .onAppear {
            Task {
                await resourceManager.refreshServerConfig(minInterval: 120,
                                                          userId: authManager.userIdentifier)
                await WishReplyManager.shared.refresh(userId: authManager.userIdentifier)
                await ReportReplyManager.shared.refresh(userId: authManager.userIdentifier)
            }
        }
        // 承接横幅「回复」按钮调用的 SupportChatManager.openChat(type:)
        .sheet(isPresented: $supportManager.showChat) {
            SupportChatView(userId: SupportIdentity.userId(appleId: authManager.userIdentifier))
        }
    }
}

// MARK: - 服务器公告条
struct NotificationBannerView: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bell.badge.fill").foregroundColor(.orange)
                .font(.system(size: 16)).padding(.top, 3)
            Text(message).font(.system(size: 14, weight: .medium))
                .fixedSize(horizontal: false, vertical: true).lineLimit(3)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary).padding(6)
                    .background(Color.secondary.opacity(0.15)).clipShape(Circle())
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.cardBackground)
            .shadow(color: .black.opacity(0.06), radius: 3, y: 2))
        .padding(.horizontal, 16).padding(.vertical, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - 寻片回复横幅
struct WishReplyBanner: View {
    @ObservedObject private var manager = WishReplyManager.shared
    let userId: String?
    @AppStorage("isGlobalEnglishMode") private var en = false

    var body: some View {
        Group {
            if let r = manager.pendingReplies.first {
                bannerBody(icon: "bell.badge.fill", tint: .orange,
                           title: en ? "Reply to your request" : "你的寻片请求有回复啦",
                           sub: r.wish_content, body: r.admin_reply ?? "",
                           threadType: "wish") {
                    Task { await manager.acknowledge(r, userId: userId) }
                }
            }
        }
        .animation(.easeInOut, value: manager.pendingReplies.first?.id)
    }

    @ViewBuilder
    private func bannerBody(icon: String, tint: Color, title: String, sub: String,
                            body: String, threadType: String,
                            onClose: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundColor(tint).font(.system(size: 16)).padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .bold))
                if !sub.isEmpty {
                    Text("「\(sub)」").font(.system(size: 12))
                        .foregroundColor(.secondary).lineLimit(1)
                }
                Text(body).font(.system(size: 14, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true).lineLimit(3)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button { SupportChatManager.shared.openChat(type: threadType) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 10, weight: .bold))
                        Text(en ? "Reply" : "回复").font(.system(size: 11, weight: .bold))
                    }
                    .foregroundColor(.white).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.blue))
                }
                .buttonStyle(PlainButtonStyle())
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary).padding(6)
                        .background(Color.secondary.opacity(0.15)).clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.cardBackground)
            .shadow(color: .black.opacity(0.06), radius: 3, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.25), lineWidth: 0.5))
        .padding(.horizontal, 16).padding(.vertical, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - 举报回复横幅
struct ReportReplyBanner: View {
    @ObservedObject private var manager = ReportReplyManager.shared
    let userId: String?
    @AppStorage("isGlobalEnglishMode") private var en = false

    var body: some View {
        Group {
            if let r = manager.pendingReplies.first {
                let ep = (r.episode_name?.isEmpty == false) ? " · \(r.episode_name!)" : ""
                WishReplyBannerShell(icon: "checkmark.bubble.fill", tint: .green,
                                     title: en ? "Reply to your report" : "你举报的链接有回复啦",
                                     sub: (r.video_title ?? "") + ep,
                                     body: r.admin_reply ?? "",
                                     threadType: "report",
                                     en: en) {
                    Task { await manager.acknowledge(r, userId: userId) }
                }
            }
        }
        .animation(.easeInOut, value: manager.pendingReplies.first?.id)
    }
}

/// 抽出来的横幅外壳，供举报横幅复用
struct WishReplyBannerShell: View {
    let icon: String, tint: Color, title: String, sub: String, body_: String
    let threadType: String, en: Bool
    let onClose: () -> Void

    init(icon: String, tint: Color, title: String, sub: String, body: String,
         threadType: String, en: Bool, onClose: @escaping () -> Void) {
        self.icon = icon; self.tint = tint; self.title = title
        self.sub = sub; self.body_ = body; self.threadType = threadType
        self.en = en; self.onClose = onClose
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundColor(tint).font(.system(size: 16)).padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .bold))
                if !sub.isEmpty {
                    Text("「\(sub)」").font(.system(size: 12))
                        .foregroundColor(.secondary).lineLimit(1)
                }
                Text(body_).font(.system(size: 14, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true).lineLimit(3)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button { SupportChatManager.shared.openChat(type: threadType) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 10, weight: .bold))
                        Text(en ? "Reply" : "回复").font(.system(size: 11, weight: .bold))
                    }
                    .foregroundColor(.white).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.blue))
                }
                .buttonStyle(PlainButtonStyle())
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary).padding(6)
                        .background(Color.secondary.opacity(0.15)).clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.cardBackground)
            .shadow(color: .black.opacity(0.06), radius: 3, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.25), lineWidth: 0.5))
        .padding(.horizontal, 16).padding(.vertical, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
