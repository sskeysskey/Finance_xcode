import SwiftUI
import AppKit            // NSPasteboard
import AuthenticationServices

struct SubscriptionView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var lang: LanguageManager
    @ObservedObject var quota = QuotaManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var working = false
    @State private var message: String?
    @State private var showInvite = false

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(systemName: "crown.fill").font(.system(size: 34)).foregroundStyle(.orange)
                Text(lang.t("开通会员，畅享全部内容", "Go Premium")).font(.title2.bold())
                Text(lang.t("不限次数观看与下载，去除点数限制。",
                            "Unlimited watching & downloading."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            GroupBox {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(lang.t("免费版", "Free")).font(.headline)
                        Text(lang.t("每日 \(quota.dailyQuota) 点免费额度，当前 \(quota.remainingSummary(false))",
                                    "\(quota.dailyQuota) free daily · \(quota.remainingSummary(true))"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !auth.isSubscribed {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
                .padding(6)
            }

            GroupBox {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(lang.t("专业版 · 每月", "Premium · Monthly")).font(.headline)
                        Text(lang.t("不限量观看 / 下载，全部线路可用",
                                    "Unlimited watching & downloading"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(auth.isSubscribed ? lang.t("已开通", "Active") : lang.t("立即订阅", "Subscribe")) {
                        Task { await purchase() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(auth.isSubscribed || working)
                }
                .padding(6)
            }

            if !auth.isLoggedIn {
                // ⭐ 让原生按钮自己发起授权，结果交给 AuthManager，避免双重流程
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    auth.handleSignIn(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 36)

                Text(lang.t("登录后可同步会员状态与免费点数（登录免费）",
                            "Sign in to sync your membership and free passes"))
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if let m = message { Text(m).font(.caption).foregroundStyle(.orange) }

            HStack(spacing: 14) {
                Button(lang.t("恢复购买", "Restore")) { Task { await restore() } }.buttonStyle(.link)
                Button(lang.t("邀请码", "Invite Code")) { showInvite = true }.buttonStyle(.link)
                Link(lang.t("隐私政策", "Privacy"),
                     destination: URL(string: "https://sskeysskey.github.io/website/privacy.html")!)
                Link(lang.t("使用条款", "Terms"),
                     destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
            }
            .font(.caption)

            HStack { Spacer(); Button(lang.t("关闭", "Close")) { dismiss() } }
        }
        .padding(22)
        .frame(width: 470)
        .overlay { if working { ProgressView().controlSize(.large) } }
        .sheet(isPresented: $showInvite) { InviteSheet() }
        // ⭐ 换成兼容版，13/14/15 都零警告
        .onChangeCompat(of: auth.isSubscribed) { isSub in
            if isSub { dismiss() }
        }
    }

    private func purchase() async {
        guard auth.isLoggedIn else { auth.signInWithApple(); return }
        working = true; message = nil
        do { _ = try await auth.purchase() }
        catch { message = error.localizedDescription }
        working = false
    }

    private func restore() async {
        working = true; message = nil
        do {
            try await auth.restorePurchases()
            message = auth.isSubscribed ? lang.t("已恢复会员", "Restored")
                                        : lang.t("未找到可恢复的购买", "No purchase found")
        } catch { message = error.localizedDescription }
        working = false
    }
}

struct InviteSheet: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var lang: LanguageManager
    @ObservedObject var quota = QuotaManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var msg: String?
    @State private var ok = false
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(lang.t("邀请好友，双方各得点数", "Invite a friend, both get points")).font(.headline)

            if !quota.inviteCode.isEmpty {
                HStack {
                    Text(lang.t("我的邀请码：", "My code: "))
                    Text(quota.inviteCode).font(.title3.monospaced().bold())
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(quota.inviteCode, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    Spacer()
                    Text(lang.t("已邀请 \(quota.inviteRewardCount) 人",
                                "\(quota.inviteRewardCount) invited"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            if quota.hasRedeemedInvite {
                Text(lang.t("你已使用过邀请码", "You've already used an invite code"))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                TextField(lang.t("输入好友的邀请码", "Enter friend's code"), text: $code)
                    .textCase(.uppercase)
                Button(lang.t("兑换 \(quota.inviteRewardPoints) 点",
                              "Redeem \(quota.inviteRewardPoints) pts")) {
                    Task { await redeem() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || code.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let m = msg { Text(m).font(.caption).foregroundStyle(ok ? .green : .red) }
            HStack { Spacer(); Button(lang.t("关闭", "Close")) { dismiss() } }
        }
        .padding(20)
        .frame(width: 420)
        .task { await quota.refresh(userId: QuotaManager.currentUserId(auth: auth)) }
    }

    private func redeem() async {
        working = true
        do {
            let p = try await quota.redeemInvite(userId: QuotaManager.currentUserId(auth: auth),
                                                 code: code.uppercased())
            ok = true; msg = lang.t("兑换成功，获得 \(p) 点", "Success! +\(p) points")
            await quota.refresh(userId: QuotaManager.currentUserId(auth: auth))
        } catch { ok = false; msg = error.localizedDescription }
        working = false
    }
}