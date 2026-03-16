import SwiftUI

struct PredictionDetailView: View {
    let item: PredictionItem
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // MARK: - 顶部信息
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(item.subtype.uppercased())
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
                            
                            Text(item.name)
                                .font(.title2.bold())
                                .foregroundColor(.white)
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
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(.blue)
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
    
    private var barWidth: CGFloat {
        guard let val = Fmt.percentValue(option.value) else { return 0.05 }
        return max(0.03, val / 100.0)
    }
    
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                // 排名
                Text("#\(rank)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
                    .frame(width: 32, alignment: .leading)
                
                // 标签
                Text(option.displayLabel)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(2)
                
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
                    .foregroundColor(.white)
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