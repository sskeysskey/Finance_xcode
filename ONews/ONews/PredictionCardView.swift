import SwiftUI

struct PredictionCardView: View {
    let item: PredictionItem
    let isSubscribed: Bool
    let onLockedTap: () -> Void
    var onNavigateToDetail: (() -> Void)? = nil

    @EnvironmentObject var transManager: TranslationManager
    // ❌ 移除: @State private var showDetail = false
    
    private var showBlur: Bool { item.isHidden && !isSubscribed }
    private var canExpand: Bool { !item.displayOptions.isEmpty }
    
    var body: some View {
        Button {
            if showBlur {
                onLockedTap()
            } else if canExpand {
                onNavigateToDetail?() // ✅ 改为调用回调
            }
        } label: {
            cardContent
        }
        .buttonStyle(CardButtonStyle())
        // ✅ 这里不再有任何 .navigationDestination 修饰符
    }
    
    // MARK: - 卡片内容
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 顶部：type 和 subtype 标签
            HStack(spacing: 6) {
                // 如果 type 和 subtype 不一样，则先显示 type（大分类）
                if item.type.lowercased() != item.subtype.lowercased() {
                    tagLabel(transManager.type(item.type))
                }
                tagLabel(transManager.subtype(item.subtype))
                
                Spacer()
                
                // 来源小标
                Text(item.source.rawValue)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
            }
            
            Text(transManager.name(item.name))
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.primary)
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
                // ✅ 修复长按透视bug：当需要遮挡时，直接把底层内容本身模糊掉，彻底防止透视
                .blur(radius: showBlur ? 10 : 0)
                
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
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.cardBg)
                .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
        )
    }
    
    // 🆕 标签抽成方法
    private func tagLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundColor(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.tagBg)
            )
    }
    
    private var blurOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
            
            VStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.primary.opacity(0.8))
                Text("订阅解锁详情")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary.opacity(0.7))
            }
        }
        // ✅ 修复尺寸bug：使用负边距让遮罩稍微放大，确保边缘完全盖住底层内容
        .padding(-8)
    }
}

// MARK: - 选项行
struct OptionRow: View {
    let option: PredictionOption
    let color: Color

    @EnvironmentObject var transManager: TranslationManager
    
    private var barWidth: CGFloat {
        guard let val = Fmt.percentValue(option.value) else { return 0.05 }
        return max(0.03, val / 100.0)
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // 标签 + 进度条
            VStack(alignment: .leading, spacing: 6) {
                Text(transManager.option(option.displayLabel))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
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
                .foregroundColor(.primary)
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