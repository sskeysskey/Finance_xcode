import SwiftUI

struct SubscriptionView: View {

    @EnvironmentObject var authManager: AuthManager
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme // 获取系统模式
    
    // 支付相关状态
    @State private var isPurchasing = false
    @State private var showError = false
    @State private var errorMessage = ""
    
    // 恢复购买相关状态
    @State private var isRestoring = false
    @State private var showRestoreAlert = false
    @State private var restoreMessage = ""
    
    // 【新增】控制登录弹窗显示
    @State private var showLoginSheet = false
    
    // 【新增】后门/内部通道相关状态
    @State private var tapCount = 0             // 点击计数器
    @State private var showRedeemSheet = false  // 控制输入框弹窗
    @State private var redeemCodeInput = ""     // 输入的验证码
    @State private var redeemMessage = ""       // 验证结果消息
    @State private var showRedeemResultAlert = false // 控制结果弹窗
    @State private var isRedeeming = false      // 控制验证过程中的加载状态
    // =========== 【1. 新增】状态变量 ===========
    // 用来标记：用户是否是因为想输入验证码而被强制去登录的
    @State private var pendingRedeemAfterLogin = false 

    var body: some View {
        ZStack {
            // 1. 使用系统分组背景色 (Light: 浅灰, Dark: 纯黑)
            Color(UIColor.systemGroupedBackground).ignoresSafeArea()
            
            VStack(spacing: 25) {
                // 标题
                VStack(spacing: 10) {
                    Text("今日免费点数已用完😭")
                        .font(.largeTitle.bold())
                        // 2. 自动适配文字颜色
                        .foregroundColor(.primary)
                        .onTapGesture {
                            tapCount += 1
                            if tapCount >= 5 { // 连续点击5次触发
                                tapCount = 0
                                // =========== 【2. 修改】这里改为调用处理函数 ===========
                                handleSecretTrigger()
                            }
                        }
                    
                    Text("请选择“专业版”订阅\n订阅成功后一个月内您将获得无限查询权限")
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
//                                .font(.title2.bold())
                                .foregroundColor(.primary) // 适配颜色
                            Text("仅能使用 \(authManager.isSubscribed ? "每日受限" : "每日有限次数") 查询")
                                .font(.subheadline)
                                .foregroundColor(.secondary) // 适配颜色
                        }
                        Spacer()
                        if !authManager.isSubscribed {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.title)
                        }
                    }
                    .padding()
                    // 3. 卡片背景色：Light模式下是白色，Dark模式下是深灰色
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(12)
                    // 添加轻微阴影，让白色卡片在浅灰色背景上突显
                    .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(authManager.isSubscribed ? Color.clear : Color.green, lineWidth: 2)
                    )
                }
                .buttonStyle(PlainButtonStyle())
                
                // 付费套餐卡片
                Button(action: {
                    handlePurchase()
                }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("专业版\n(订阅时长 1 Month)")
                                .font(.title2.bold())
                                .foregroundColor(.primary)
                            Text("不限次检索和查询所有数据")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text("¥6/月")
                                .font(.title2.bold())
                                // 价格颜色：深色模式用黄色醒目，浅色模式用蓝色或橙色更易读
                                // 这里使用 orange 兼顾两者
                                .foregroundColor(.orange)
                        }
                    }
                    .padding()
                    // 卡片背景色
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(12)
                    .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(authManager.isSubscribed ? Color.orange : Color.clear, lineWidth: 2)
                    )
                }
                .buttonStyle(PlainButtonStyle())
                
                Spacer()
                    
                // 【修改】底部链接区域，加入恢复购买按钮
                HStack(spacing: 20) {
                    // 恢复购买按钮
                    Button(action: {
                        performRestore()
                    }) {
                        Text("恢复购买")
                            .font(.footnote)
                            .foregroundColor(.blue) // 链接通常用蓝色
                            .underline()
                    }
                    .disabled(isRestoring || isPurchasing || isRedeeming)
                    
                    Text("|").foregroundColor(.secondary.opacity(0.5))
                    
                    Link("隐私政策", destination: URL(string: "https://sskeysskey.github.io/website/privacy.html")!)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text("|").foregroundColor(.secondary.opacity(0.5))
                    
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
                    Text("如果不选择付费，您将继续使用免费版，每日会有查询次数限制，如当天的用完，可第二天再来。")
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
            
            // 加载遮罩：同时处理支付、恢复、兑换的状态
            if isPurchasing || isRestoring || isRedeeming {
                Color.black.opacity(0.6).ignoresSafeArea()
                VStack {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    
                    if isRestoring {
                        Text("正在恢复购买...").foregroundColor(.white).padding(.top)
                    } else if isPurchasing {
                        Text("正在处理支付...").foregroundColor(.white).padding(.top)
                    } else if isRedeeming {
                        Text("正在验证代码...").foregroundColor(.white).padding(.top)
                    }
                }
            }
        }
        // 支付失败弹窗
        .alert("支付失败", isPresented: $showError) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        // 恢复结果弹窗
        .alert("恢复结果", isPresented: $showRestoreAlert) {
            Button("确定", role: .cancel) {
                // 如果恢复成功，用户点击确定后可以自动关闭页面，提升体验（可选）
                if authManager.isSubscribed {
                    dismiss()
                }
            }
        } message: {
            Text(restoreMessage)
        }
        // 【新增】内部通道输入弹窗
        .alert("内部访问", isPresented: $showRedeemSheet) {
            TextField("请输入访问代码", text: $redeemCodeInput)
            Button("取消", role: .cancel) {
                redeemCodeInput = "" // 取消时清空
            }
            Button("验证") {
                performRedeem()
            }
        } message: {
            Text("请输入特定的访问代码以解锁功能。")
        }
        // 【新增】兑换结果反馈弹窗
        .alert("验证结果", isPresented: $showRedeemResultAlert) {
            Button("确定", role: .cancel) {
                // 如果验证成功，关闭订阅页面
                if authManager.isSubscribed {
                    dismiss()
                }
            }
        } message: {
            Text(redeemMessage)
        }
        // 【新增】登录弹窗
        .sheet(isPresented: $showLoginSheet) {
            LoginView()
        }
        .onChange(of: authManager.isLoggedIn) { newValue in
            // 当监测到登录状态变为 true
            if newValue == true {
                // 1. 关闭登录弹窗
                if showLoginSheet {
                    showLoginSheet = false
                }
                
                // =========== 【4. 新增】登录成功后的自动跳转逻辑 ===========
                if pendingRedeemAfterLogin {
                    print("登录成功，检测到待处理的兑换请求，延迟弹出输入框...")
                    pendingRedeemAfterLogin = false // 重置标记
                    
                    // 【关键】必须加一点延迟，等待 LoginView 的关闭动画完成
                    // 否则 Sheet 关闭和 Alert 弹出同时发生可能会冲突导致 Alert 弹不出来
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        showRedeemSheet = true
                    }
                }
            }
        }
    }

    // =========== 【3. 新增】处理连按触发逻辑 ===========
    private func handleSecretTrigger() {
        if authManager.isLoggedIn {
            // 如果已登录，直接显示兑换输入框
            showRedeemSheet = true
        } else {
            // 如果未登录，先标记“待兑换”，然后弹出登录页
            print("触发彩蛋：未登录，跳转登录页")
            pendingRedeemAfterLogin = true
            showLoginSheet = true
        }
    }
    
    // 【修改】处理购买：先检查登录
    private func handlePurchase() {
        // 1. 检查是否已登录
        guard authManager.isLoggedIn else {
            // 未登录 -> 弹出登录页
            showLoginSheet = true
            return
        }
        
        // 2. 已登录 -> 执行原有购买逻辑
        isPurchasing = true
        Task {
            do {
                try await authManager.purchaseSubscription()
                await MainActor.run {
                    isPurchasing = false
                    // 【核心修改】
                    // 只有当订阅状态确实变为 true (购买成功) 时，才关闭弹窗。
                    // 如果用户取消了支付 (isSubscribed 仍为 false)，则不关闭，保留在当前页面。
                    if authManager.isSubscribed {
                        dismiss()
                    } else {
                        print("用户取消或未完成支付，保留订阅页面")
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
            // 未登录 -> 弹出登录页
            showLoginSheet = true
            return
        }
        
        // 2. 已登录 -> 执行原有恢复逻辑
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
    
    // 【新增】执行兑换码验证逻辑
    private func performRedeem() {
        // 简单的本地判空
        guard !redeemCodeInput.isEmpty else { return }
        
        // 2. 【新增】检查是否已登录 (如果服务器需要绑定User ID)
        guard authManager.isLoggedIn else {
            showLoginSheet = true
            return
        }
        
        isRedeeming = true
        
        Task {
            do {
                // 调用 AuthManager 的方法请求服务器
                let success = try await authManager.redeemInviteCode(redeemCodeInput)
                
                await MainActor.run {
                    isRedeeming = false
                    if success {
                        redeemMessage = "验证成功！您已获得无限访问权限。"
                        redeemCodeInput = "" // 清空输入
                    }
                    showRedeemResultAlert = true
                }
            } catch {
                await MainActor.run {
                    isRedeeming = false
                    // 显示具体的错误信息（例如：无效的邀请码）
                    redeemMessage = "验证失败: \(error.localizedDescription)"
                    showRedeemResultAlert = true
                }
            }
        }
    }
}
