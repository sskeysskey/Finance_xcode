import SwiftUI

struct VideoInviteView: View {
    @EnvironmentObject var authManager: AuthManager
    @ObservedObject var quota = FreeQuotaManager.shared
    @Environment(\.dismiss) var dismiss
    @AppStorage("isGlobalEnglishMode") private var en = false

    @State private var codeInput = ""
    @State private var isRedeeming = false
    @State private var showResult = false
    @State private var resultTitle = ""
    @State private var resultMessage = ""
    @State private var succeeded = false
    @State private var copied = false

    private var shareText: String {
        let code = quota.inviteCode
        return en
            ? "Use my invite code \(code) after signing in and we both get \(quota.inviteRewardPoints) free points!"
            : "用我的邀请码 \(code) 登录就能领取 \(quota.inviteRewardPoints) 点免费点数，你我都有奖！"
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 22) {
                    header
                    if !authManager.isLoggedIn { loginCard }
                    else {
                        myCodeCard
                        if !quota.hasRedeemedInvite { redeemCard } else { redeemedCard }
                        statsCard
                    }
                    rulesCard
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 16).padding(.top, 8)
            }
            .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(Localized.close) { dismiss() }
                }
            }
            .task { await quota.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager)) }
            .onChange(of: authManager.isLoggedIn) { v in
                if v { Task { await quota.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager)) } }
            }
            .alert(resultTitle, isPresented: $showResult) {
                Button(Localized.ok, role: .cancel) { if succeeded { dismiss() } }
            } message: { Text(resultMessage) }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "gift.circle.fill").font(.system(size: 70))
                .foregroundStyle(.linearGradient(colors: [.pink, .orange],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: .pink.opacity(0.3), radius: 10, y: 5)
            Text(en ? "Both get \(quota.inviteRewardPoints) points"
                    : "邀请好友 · 双方各得 \(quota.inviteRewardPoints) 点")
                .font(.title3.bold()).multilineTextAlignment(.center)
        }
        .padding(.top, 10)
    }

    private var loginCard: some View {
        VStack(spacing: 14) {
            Text(en ? "Sign in to get your invite code" : "登录后才能生成你的专属邀请码")
                .font(.subheadline).foregroundColor(.secondary)
            Button { authManager.signInWithApple() } label: {
                Text(Localized.loginAccount)
                    .fontWeight(.bold).foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Color.blue).cornerRadius(12)
            }
        }
        .padding(18).background(Color.cardBackground).cornerRadius(16)
    }

    private var myCodeCard: some View {
        VStack(spacing: 14) {
            Text(en ? "Your invite code" : "我的专属邀请码")
                .font(.subheadline).foregroundColor(.secondary)
            Text(quota.inviteCode.isEmpty ? "····" : quota.inviteCode)
                .font(.system(size: 38, weight: .heavy, design: .monospaced))
                .foregroundColor(.orange).kerning(4)
            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = quota.inviteCode
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { copied = false } }
                } label: {
                    Label(copied ? (en ? "Copied" : "已复制") : (en ? "Copy" : "复制"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(Color.blue.opacity(0.12)).foregroundColor(.blue).cornerRadius(10)
                }
                if !quota.inviteCode.isEmpty {
                    ShareLink(item: shareText) {
                        Label(en ? "Share" : "分享给好友", systemImage: "square.and.arrow.up")
                            .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(LinearGradient(colors: [.pink, .orange],
                                                       startPoint: .leading, endPoint: .trailing))
                            .foregroundColor(.white).cornerRadius(10)
                    }
                }
            }
        }
        .padding(18).background(Color.cardBackground).cornerRadius(16)
    }

    private var statsCard: some View {
        HStack {
            Image(systemName: "person.2.fill").foregroundColor(.green)
            Text(en ? "Invited" : "已成功邀请")
            Text("\(quota.inviteRewardCount)").fontWeight(.bold).foregroundColor(.green)
            Text(en ? "friends · \(quota.inviteRewardCount * quota.inviteRewardPoints) pts earned"
                    : "位好友 · 累计获得 \(quota.inviteRewardCount * quota.inviteRewardPoints) 点")
                .font(.footnote).foregroundColor(.secondary)
            Spacer()
        }
        .font(.subheadline).padding(16).background(Color.cardBackground).cornerRadius(16)
    }

    private var redeemCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(en ? "Enter a friend's code" : "填写好友的邀请码").font(.headline)
            Text(en ? "You both get \(quota.inviteRewardPoints) free points instantly (once per user)."
                    : "输入后你和好友都将立即获得 \(quota.inviteRewardPoints) 点（每位用户仅可填写一次）")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                TextField(en ? "Invite code" : "请输入邀请码", text: $codeInput)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .padding(12).background(Color(UIColor.tertiarySystemFill)).cornerRadius(10)
                Button { performRedeem() } label: {
                    Text(en ? "Redeem" : "领取").fontWeight(.bold).foregroundColor(.white)
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .background(codeInput.isEmpty ? Color.gray : Color.orange).cornerRadius(10)
                }
                .disabled(codeInput.isEmpty || isRedeeming)
            }
        }
        .padding(18).background(Color.cardBackground).cornerRadius(16)
        .overlay { if isRedeeming { ProgressView().padding().background(.regularMaterial).cornerRadius(10) } }
    }

    private var redeemedCard: some View {
        HStack {
            Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
            Text(en ? "You've used a code. Invite friends to earn more points!"
                    : "你已使用过邀请码，快去邀请好友赚取更多点数吧！")
                .font(.subheadline).foregroundColor(.secondary)
            Spacer()
        }
        .padding(16).background(Color.cardBackground).cornerRadius(16)
    }

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(en ? "How it works" : "活动规则").font(.headline)
            ruleRow("1", en ? "Share your invite code" : "把你的邀请码分享给好友")
            ruleRow("2", en ? "Friends sign in and enter your code" : "好友下载 App 并登录后填入你的邀请码")
            ruleRow("3", en ? "You both instantly get \(quota.inviteRewardPoints) points"
                            : "你和好友立即各得 \(quota.inviteRewardPoints) 点")
            ruleRow("4", en ? "No limit — invite more, get more" : "邀请人数不限，邀请越多点数越多")
        }
        .padding(18).background(Color.cardBackground).cornerRadius(16)
    }

    private func ruleRow(_ n: String, _ t: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(n).font(.caption.bold()).foregroundColor(.white)
                .frame(width: 20, height: 20).background(Color.orange).clipShape(Circle())
            Text(t).font(.subheadline).foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func performRedeem() {
        guard authManager.isLoggedIn else { authManager.signInWithApple(); return }
        let code = codeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        isRedeeming = true
        Task {
            do {
                let uid = FreeQuotaManager.currentUserId(auth: authManager)
                let points = try await quota.redeemInvite(userId: uid, code: code)
                await quota.refresh(userId: uid)
                await MainActor.run {
                    isRedeeming = false; succeeded = true
                    resultTitle = en ? "🎉 Success!" : "🎉 恭喜领取成功！"
                    resultMessage = en ? "You and your friend each got \(points) free points!"
                                       : "你和好友都已获得 \(points) 点免费点数！"
                    showResult = true; codeInput = ""
                }
            } catch {
                await MainActor.run {
                    isRedeeming = false; succeeded = false
                    resultTitle = en ? "Failed" : "领取失败"
                    resultMessage = error.localizedDescription
                    showResult = true
                }
            }
        }
    }
}
