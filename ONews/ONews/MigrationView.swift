import SwiftUI

struct MigrationView: View {
    let config: MigrationConfig
    let onDismiss: (() -> Void)?  // nil 表示不可关闭(强制模式)
    
    @AppStorage("isGlobalEnglishMode") private var isEnglish = false
    @State private var animateIn = false
    
    private var title: String { isEnglish ? config.titleEn : config.titleZh }
    private var subtitle: String { isEnglish ? config.subtitleEn : config.subtitleZh }
    private var paragraphs: [String] { isEnglish ? config.contentEn : config.contentZh }
    private var subNotice: String { isEnglish ? config.subscriptionNoticeEn : config.subscriptionNoticeZh }
    private var primaryText: String { isEnglish ? config.primaryButtonEn : config.primaryButtonZh }
    private var secondaryText: String { isEnglish ? config.secondaryButtonEn : config.secondaryButtonZh }
    
    var body: some View {
        ZStack {
            // 不可点穿的背景
            Color(.systemBackground)
                .ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 24) {
                    // 顶部 Logo + 动画图标
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(colors: [.blue, .purple], 
                                                     startPoint: .topLeading, 
                                                     endPoint: .bottomTrailing))
                                .frame(width: 100, height: 100)
                                .shadow(color: .blue.opacity(0.3), radius: 20, y: 8)
                            
                            Image(systemName: "arrow.up.right.circle.fill")
                                .font(.system(size: 50, weight: .bold))
                                .foregroundColor(.white)
                                .scaleEffect(animateIn ? 1.0 : 0.5)
                                .animation(.spring(response: 0.6, dampingFraction: 0.6).delay(0.2), 
                                          value: animateIn)
                        }
                        .padding(.top, 20)
                        
                        Text(title)
                            .font(.system(size: 30, weight: .black, design: .rounded))
                            .multilineTextAlignment(.center)
                        
                        Text(subtitle)
                            .font(.headline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    
                    // 正文段落
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(paragraphs.indices, id: \.self) { idx in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundColor(.blue)
                                    .font(.system(size: 16))
                                    .padding(.top, 2)
                                
                                Text(paragraphs[idx])
                                    .font(.body)
                                    .foregroundColor(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    .padding(.horizontal, 20)
                    
                    // 订阅迁移提示(单独高亮一块)
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "crown.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 18))
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(isEnglish ? "About Your Subscription" : "关于您的订阅")
                                .font(.subheadline.bold())
                                .foregroundColor(.orange)
                            Text(subNotice)
                                .font(.footnote)
                                .foregroundColor(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(16)
                    .background(Color.orange.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                    )
                    .cornerRadius(14)
                    .padding(.horizontal, 20)
                    
                    // 按钮区
                    VStack(spacing: 12) {
                        // 主按钮:跳转下载
                        Button(action: openNewApp) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.down.app.fill")
                                Text(primaryText)
                                    .fontWeight(.bold)
                            }
                            .font(.system(size: 17))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(
                                LinearGradient(colors: [.blue, .purple], 
                                              startPoint: .leading, endPoint: .trailing)
                            )
                            .cornerRadius(14)
                            .shadow(color: .blue.opacity(0.4), radius: 12, y: 6)
                        }
                        
                        // 次按钮:仅软模式显示
                        if let onDismiss = onDismiss {
                            Button(action: onDismiss) {
                                Text(secondaryText)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
            }
        }
        .onAppear {
            withAnimation { animateIn = true }
        }
        .interactiveDismissDisabled(true)  // 禁止下滑关闭
    }
    
    private func openNewApp() {
        // 优先 itms-apps,失败兜底 https
        if let url = URL(string: config.newAppUrl), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else if let fallback = URL(string: config.fallbackUrl) {
            UIApplication.shared.open(fallback)
        }
    }
}