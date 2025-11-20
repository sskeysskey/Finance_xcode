import SwiftUI

struct SubscriptionView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.dismiss) var dismiss
    
    @State private var isPurchasing = false
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        ZStack {
            Color.viewBackground.ignoresSafeArea()
            
            VStack(spacing: 25) {
                // 标题
                VStack(spacing: 10) {
                    Text("选择您的计划")
                        .font(.largeTitle.bold())
                        .foregroundColor(.white)
                    Text("支持正版，获取最新资讯")
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
                            Text("仅浏览 \(authManager.isSubscribed ? "全部" : "历史") 文章")
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
                            Text("专业版")
                                .font(.title2.bold())
                                .foregroundColor(.white)
                            Text("解锁所有最新文章")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text("¥10")
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
                
                // 底部说明
                if authManager.isSubscribed {
                    Text("您当前是尊贵的专业版用户")
                        .foregroundColor(.yellow)
                        .padding()
                } else {
                    Text("如果不选择付费，您将继续使用免费版，最新文章将保持锁定状态。")
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
            
            // 加载遮罩
            if isPurchasing {
                Color.black.opacity(0.6).ignoresSafeArea()
                VStack {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text("正在处理支付...")
                        .foregroundColor(.white)
                        .padding(.top)
                }
            }
        }
        .alert("支付失败", isPresented: $showError) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }
    
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
}
