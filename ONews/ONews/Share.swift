import SwiftUI

// 1. 自定义分享菜单
struct CustomShareSheet: View {
    var onWeChatAction: () -> Void
    var onSystemShareAction: () -> Void
    @Environment(\.dismiss) var dismiss
    
    // 监听语言变化以实时刷新 UI
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    var body: some View {
        VStack(spacing: 20) {
            // 使用修正后的 Localized 属性
            Text(Localized.shareTo)
                .font(.headline)
                .padding(.top, 20)
            
            HStack(spacing: 40) {
                // 自定义微信按钮
                ShareIconBtn(
                    icon: "message.fill", // 这里用SF Symbol代替，实际可用微信图标资源
                    color: Color.green,
                    title: Localized.weChat
                ) {
                    dismiss()
                    onWeChatAction()
                }
                
                // 更多（调用系统分享）
                ShareIconBtn(
                    icon: "ellipsis.circle.fill",
                    color: Color.gray,
                    title: Localized.more
                ) {
                    dismiss()
                    onSystemShareAction()
                }
            }
            .padding(.vertical, 20)
            
            Spacer()
        }
        .presentationDetents([.height(220)]) 
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
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .frame(width: 80) 
                    .multilineTextAlignment(.center)
            }
        }
    }
}

// 2. 微信手动粘贴引导页
struct WeChatGuideView: View {
    @Environment(\.dismiss) var dismiss
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    var body: some View {
        VStack(spacing: 25) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)
                .padding(.top, 40)
            
            Text(Localized.contentCopied)
                .font(.title2)
                .fontWeight(.bold)
            
            Text(Localized.weChatLimitHint)
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
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
                // 这里可以加一个提示，或者打印
                print(Localized.weChatNotInstalled)
            }
        }
    }
}