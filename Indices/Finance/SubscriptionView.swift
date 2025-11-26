import SwiftUI

struct SubscriptionView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.dismiss) var dismiss
    
    // 支付相关状态
    @State private var isPurchasing = false
    @State private var showError = false
    @State private var errorMessage = ""
    
    // 【新增】恢复购买相关状态
    @State private var isRestoring = false
    @State private var showRestoreAlert = false
    @State private var restoreMessage = ""
    
    var body: some View {
        ZStack {
            Color.viewBackground.ignoresSafeArea()
            
            VStack(spacing: 25) {
                // 标题
                VStack(spacing: 10) {
                    Text("选择您的订阅套餐")
                        .font(.largeTitle.bold())
                        .foregroundColor(.white)
                    Text("支持正版，获取无限查询权限。")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                .padding(.top, 40)
                
                // 免费套餐卡片
                Button(action: {
                    // 选择免费，直接关闭
                    dismiss()
                }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("免费版")
                                .font(.title2.bold())
                            Text("仅浏览 \(authManager.isSubscribed ? "每日受限" : "数据") 查询")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        if !authManager.isSubscribed {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.title)
                        }
                    }
                    .padding()
                    .background(Color(white: 0.15))
                    .cornerRadius(12)
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
                            Text("专业版 (订阅时长 1 Month)")
                                .font(.title2.bold())
                                .foregroundColor(.white)
                            Text("无限检索数据")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text("¥6")
                                .font(.title2.bold())
                                .foregroundColor(.yellow)
                            Text("/月")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    .padding()
                    .background(Color(white: 0.15))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(authManager.isSubscribed ? Color.yellow : Color.clear, lineWidth: 2)
                    )
                }
                .buttonStyle(PlainButtonStyle())
                
                Spacer()
                    
                // 【修改】底部链接区域，加入恢复购买按钮
                HStack(spacing: 20) {
                    
                    
                    // 【新增】恢复购买按钮
                    Button(action: {
                        performRestore()
                    }) {
                        Text("恢复购买")
                            .font(.footnote)
                            .foregroundColor(.white) //稍微高亮一点，方便用户发现
                            .underline()
                    }
                    .disabled(isRestoring || isPurchasing)
                    
                    // 分隔符
                    Text("|").foregroundColor(.gray.opacity(0.5))
                    
                    Link("隐私政策", destination: URL(string: "https://sskeysskey.github.io/website/privacy.html")!)
                        .font(.footnote)
                        .foregroundColor(.gray)

                    // 分隔符
                    Text("|").foregroundColor(.gray.opacity(0.5))
                    
                    Link("使用条款 (EULA)", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                        .font(.footnote)
                        .foregroundColor(.gray)
                }
                
                Spacer()
                
                // 底部说明
                if authManager.isSubscribed {
                    Text("您当前是尊贵的专业版用户")
                        .foregroundColor(.yellow)
                        .padding()
                } else {
                    Text("如果不选择付费，您将继续使用免费版，每日会有查询次数限制，如当天的用完，可第二天再来。")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                
                Button("关闭") {
                    dismiss()
                }
                .foregroundColor(.white.opacity(0.6))
                .padding(.bottom)
            }
            .padding(.horizontal)
            
            // 【修改】加载遮罩：同时处理支付和恢复的状态
            if isPurchasing || isRestoring {
                Color.black.opacity(0.6).ignoresSafeArea()
                VStack {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    // 根据状态显示不同文案
                    Text(isRestoring ? "正在恢复购买..." : "正在处理支付...")
                        .foregroundColor(.white)
                        .padding(.top)
                }
            }
        }
        // 支付失败弹窗
        .alert("支付失败", isPresented: $showError) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        // 【新增】恢复结果弹窗
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