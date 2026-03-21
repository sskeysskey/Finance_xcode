import SwiftUI

struct PredictionCardView: View {
    let item: PredictionItem
    let isSubscribed: Bool
    let onLockedTap: () -> Void
    
    @State private var showDetail = false
    
    private var showBlur: Bool { item.isHidden && !isSubscribed }
    private var canExpand: Bool { !item.displayOptions.isEmpty }
    
    var body: some View {
        Button {
            if showBlur {
                onLockedTap()
            } else if canExpand {
                showDetail = true
            }
        } label: {
            cardContent
        }
        .buttonStyle(CardButtonStyle())
        .sheet(isPresented: $showDetail) {
            PredictionDetailView(item: item)
        }
    }
    
    // MARK: - 卡片内容
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 顶部：subtype 标签
            HStack {
                Text(item.subtype.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.tagBg)
                    .cornerRadius(6)
                
                Spacer()
                
                // 来源小标
                Text(item.source.rawValue)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            
            // 标题
            Text(item.name)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            
            // 选项区域（最多显示2个）
            ZStack {
                VStack(spacing: 10) {
                    let displayOpts = Array(item.displayOptions.prefix(2))
                    ForEach(Array(displayOpts.enumerated()), id: \.element.id) { idx, opt in
                        OptionRow(
                            option: opt,
                            color: Color.barColors[idx % Color.barColors.count]
                        )
                    }
                }
                
                // 毛玻璃遮罩
                if showBlur {
                    blurOverlay
                }
            }
            
            // 底部信息栏
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("\(Fmt.volume(item.volume)) vol")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                
                if let endDate = item.endDate {
                    Text("·").foregroundColor(.secondary)
                    Text(endDate)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                HStack(spacing: 4) {
                    Text("\(item.marketCount)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                    Text(item.marketCount == 1 ? "market" : "markets")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                
                if canExpand {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.5))
                }
            }
        }
        .padding(16)
        .background(Color.cardBg)
        .cornerRadius(16)
    }
    
    // MARK: - 毛玻璃遮罩
    private var blurOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
            
            VStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.8))
                Text("订阅解锁详情")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
    }
}

// MARK: - 选项行
struct OptionRow: View {
    let option: PredictionOption
    let color: Color
    
    private var barWidth: CGFloat {
        guard let val = Fmt.percentValue(option.value) else { return 0.05 }
        return max(0.03, val / 100.0)
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // 标签 + 进度条
            VStack(alignment: .leading, spacing: 6) {
                Text(option.displayLabel)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: geo.size.width * barWidth, height: 4)
                }
                .frame(height: 4)
            }
            
            // Change 标签
            if let change = option.change, !change.isEmpty {
                Text(change)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(change.contains("▲") ? .green : change.contains("▼") ? .red : .secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            
            // 百分比 pill
            Text(option.value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.pillBorder, lineWidth: 1.5)
                )
                .fixedSize()
        }
    }
}

// MARK: - 卡片按钮样式
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.spring(response: 0.3), value: configuration.isPressed)
    }
}