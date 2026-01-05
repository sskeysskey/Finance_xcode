import SwiftUI

// 1. 自定义分享菜单
struct CustomShareSheet: View {
    var onWeChatAction: () -> Void
    var onSystemShareAction: () -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("分享至")
                .font(.headline)
                .padding(.top, 20)
            
            HStack(spacing: 40) {
                // 自定义微信按钮
                ShareIconBtn(
                    icon: "message.fill", // 这里用SF Symbol代替，实际可用微信图标资源
                    color: Color.green,
                    title: "微信"
                ) {
                    dismiss()
                    onWeChatAction()
                }
                
                // 更多（调用系统分享）
                ShareIconBtn(
                    icon: "ellipsis.circle.fill",
                    color: Color.gray,
                    title: "更多"
                ) {
                    dismiss()
                    onSystemShareAction()
                }
            }
            .padding(.vertical, 20)
            
            Spacer()
        }
        .presentationDetents([.height(200)]) // iOS 16+ 支持，控制弹窗高度
        .presentationDragIndicator(.visible)
    }
}

// 辅助按钮视图
struct ShareIconBtn: View {
    let icon: String
    let color: Color
    let title: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.1))
                        .frame(width: 60, height: 60)
                    Image(systemName: icon)
                        .font(.title)
                        .foregroundColor(color)
                }
                Text(title)
                    .font(.caption)
                    .foregroundColor(.primary)
            }
        }
    }
}

// 2. 微信手动粘贴引导页
struct WeChatGuideView: View {
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 25) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)
                .padding(.top, 40)
            
            Text("文章内容已复制")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("由于微信限制请手动去微信粘贴文章内容")
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .foregroundColor(.secondary)
        }
        .presentationDetents([.medium])
    }
    
    private func openWeChat() {
        // 尝试打开微信 URL Scheme
        if let url = URL(string: "wechat://") {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
            } else {
                // 如果没装微信的备选逻辑，这里简单打印
                print("未安装微信")
            }
        }
    }
}
