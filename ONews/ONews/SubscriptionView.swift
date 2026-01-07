import SwiftUI

struct SubscriptionView: View {

    @EnvironmentObject var authManager: AuthManager
    @Environment(\.dismiss) var dismiss
    // 【新增】
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false 
    
    @State private var isPurchasing = false
    @State private var showError = false
    @State private var errorMessage = ""
    
    // 控制隐藏输入框的显示
    @State private var showRedeemAlert = false
    @State private var inviteCode = ""
    @State private var isRedeeming = false
    
    // 恢复购买相关状态
    @State private var isRestoring = false
    @State private var showRestoreAlert = false
    @State private var restoreMessage = ""
    
    // 【新增 1】控制登录弹窗显示
    @State private var showLoginSheet = false
    
    var body: some View {
        ZStack {
            // 使用系统背景色
            Color.viewBackground.ignoresSafeArea()
            
            VStack(spacing: 25) {
                // 标题
                VStack(spacing: 10) {
                    Text(Localized.subTitle) // "最近三天..."
                        .font(.largeTitle.bold())
                        .foregroundColor(.primary)
                        // 连续点击5次触发
                        .onTapGesture(count: 5) {
                            showRedeemAlert = true
                        }
                    
                    Text(Localized.subDesc)
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
                            Text(Localized.planFree)
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
                            Text(Localized.planPro)
                                .font(.title2.bold())
                                .foregroundColor(.primary)
                            Text(Localized.planProDesc)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text("¥12/月")
                                .font(.title2.bold())
                                .foregroundColor(.orange)
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
                        Text(Localized.restorePurchase)
                            .font(.footnote)
                            .foregroundColor(.blue)
                            .underline()
                    }
                    .disabled(isRestoring || isPurchasing || isRedeeming)
                    
                    Text("|").foregroundColor(.secondary)
                    
                    Link(Localized.privacy, destination: URL(string: "https://sskeysskey.github.io/website/privacy.html")!)
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    Text("|").foregroundColor(.secondary)
                    Link(Localized.terms, destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
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
                
                Button(Localized.close) {
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
                        Text(Localized.processingPayment)
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
        // 【新增 2】绑定登录弹窗
        .sheet(isPresented: $showLoginSheet) {
            LoginView()
        }
        // ================== 【新增修复代码开始】 ==================
        // 监听登录状态，登录成功后自动关闭当前视图弹出的 LoginView
        .onChange(of: authManager.isLoggedIn) { _, newValue in
            if newValue == true && showLoginSheet {
                showLoginSheet = false
                // 可选：如果需要在登录后自动继续购买流程，可以在这里再次调用 handlePurchase()
                // handlePurchase() 
            }
        }
    }
    
    // 【修改】处理购买：先检查登录
    private func handlePurchase() {
        // 1. 检查是否已登录
        guard authManager.isLoggedIn else {
            showLoginSheet = true
            return
        }
        
        // 2. 开始购买流程
        isPurchasing = true
        
        Task {
            do {
                // 【核心修改】获取购买结果 (true/false)
                let isSuccess = try await authManager.purchaseSubscription()
                
                await MainActor.run {
                    isPurchasing = false
                    
                    if isSuccess {
                        // 只有明确成功时，才关闭页面
                        print("支付成功，关闭订阅页面")
                        dismiss()
                    } else {
                        // 如果是取消(.userCancelled)或挂起，保持页面打开
                        print("用户取消或未完成支付，保留订阅页面")
                        // 这里不需要做任何操作，SubscriptionView 会继续显示
                    }
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
    
    // 【修改】处理恢复购买：先检查登录
    private func performRestore() {
        // 1. 检查是否已登录
        guard authManager.isLoggedIn else {
            showLoginSheet = true
            return
        }
        
        // 2. 已登录 -> 执行原有恢复逻辑
        isRestoring = true
        Task {
            do {
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
    
    // 【修改】处理兑换逻辑：建议也加上登录检查
    private func handleRedeem() {
        guard !inviteCode.isEmpty else { return }
        
        // 建议加上：确保有 UserID 绑定
        guard authManager.isLoggedIn else {
            showLoginSheet = true
            return
        }
        
        isRedeeming = true
        Task {
            // ... (原有兑换逻辑保持不变)
            do {
                try await authManager.redeemInviteCode(inviteCode)
                await MainActor.run {
                    isRedeeming = false
                    inviteCode = ""
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
}
