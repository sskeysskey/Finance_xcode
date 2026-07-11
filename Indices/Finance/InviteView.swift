import SwiftUI

// 邀请中心（个人中心 / 点数不足 / banner“+” 都用它）
struct InviteView: View {
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    @Environment(\.dismiss) var dismiss

    @State private var codeInput = ""
    @State private var isRedeeming = false
    @State private var showResult = false
    @State private var resultTitle = ""
    @State private var resultMessage = ""
    @State private var redeemSucceeded = false
    @State private var showLogin = false
    @State private var copied = false

    // 分享文案
    private var shareText: String {
        let code = usageManager.inviteCode
        return "我在用【美股精灵】看美股数据，用我的邀请码 \(code) 注册就能领取 30 天专业版会员，你我都有奖！下载：https://apps.apple.com/cn/app/id6754904170"
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 22) {
                    header

                    if !authManager.isLoggedIn {
                        loginCard
                    } else {
                        myCodeCard
                        statsCard
                        if !usageManager.hasRedeemedInvite {
                            redeemCard
                        } else {
                            redeemedCard
                        }
                    }

                    rulesCard
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("邀请中大奖")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await usageManager.refreshQuota() }
            .sheet(isPresented: $showLogin) { LoginView() }
            .onChange(of: authManager.isLoggedIn) { _, newVal in
                if newVal { showLogin = false; Task { await usageManager.refreshQuota() } }
            }
            .alert(resultTitle, isPresented: $showResult) {
                Button("好的", role: .cancel) {
                    if redeemSucceeded { dismiss() }
                }
            } message: {
                Text(resultMessage)
            }
        }
    }

    // MARK: - Sections
    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "gift.circle.fill")
                .font(.system(size: 70))
                .foregroundStyle(.linearGradient(colors: [.pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: .pink.opacity(0.3), radius: 10, y: 5)
            Text("邀请好友 · 双方各得 30 天会员")
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            Text("好友越多，免费会员越久！")
                .font(.subheadline).foregroundColor(.secondary)
        }
        .padding(.top, 10)
    }

    private var loginCard: some View {
        VStack(spacing: 14) {
            Text("登录后才能生成你的专属邀请码")
                .font(.subheadline).foregroundColor(.secondary)
            Button {
                showLogin = true
            } label: {
                Text("登录 / 注册")
                    .fontWeight(.bold).foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Color.blue).cornerRadius(12)
            }
        }
        .padding(18)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    private var myCodeCard: some View {
        VStack(spacing: 14) {
            Text("我的专属邀请码").font(.subheadline).foregroundColor(.secondary)
            Text(usageManager.inviteCode.isEmpty ? "····" : usageManager.inviteCode)
                .font(.system(size: 38, weight: .heavy, design: .monospaced))
                .foregroundColor(.orange)
                .kerning(4)

            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = usageManager.inviteCode
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { copied = false }
                    }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(Color.blue.opacity(0.12)).foregroundColor(.blue).cornerRadius(10)
                }
                if !usageManager.inviteCode.isEmpty {
                    ShareLink(item: shareText) {
                        Label("分享给好友", systemImage: "square.and.arrow.up")
                            .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(LinearGradient(colors: [.pink, .orange], startPoint: .leading, endPoint: .trailing))
                            .foregroundColor(.white).cornerRadius(10)
                    }
                }
            }
        }
        .padding(18)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    private var statsCard: some View {
        HStack {
            Image(systemName: "person.2.fill").foregroundColor(.green)
            Text("已成功邀请")
            Text("\(usageManager.inviteRewardCount)").fontWeight(.bold).foregroundColor(.green)
            Text("位好友 · 累计获得 \(usageManager.inviteRewardCount * 30) 天会员")
                .font(.footnote).foregroundColor(.secondary)
            Spacer()
        }
        .font(.subheadline)
        .padding(16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    private var redeemCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("填写好友的邀请码").font(.headline)
            Text("输入后你和好友都将立即获得 30 天专业版会员（每位用户仅可填写一次）")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                TextField("请输入邀请码", text: $codeInput)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Color(UIColor.tertiarySystemFill))
                    .cornerRadius(10)
                Button {
                    performRedeem()
                } label: {
                    Text("领取")
                        .fontWeight(.bold).foregroundColor(.white)
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .background(codeInput.isEmpty ? Color.gray : Color.orange)
                        .cornerRadius(10)
                }
                .disabled(codeInput.isEmpty || isRedeeming)
            }
        }
        .padding(18)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .overlay {
            if isRedeeming {
                ProgressView().padding().background(.regularMaterial).cornerRadius(10)
            }
        }
    }

    private var redeemedCard: some View {
        HStack {
            Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
            Text("你已使用过邀请码，快去邀请好友赚取更多会员吧！")
                .font(.subheadline).foregroundColor(.secondary)
            Spacer()
        }
        .padding(16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("活动规则").font(.headline)
            ruleRow("1", "把你的邀请码分享给好友")
            ruleRow("2", "好友下载 App 并登录后，在首页或个人中心填入你的邀请码")
            ruleRow("3", "你和好友立即各得 30 天专业版会员（可叠加到现有会员时长）")
            ruleRow("4", "邀请人数不限，邀请越多，免费会员越久")
        }
        .padding(18)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    private func ruleRow(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(n)
                .font(.caption.bold()).foregroundColor(.white)
                .frame(width: 20, height: 20).background(Color.orange).clipShape(Circle())
            Text(text).font(.subheadline).foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Actions
    private func performRedeem() {
        guard authManager.isLoggedIn else { showLogin = true; return }
        let code = codeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        isRedeeming = true
        Task {
            do {
                let days = try await authManager.redeemFriendInviteCode(code)
                await usageManager.refreshQuota()
                await MainActor.run {
                    isRedeeming = false
                    redeemSucceeded = true
                    resultTitle = "🎉 恭喜领取成功！"
                    resultMessage = "你和好友都已获得 \(days) 天专业版会员！现在可无限畅享全部功能。"
                    showResult = true
                    codeInput = ""
                }
            } catch {
                await MainActor.run {
                    isRedeeming = false
                    redeemSucceeded = false
                    resultTitle = "领取失败"
                    resultMessage = error.localizedDescription
                    showResult = true
                }
            }
        }
    }
}

// 首页首启弹出的邀请码输入弹窗
struct InviteRedeemPromptView: View {
    @Binding var code: String
    var onConfirm: () -> Void
    var onSkip: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 40, height: 5).padding(.top, 10)

            Image(systemName: "gift.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.linearGradient(colors: [.pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))

            Text("有邀请码吗？")
                .font(.title2.bold())
            Text("填入好友的邀请码，立即领取 30 天专业版会员！")
                .font(.subheadline).foregroundColor(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal)

            TextField("请输入邀请码（选填）", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .multilineTextAlignment(.center)
                .font(.system(.title3, design: .monospaced))
                .padding(14)
                .background(Color(UIColor.tertiarySystemFill))
                .cornerRadius(12)
                .padding(.horizontal)

            Button(action: onConfirm) {
                Text("立即领取")
                    .fontWeight(.bold).foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(LinearGradient(colors: [.pink, .orange], startPoint: .leading, endPoint: .trailing))
                    .cornerRadius(14)
            }
            .padding(.horizontal)
            .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)

            Button("暂不需要", action: onSkip)
                .font(.subheadline).foregroundColor(.secondary)

            Spacer()
        }
        .padding(.bottom, 20)
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
    }
}
