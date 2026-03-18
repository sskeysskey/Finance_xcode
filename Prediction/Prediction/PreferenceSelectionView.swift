import SwiftUI

struct PreferenceSelectionView: View {
    @EnvironmentObject var syncManager: SyncManager
    @EnvironmentObject var prefManager: PreferenceManager
    @Environment(\.dismiss) var dismiss
    
    let isOnboarding: Bool
    var onComplete: (() -> Void)? = nil
    
    @State private var expandedTypes: Set<String> = []
    
    private var categories: [(type: String, subtypes: [String])] {
        let all = syncManager.polymarketItems + syncManager.kalshiItems
        return PreferenceManager.extractCategories(from: all)
    }
    
    private var allSubtypes: [String] {
        categories.flatMap { $0.subtypes }
    }
    
    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // 顶部标题
                VStack(spacing: 8) {
                    Text(isOnboarding ? "选择您感兴趣的话题" : "偏好设置")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                    Text("选择您想追踪的预测类别")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 20)
                .padding(.bottom, 16)
                
                // 全选/全不选
                HStack {
                    Button("全选") {
                        withAnimation { prefManager.selectAll(subtypes: allSubtypes) }
                    }
                    .font(.caption.bold())
                    .foregroundColor(.blue)
                    
                    Text("·").foregroundColor(.secondary)
                    
                    Button("全不选") {
                        withAnimation { prefManager.selectedSubtypes.removeAll() }
                    }
                    .font(.caption.bold())
                    .foregroundColor(.blue)
                    
                    Spacer()
                    
                    Text("已选 \(prefManager.selectedSubtypes.count) 项")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                
                // 类别列表
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(categories, id: \.type) { category in
                            CategoryCard(
                                typeName: category.type,
                                subtypes: category.subtypes,
                                isExpanded: expandedTypes.contains(category.type),
                                selectedSubtypes: $prefManager.selectedSubtypes,
                                onToggleExpand: {
                                    withAnimation(.spring(response: 0.3)) {
                                        if expandedTypes.contains(category.type) {
                                            expandedTypes.remove(category.type)
                                        } else {
                                            expandedTypes.insert(category.type)
                                        }
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 100)
                }
                
                Spacer()
            }
            
            // 底部确认按钮
            VStack {
                Spacer()
                Button {
                    prefManager.save()
                    if isOnboarding {
                        onComplete?()
                    } else {
                        dismiss()
                    }
                } label: {
                    Text(isOnboarding ? "开始探索" : "保存设置")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background {
                            if prefManager.selectedSubtypes.isEmpty {
                                Color.gray
                            } else {
                                LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing)
                            }
                        }
                        .cornerRadius(16)
                }
                .disabled(prefManager.selectedSubtypes.isEmpty)
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
                .background(
                    LinearGradient(colors: [Color.appBg.opacity(0), Color.appBg],
                                   startPoint: .top, endPoint: .bottom)
                    .frame(height: 100)
                    .allowsHitTesting(false)
                )
            }
        }
        .navigationBarBackButtonHidden(isOnboarding)
        .onAppear {
            // 首次进入自动展开所有类别
            expandedTypes = Set(categories.map { $0.type })
        }
        // 【新增】监听数据变化，如果数据突然加载进来了，也自动展开
        .onChange(of: categories.count) { _ in
            if expandedTypes.isEmpty {
                expandedTypes = Set(categories.map { $0.type })
            }
        }
    }
}

// MARK: - 类别卡片
struct CategoryCard: View {
    let typeName: String
    let subtypes: [String]
    let isExpanded: Bool
    @Binding var selectedSubtypes: Set<String>
    let onToggleExpand: () -> Void
    
    private var selectedCount: Int {
        subtypes.filter { selectedSubtypes.contains($0) }.count
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 大类标题（不可选）
            Button(action: onToggleExpand) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(typeName)
                            .font(.headline)
                            .foregroundColor(.white)
                        Text("\(selectedCount)/\(subtypes.count) 已选")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                }
                .padding(16)
            }
            
            // 子类标签（可选）
            if isExpanded {
                let columns = [GridItem(.adaptive(minimum: 100, maximum: 200), spacing: 10)]
                
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(subtypes, id: \.self) { subtype in
                        let isSelected = selectedSubtypes.contains(subtype)
                        
                        Button {
                            withAnimation(.spring(response: 0.25)) {
                                if isSelected {
                                    selectedSubtypes.remove(subtype)
                                } else {
                                    selectedSubtypes.insert(subtype)
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 14))
                                    .foregroundColor(isSelected ? .blue : .secondary)
                                
                                Text(subtype)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(isSelected ? .white : .secondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(isSelected ? Color.blue.opacity(0.2) : Color.white.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(isSelected ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 1)
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .background(Color.cardBg)
        .cornerRadius(16)
    }
}
