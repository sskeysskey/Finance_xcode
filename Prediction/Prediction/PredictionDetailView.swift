import SwiftUI

struct PredictionDetailView: View {
    let item: PredictionItem
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var transManager: TranslationManager // ← 新增

    var body: some View {
        // ✅ 移除了 NavigationStack，直接返回 ZStack
        ZStack {
            Color.appBg.ignoresSafeArea()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // MARK: - 顶部信息
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 6) {
                            // 如果 type 和 subtype 不一样，则先显示 type（大分类）
                            if item.type.lowercased() != item.subtype.lowercased() {
                                Text(transManager.type(item.type).uppercased())
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.tagBg)
                                    .cornerRadius(6)
                            }
                            
                            // 显示 subtype（小分类）
                            Text(transManager.subtype(item.subtype).uppercased())
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.tagBg)
                                .cornerRadius(6)
                            
                            Spacer()
                            
                            Text(item.source.rawValue)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                        
                        // 替换 name 展示:
                        Text(transManager.name(item.name))
                            .font(.title2.bold())
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 16)
                    
                    // MARK: - 所有选项
                    VStack(spacing: 10) {
                        ForEach(Array(item.displayOptions.enumerated()), id: \.element.id) { idx, option in
                            DetailOptionRow(
                                option: option,
                                rank: idx + 1,
                                color: Color.barColors[idx % Color.barColors.count]
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    
                    // MARK: - 底部元数据
                    VStack(spacing: 10) {
                        metaRow(icon: "chart.bar.fill", text: "Volume: \(Fmt.volume(item.volume))")
                        
                        if let endDate = item.endDate {
                            metaRow(icon: "calendar", text: "Ends: \(endDate)")
                        }
                        
                        metaRow(icon: "list.number", text: "\(item.marketCount) \(item.marketCount == 1 ? "market" : "markets")")
                    }
                    .padding(16)
                    .background(Color.cardBg)
                    .cornerRadius(14)
                    .padding(.horizontal, 16)
                    
                    Spacer().frame(height: 50)
                }
                .padding(.top, 16)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // ✅ 新增：在导航栏右侧添加中英切换按钮
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        transManager.toggle()
                    }
                } label: {
                    Text(transManager.language == .chinese ? "EN" : "中")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle().fill(Color.primary.opacity(0.1))
                        )
                }
            }
        }
    }
    
    private func metaRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}

// MARK: - 详情页选项行
struct DetailOptionRow: View {
    let option: PredictionOption
    let rank: Int
    let color: Color

    @EnvironmentObject var transManager: TranslationManager // ← 新增
    
    private var barWidth: CGFloat {
        guard let val = Fmt.percentValue(option.value) else { return 0.05 }
        return max(0.03, val / 100.0)
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // 如果想要顶部对齐，可以将原来的 HStack(spacing: 12) 改为：
            HStack(alignment: .top, spacing: 12) {
                // 排名
                Text("#\(rank)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
                    .frame(width: 32, alignment: .leading)
                    .padding(.top, 2) // 稍微往下移一点，让它和右侧多行文字的第一行视觉对齐
                
                // 标签
                Text(transManager.option(option.displayLabel)) 
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(nil) // ✅ 移除行数限制，允许无限换行（可以直接删掉这行，或者写 nil）
                    .fixedSize(horizontal: false, vertical: true) // ✅ 强制允许垂直方向完整展开
                
                Spacer()
                
                // 变化值
                if let change = option.change, !change.isEmpty {
                    Text(change)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(changeColor(change))
                        .fixedSize()
                }
                
                // 百分比
                Text(option.value)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(color.opacity(0.15))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(color.opacity(0.4), lineWidth: 1)
                    )
                    .fixedSize()
            }
            
            // 进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.15))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: geo.size.width * barWidth, height: 4)
                }
            }
            .frame(height: 4)
        }
        .padding(14)
        .background(Color.cardBg)
        .cornerRadius(12)
    }
    
    private func changeColor(_ change: String) -> Color {
        if change.contains("▲") { return .green }
        if change.contains("▼") { return .red }
        return .secondary
    }
}