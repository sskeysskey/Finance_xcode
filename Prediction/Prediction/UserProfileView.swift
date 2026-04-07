import SwiftUI

// MARK: - 日期格式化工具函数
func formatDateLocal(_ isoString: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: isoString) {
        let displayFormatter = DateFormatter()
        displayFormatter.dateStyle = .medium
        displayFormatter.timeStyle = .short
        displayFormatter.locale = Locale.current
        return displayFormatter.string(from: date)
    }
    let fallbackFormatter = ISO8601DateFormatter()
    if let date = fallbackFormatter.date(from: isoString) {
        let displayFormatter = DateFormatter()
        displayFormatter.dateStyle = .medium
        return displayFormatter.string(from: date)
    }
    return String(isoString.prefix(10))
}

// MARK: - 用户个人中心视图
struct UserProfileView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.dismiss) var dismiss
    
    // 删除账号相关状态
    @State private var showDeleteAccountConfirmation = false
    @State private var isDeletingAccount = false
    @State private var deleteErrorMessage = ""
    @State private var showDeleteError = false
    
    var body: some View {
        NavigationView {
            ZStack {
                List {
                    // MARK: 1. 用户信息
                    Section {
                        HStack {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 60))
                                .foregroundColor(.gray)
                            VStack(alignment: .leading, spacing: 4) {
                                if authManager.isSubscribed {
                                    Text("专业版会员")
                                        .font(.subheadline)
                                        .foregroundColor(.yellow)
                                        .bold()
                                    if let dateStr = authManager.subscriptionExpiryDate {
                                        Text("有效期至: \(formatDateLocal(dateStr))")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                } else {
                                    Text("免费用户")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                
                                if let userId = authManager.userIdentifier {
                                    Text("ID: \(userId.prefix(6))...")
                                        .font(.caption2)
                                        .foregroundColor(.gray)
                                } else {
                                    Text("未登录")
                                        .font(.caption2)
                                        .foregroundColor(.gray)
                                }
                            }
                            .padding(.leading, 8)
                        }
                        .padding(.vertical, 10)
                    }
                    
                    // MARK: 2. 升级入口（仅非会员显示）
                    if !authManager.isSubscribed {
                        Section {
                            Button {
                                // 【修复】先关闭当前的个人中心 Sheet，延迟后再呼出订阅 Sheet
                                dismiss() // 1. 先关闭个人中心
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    authManager.showSubscriptionSheet = true // 2. 等待关闭动画（约0.3秒）完成后，再触发订阅页
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "crown.fill")
                                        .foregroundColor(.orange)
                                    Text("升级专业版")
                                        .foregroundColor(.primary)
                                        .fontWeight(.medium)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                    }
                    
                    // MARK: 3. 支持与反馈
                    Section(header: Text("支持与反馈")) {
                        Button {
                            let email = "728308386@qq.com"
                            if let url = URL(string: "mailto:\(email)") {
                                if UIApplication.shared.canOpenURL(url) {
                                    UIApplication.shared.open(url)
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "envelope.fill")
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("问题反馈")
                                        .foregroundColor(.primary)
                                    Text("728308386@qq.com")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = "728308386@qq.com"
                            } label: {
                                Label("复制邮箱地址", systemImage: "doc.on.doc")
                            }
                        }
                    }
                    
                    // MARK: 4. 账户操作
                    Section {
                        if authManager.isLoggedIn {
                            Button(role: .destructive) {
                                authManager.signOut()
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: "rectangle.portrait.and.arrow.right")
                                    Text("退出登录")
                                }
                            }
                            
                            Button(role: .destructive) {
                                showDeleteAccountConfirmation = true
                            } label: {
                                HStack {
                                    Image(systemName: "trash.fill")
                                    Text("删除账号")
                                }
                            }
                        } else {
                            Text("您当前使用的是匿名模式")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .navigationTitle("账户")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("关闭") { dismiss() }
                    }
                }
                .alert("确认删除账号", isPresented: $showDeleteAccountConfirmation) {
                    Button("取消", role: .cancel) { }
                    Button("永久删除", role: .destructive) {
                        performAccountDeletion()
                    }
                } message: {
                    Text("此操作不可逆。您的所有数据和订阅状态将从我们的服务器上永久删除。")
                }
                .alert("删除失败", isPresented: $showDeleteError) {
                    Button("确定", role: .cancel) { }
                } message: {
                    Text(deleteErrorMessage)
                }
                
                // 删除中遮罩
                if isDeletingAccount {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    VStack(spacing: 20) {
                        ProgressView().scaleEffect(1.5).tint(.primary)
                        Text("正在删除账号...").foregroundColor(.primary)
                    }
                    .zIndex(200)
                }
            }
        }
    }
    
    private func performAccountDeletion() {
        isDeletingAccount = true
        Task {
            do {
                try await authManager.deleteAccount()
                await MainActor.run {
                    isDeletingAccount = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isDeletingAccount = false
                    deleteErrorMessage = error.localizedDescription
                    showDeleteError = true
                }
            }
        }
    }
}