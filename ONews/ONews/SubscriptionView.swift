import SwiftUI

struct SubscriptionView: View {

    @EnvironmentObject var authManager: AuthManager
    @Environment(\.dismiss) var dismiss
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
    
    // 控制登录弹窗显示
    @State private var showLoginSheet = false
    
    // 【新增 1】定义挂起的操作类型
    enum PendingAction {
        case none
        case purchase
        case redeem
        case restore
    }
    // 【新增 2】记录登录后需要自动执行的操作
    @State private var pendingAction: PendingAction = .none
    
    var body: some View {
        ZStack {
            // 使用系统背景色
            Color.viewBackground.ignoresSafeArea()
            
            VStack(spacing: 25) {
                // 标题
                VStack(spacing: 10) {
                    Text(Localized.subTitle)
                        .font(.largeTitle.bold())
                        .foregroundColor(.primary)
                        // 【修改 1】连按5次触发逻辑优化
                        .onTapGesture(count: 5) {
                            if authManager.isLoggedIn {
                                // 已登录，直接弹窗
                                showRedeemAlert = true
                            } else {
                                // 未登录，记录意图并跳转登录
                                pendingAction = .redeem
                                showLoginSheet = true
                            }
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
                    // 【修改 2】购买按钮逻辑优化
                    if authManager.isLoggedIn {
                        handlePurchase()
                    } else {
                        pendingAction = .purchase
                        showLoginSheet = true
                    }
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
                
                // 底部链接区域
                HStack(spacing: 20) {
                    // 恢复购买按钮
                    Button(action: {
                        // 【修改 3】恢复购买逻辑优化
                        if authManager.isLoggedIn {
                            performRestore()
                        } else {
                            pendingAction = .restore
                            showLoginSheet = true
                        }
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
        // 兑换码 Alert
        .alert(Localized.internalTestTitle, isPresented: $showRedeemAlert) {
            TextField(Localized.enterInviteCode, text: $inviteCode)
                .textInputAutocapitalization(.characters)
            Button(Localized.cancel, role: .cancel) { 
                // 取消时清空挂起状态
                pendingAction = .none
            }
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
            // 只有当登录成功(true) 且 登录窗正在显示时才处理
            if newValue == true && showLoginSheet {
                showLoginSheet = false
                
                // 延迟一点点，等待 LoginSheet 关闭动画完成，再执行挂起的操作
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    // 1. 优先检查是否有挂起的操作
                    switch pendingAction {
                    case .redeem:
                        print("登录成功，恢复挂起操作：弹出兑换框")
                        showRedeemAlert = true
                        
                    case .purchase:
                        print("登录成功，恢复挂起操作：开始购买")
                        handlePurchase()
                        
                    case .restore:
                        print("登录成功，恢复挂起操作：开始恢复")
                        performRestore()
                        
                    case .none:
                        // 2. 如果没有挂起操作，再检查是否已经自动识别了订阅（之前的逻辑）
                        // 比如用户在别的设备买了，刚登录同步下来了
                        if authManager.isSubscribed {
                            print("登录成功且识别到订阅，自动关闭订阅页面。")
                            dismiss()
                        }
                    }
                    
                    // 执行完后，重置状态（注意：redeem 是弹窗，不要立即重置，等弹窗关闭或提交时重置，
                    // 但这里重置为 none 也没事，因为 showRedeemAlert 已经设为 true 了）
                    if pendingAction != .redeem {
                        pendingAction = .none
                    }
                }
            }
        }
    }
    
    // 处理购买
    private func handlePurchase() {
        // 双重检查，虽然调用前通常已经检查过了
        guard authManager.isLoggedIn else {
            pendingAction = .purchase
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
                    pendingAction = .none // 结束后清空状态
                    
                    if isSuccess {
                        // 只有明确成功时，才关闭页面
                        print("支付成功，关闭订阅页面")
                        dismiss()
                    }
                }
            } catch {
                await MainActor.run {
                    isPurchasing = false
                    pendingAction = .none
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
            pendingAction = .restore
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
                    pendingAction = .none
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
                    pendingAction = .none
                    restoreMessage = "\(Localized.restoreFailed): \(error.localizedDescription)"
                    showRestoreAlert = true
                }
            }
        }
    }
    
    // 【修改】处理兑换逻辑：建议也加上登录检查
    private func handleRedeem() {
        guard !inviteCode.isEmpty else { return }
        
        // 确保已登录（理论上走到这里肯定是已登录的，因为弹窗前检查了）
        guard authManager.isLoggedIn else {
            pendingAction = .redeem
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
                    pendingAction = .none // 成功：清空挂起状态
                    inviteCode = ""
                    // 兑换成功后，直接关闭订阅页面
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isRedeeming = false
                    // 【关键修改点】
                    // 即使失败了，也清空 pendingAction。
                    // 因为此时兑换框已经弹出来了，用户的“登录并自动触发兑换”意图已经完成。
                    // 剩下的重试操作由用户在当前 Alert 界面手动完成即可。
                    pendingAction = .none 
                    
                    inviteCode = ""
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }
}