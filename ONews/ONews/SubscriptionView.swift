import SwiftUI

struct SubscriptionView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.dismiss) var dismiss
    
    @State private var isPurchasing = false
    @State private var showError = false
    @State private var errorMessage = ""
    
    // 【新增】控制隐藏输入框的显示
    @State private var showRedeemAlert = false
    @State private var inviteCode = ""
    @State private var isRedeeming = false
    
    // 【新增】恢复购买相关状态
    @State private var isRestoring = false
    @State private var showRestoreAlert = false
    @State private var restoreMessage = ""
    
    var body: some View {
        ZStack {
            // 【修改】使用系统背景色
            Color.viewBackground.ignoresSafeArea()
            
            VStack(spacing: 25) {
                // 标题
                VStack(spacing: 10) {
                    Text("最近三天的新闻需付费观看🥲")
                        .font(.largeTitle.bold())
                        .foregroundColor(.primary)
                        // 连续点击5次触发
                        .onTapGesture(count: 5) {
                            showRedeemAlert = true
                        }
                    
                    Text("推荐选择“专业版”套餐\n订阅成功后的一个月内畅享所有日期资讯\n如果实在不想付费😓\n三天前资讯也可永久免费享用")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 40)
                
                // 免费套餐卡片
                Button(action: {
                    // 选择免费，直接关闭
                    dismiss()
                }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("【当前】免费版")
                                // .font(.title2.bold())
                                .foregroundColor(.primary)
                            Text("可免费浏览 \(authManager.isSubscribed ? "全部" : "三天前") 的所有文章")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if !authManager.isSubscribed {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.title)
                        }
                    }
                    .padding()
                    // 【修改】使用卡片背景色
                    .background(Color.cardBackground)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(authManager.isSubscribed ? Color.clear : Color.green, lineWidth: 2)
                    )
                    .shadow(color: Color.black.opacity(0.05), radius: 5)
                }
                .buttonStyle(PlainButtonStyle())
                
                // 付费套餐卡片
                Button(action: {
                    handlePurchase()
                }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("专业版套餐")
                                .font(.title2.bold())
                                .foregroundColor(.primary)
                            Text("解锁最新日期资讯，与世界同频")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text("¥12/月")
                                .font(.title2.bold())
                                .foregroundColor(.orange) // 橙色在深浅模式下都比较醒目
                            // Text("/月")
                            //     .font(.caption)
                            //     .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    // 【修改】使用卡片背景色
                    .background(Color.cardBackground)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(authManager.isSubscribed ? Color.orange : Color.clear, lineWidth: 2)
                    )
                    .shadow(color: Color.black.opacity(0.05), radius: 5)
                }
                .buttonStyle(PlainButtonStyle())
                
                Spacer()
                
                // 【新增】底部链接区域，加入恢复购买按钮
                HStack(spacing: 20) {
                    
                    // 恢复购买按钮
                    Button(action: {
                        performRestore()
                    }) {
                        Text("恢复购买")
                            .font(.footnote)
                            .foregroundColor(.blue)
                            .underline()
                    }
                    .disabled(isRestoring || isPurchasing || isRedeeming)
                    
                    Text("|").foregroundColor(.secondary)
                    
                    Link("隐私政策", destination: URL(string: "https://sskeysskey.github.io/website/privacy.html")!)
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    Text("|").foregroundColor(.secondary)
                    
                    Link("使用条款 (EULA)", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // 底部说明
                if authManager.isSubscribed {
                    Text("您当前是尊贵的专业版用户")
                        .foregroundColor(.orange)
                        .padding()
                } else {
                    Text("如果不选择付费，您将继续使用免费版，仍可以浏览三天前的文章。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                
                Button("关闭") {
                    dismiss()
                }
                .foregroundColor(.secondary)
                .padding(.bottom)
            }
            .padding(.horizontal)
            
            // 加载遮罩 (购买、兑换或恢复时显示)
            if isPurchasing || isRedeeming || isRestoring {
                Color.black.opacity(0.6).ignoresSafeArea()
                VStack {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    
                    // 根据状态显示不同文案
                    if isRestoring {
                        Text("正在恢复购买...")
                            .foregroundColor(.white)
                            .padding(.top)
                    } else if isRedeeming {
                        Text("正在验证...")
                            .foregroundColor(.white)
                            .padding(.top)
                    } else {
                        Text("正在处理支付...")
                            .foregroundColor(.white)
                            .padding(.top)
                    }
                }
            }
        }
        .alert("支付失败", isPresented: $showError) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        // 【新增】兑换码输入弹窗
        .alert("内部测试/亲友通道", isPresented: $showRedeemAlert) {
            TextField("请输入邀请码", text: $inviteCode)
                .textInputAutocapitalization(.characters) // 自动大写
            Button("取消", role: .cancel) { }
            Button("兑换") {
                handleRedeem()
            }
        } message: {
            Text("请输入管理员提供的专用代码以解锁全部功能。")
        }
        // 【新增】恢复结果弹窗
        .alert("恢复结果", isPresented: $showRestoreAlert) {
            Button("确定", role: .cancel) {
                // 如果恢复成功，用户点击确定后可以自动关闭页面
                if authManager.isSubscribed {
                    dismiss()
                }
            }
        } message: {
            Text(restoreMessage)
        }
    }
    
    // 处理购买
    private func handlePurchase() {
        isPurchasing = true
        Task {
            do {
                try await authManager.purchaseSubscription()
                await MainActor.run {
                    isPurchasing = false
                    // 购买成功后，AuthManager 会更新状态并可能自动关闭 Sheet，
                    // 或者我们在这里手动关闭
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isPurchasing = false
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }
    
    // 【新增】处理兑换逻辑
    private func handleRedeem() {
        guard !inviteCode.isEmpty else { return }
        isRedeeming = true
        
        Task {
            do {
                try await authManager.redeemInviteCode(inviteCode)
                await MainActor.run {
                    isRedeeming = false
                    inviteCode = ""
                    // 兑换成功，关闭页面
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isRedeeming = false
                    inviteCode = ""
                    errorMessage = "兑换失败: \(error.localizedDescription)"
                    showError = true
                }
            }
        }
    }
    
    // 【新增】处理恢复购买
    private func performRestore() {
        isRestoring = true
        Task {
            do {
                // 调用 AuthManager 的恢复方法
                try await authManager.restorePurchases()
                
                await MainActor.run {
                    isRestoring = false
                    if authManager.isSubscribed {
                        restoreMessage = "成功恢复订阅！您现在可以无限制访问数据。"
                    } else {
                        restoreMessage = "未发现有效的订阅记录。"
                    }
                    showRestoreAlert = true
                }
            } catch {
                await MainActor.run {
                    isRestoring = false
                    restoreMessage = "恢复失败: \(error.localizedDescription)"
                    showRestoreAlert = true
                }
            }
        }
    }
}