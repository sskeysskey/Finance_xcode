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
                        .multilineTextAlignment(.center)
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
                                .font(.headline)
                            // 【修改】使用双语变量
                            Text(authManager.isSubscribed ? Localized.planFreeDetailSubbed : Localized.planFreeDetail)
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
                            // 【修改】价格双语化
                            Text(Localized.pricePerMonth)
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
                    // 【修改】双语化
                    Text(Localized.currentProUser)
                        .foregroundColor(.orange)
                        .padding()
                } else {
                    // 【修改】双语化
                    Text(Localized.freePlanFootnote)
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
                    
                    // 【修改】文案双语化
                    if isRestoring {
                        Text(Localized.restoring)
                            .foregroundColor(.white)
                            .padding(.top)
                    } else if isRedeeming {
                        Text(Localized.verifying)
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
        // 【修改】Alert 标题双语化
        .alert(Localized.paymentFailed, isPresented: $showError) {
            Button(Localized.confirm, role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        // 【修改】兑换码 Alert 双语化
        .alert(Localized.internalTestTitle, isPresented: $showRedeemAlert) {
            TextField(Localized.enterInviteCode, text: $inviteCode)
                .textInputAutocapitalization(.characters)
            Button(Localized.cancel, role: .cancel) { }
            Button(Localized.redeem) {
                handleRedeem()
            }
        } message: {
            Text(Localized.inviteCodeInstruction)
        }
        // 【修改】恢复结果 Alert 双语化
        .alert(Localized.restoreResult, isPresented: $showRestoreAlert) {
            Button(Localized.confirm, role: .cancel) {
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
                // 登录成功后，给系统一点时间去同步服务器状态和 Apple 凭证
                Task {
                    // 延迟 1.5 秒，给用户一个“正在同步状态”的视觉缓冲，也确保网络请求完成
                    try? await Task.sleep(nanoseconds: 1_500_000_000) 
                    
                    if authManager.isSubscribed {
                        // 如果识别到已经是订阅用户，直接关闭订阅窗口
                        print("登录成功且识别到订阅，自动关闭订阅页面。")
                        dismiss()
                    } else {
                        // 如果登录了但还没订阅，可以保持在当前页面，让用户继续选购
                        print("登录成功但未发现有效订阅。")
                    }
                }
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
                    // 【修改】恢复结果文案双语化
                    if authManager.isSubscribed {
                        restoreMessage = Localized.restoreSuccess
                    } else {
                        restoreMessage = Localized.restoreNotFound
                    }
                    showRestoreAlert = true
                }
            } catch {
                await MainActor.run {
                    isRestoring = false
                    // 使用专门的“恢复失败”词条
                    restoreMessage = "\(Localized.restoreFailed): \(error.localizedDescription)"
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
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }
}