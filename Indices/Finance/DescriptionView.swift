import SwiftUI

// MARK: - DescriptionView
struct DescriptionView: View {
    let descriptions: (String, String) // (description1, description2)
    
    // 【修改 1】: 移除 let isDarkMode: Bool
    // 不需要显式传入，SwiftUI 会自动处理
    
    private func formatDescription(_ text: String) -> String {
        var formattedText = text
        
        // 1. 处理多空格为单个换行
        let spacePatterns = ["    ", "  "]
        for pattern in spacePatterns {
            formattedText = formattedText.replacingOccurrences(of: pattern, with: "\n")
        }
        
        // 2. 统一处理所有需要换行的标记符号
        let patterns = [
            "([^\\n])(\\d+、)",          // 中文数字序号
            "([^\\n])(\\d+\\.)",         // 英文数字序号
            "([^\\n])([一二三四五六七八九十]+、)", // 中文数字
            "([^\\n])(- )"               // 新增破折号标记
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                formattedText = regex.stringByReplacingMatches(
                    in: formattedText,
                    options: [],
                    range: NSRange(location: 0, length: formattedText.utf16.count),
                    withTemplate: "$1\n$2"
                )
            }
        }
        
        // 3. 清理多余换行
        while formattedText.contains("\n\n") {
            formattedText = formattedText.replacingOccurrences(of: "\n\n", with: "\n")
        }
        
        return formattedText
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(formatDescription(descriptions.0))
                        .font(.title2)
                        // 【修改 2】: 使用 .primary
                        // .primary 在浅色模式下是黑色，深色模式下是白色
                        .foregroundColor(.primary)
                        .padding(.bottom, 18)
                    
                    Text(formatDescription(descriptions.1))
                        .font(.title2)
                        // 【修改 3】: 同上
                        .foregroundColor(.primary)
                }
                .padding()
            }
            Spacer()
        }
        .navigationBarTitle("Description", displayMode: .inline)
        // 【修改 4】: 使用系统背景色
        // systemBackground 在浅色模式下是白色，深色模式下是黑色
        .background(Color(UIColor.systemBackground).edgesIgnoringSafeArea(.all))
    }
}