import SwiftUI
import Foundation
import Combine

@MainActor
class PreferenceManager: ObservableObject {
    
    @Published var selectedSubtypes: Set<String> = []
    @Published var knownSubtypes: Set<String> = []
    
    // ✅ 新增：新分类检测结果（替代原来的弹窗机制，改为红点提示）
    @Published var pendingNewCategories: [(type: String, subtypes: [String])] = []
    
    /// 是否存在尚未被用户确认的新分类
    var hasNewCategories: Bool { !pendingNewCategories.isEmpty }
    
    /// 所有待确认的新 subtype 集合（用于在偏好页高亮显示）
    var allPendingNewSubtypes: Set<String> {
        Set(pendingNewCategories.flatMap { $0.subtypes })
    }
    
    private let storageKey = "Pred_SelectedSubtypes"
    private let knownStorageKey = "Pred_KnownSubtypes"
    
    init() {
        if let saved = UserDefaults.standard.array(forKey: storageKey) as? [String] {
            selectedSubtypes = Set(saved)
        }
        if let savedKnown = UserDefaults.standard.array(forKey: knownStorageKey) as? [String] {
            knownSubtypes = Set(savedKnown)
        }
    }
    
    func save() {
        UserDefaults.standard.set(Array(selectedSubtypes), forKey: storageKey)
    }
    
    func saveKnown() {
        UserDefaults.standard.set(Array(knownSubtypes), forKey: knownStorageKey)
    }
    
    func toggle(_ subtype: String) {
        if selectedSubtypes.contains(subtype) {
            selectedSubtypes.remove(subtype)
        } else {
            selectedSubtypes.insert(subtype)
        }
    }
    
    func selectAll(subtypes: [String]) {
        selectedSubtypes = Set(subtypes)
    }
    
    var hasPreferences: Bool { !selectedSubtypes.isEmpty }
    
    // MARK: - 新分类检测
    
    /// ✅ 统一入口：更新新分类检测状态（替代原来的弹窗触发逻辑）
    func updateNewCategoryStatus(from items: [PredictionItem]) {
        migrateKnownSubtypesIfNeeded(from: items)
        pendingNewCategories = detectNewSubtypes(from: items)
    }
    
    /// 老用户迁移：如果已有偏好但 knownSubtypes 为空，说明是从旧版本升级的
    /// 此时将当前所有 subtype 视为"已知"，避免误触发
    func migrateKnownSubtypesIfNeeded(from items: [PredictionItem]) {
        if hasPreferences && knownSubtypes.isEmpty {
            markAllAsKnown(from: items)
        }
    }
    
    /// 检测当前数据中尚未被用户见过的新 subtype，按 type 分组返回
    func detectNewSubtypes(from items: [PredictionItem]) -> [(type: String, subtypes: [String])] {
        // ✅ 修复：数据为空时绝不返回"新分类"，防止中间状态误触发
        guard hasPreferences, !items.isEmpty else { return [] }
        
        let allCategories = PreferenceManager.extractCategories(from: items)
        var result: [(type: String, subtypes: [String])] = []
        
        for category in allCategories {
            let newSubs = category.subtypes.filter { !knownSubtypes.contains($0) }
            if !newSubs.isEmpty {
                result.append((type: category.type, subtypes: newSubs))
            }
        }
        return result
    }
    
    func markAllAsKnown(from items: [PredictionItem]) {
        let allSubs = Set(items.map { $0.subtype })
        knownSubtypes.formUnion(allSubs)
        saveKnown()
        // ✅ 清除新分类提示（红点消失）
        pendingNewCategories = []
    }
    
    /// 将指定的 subtype 集合标记为已知
    func markAsKnown(_ subtypes: Set<String>) {
        knownSubtypes.formUnion(subtypes)
        saveKnown()
        // 重新计算 pending
        pendingNewCategories = pendingNewCategories.compactMap { cat in
            let remaining = cat.subtypes.filter { !knownSubtypes.contains($0) }
            return remaining.isEmpty ? nil : (type: cat.type, subtypes: remaining)
        }
    }
    
    // MARK: - 分类提取
    
    /// 从数据中提取 type → [subtype] 映射
    static func extractCategories(from items: [PredictionItem]) -> [(type: String, subtypes: [String])] {
        var typeMap: [String: Set<String>] = [:]
        
        for item in items {
            let t = item.type
            let s = item.subtype
            typeMap[t, default: Set()].insert(s)
        }
        
        return typeMap
            .sorted { $0.key < $1.key }
            .map { (type: $0.key, subtypes: $0.value.sorted()) }
    }
}


// MARK: - 完整偏好设置页面（✅ 整合新分类提示 + 现有偏好编辑）
struct PreferenceSelectionView: View {
    @EnvironmentObject var syncManager: PredictionSyncManager
    @EnvironmentObject var prefManager: PreferenceManager
    @EnvironmentObject var transManager: TranslationManager
    @Environment(\.dismiss) var dismiss
    
    let isOnboarding: Bool
    var onComplete: (() -> Void)? = nil
    
    @State private var expandedTypes: Set<String> = []
    
    /// 当前待确认的新 subtype 集合
    private var newSubtypes: Set<String> {
        prefManager.allPendingNewSubtypes
    }
    
    /// 分类列表：如果有新分类，含新 subtype 的类别排在前面
    private var categories: [(type: String, subtypes: [String])] {
        let all = syncManager.polymarketItems + syncManager.kalshiItems
        let cats = PreferenceManager.extractCategories(from: all)
        
        if !newSubtypes.isEmpty {
            return cats.sorted { cat1, cat2 in
                let has1 = cat1.subtypes.contains(where: { newSubtypes.contains($0) })
                let has2 = cat2.subtypes.contains(where: { newSubtypes.contains($0) })
                if has1 != has2 { return has1 }
                return cat1.type < cat2.type
            }
        }
        return cats
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
                        .foregroundColor(.primary)
                    Text("选择您想追踪的预测类别")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 20)
                .padding(.bottom, 16)
                
                // 全局全选/全不选
                HStack {
                    Button("全局全选") {
                        withAnimation { prefManager.selectAll(subtypes: allSubtypes) }
                    }
                    .font(.caption.bold())
                    .foregroundStyle(LinearGradient.brandGradient)
                    
                    Text("·").foregroundColor(.secondary)
                    
                    Button("全局全不选") {
                        withAnimation { prefManager.selectedSubtypes.removeAll() }
                    }
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                    
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
                        // ✅ 新分类发现提示条（仅在非 Onboarding 且有新分类时显示）
                        if !isOnboarding && !newSubtypes.isEmpty {
                            newCategoryBanner
                        }
                        
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
                                },
                                newSubtypes: newSubtypes
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
                    // ✅ 保存时将当前所有 subtype 标记为"已知"，同时清除红点
                    let allItems = syncManager.polymarketItems + syncManager.kalshiItems
                    prefManager.markAllAsKnown(from: allItems)
                    
                    // ✅ 修复导航卡死：onboarding 模式下，先 dismiss 再延迟完成
                    if isOnboarding {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            onComplete?()
                        }
                    } else {
                        dismiss()
                    }
                } label: {
                    Text(isOnboarding ? "开始探索" : "保存设置")
                        .font(.headline)
                        .foregroundColor(prefManager.selectedSubtypes.isEmpty ? .secondary : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            Group {
                                if prefManager.selectedSubtypes.isEmpty {
                                    Color.primary.opacity(0.1)
                                } else {
                                    LinearGradient.brandGradientHorizontal
                                }
                            }
                        )
                        .cornerRadius(16)
                        .shadow(color: prefManager.selectedSubtypes.isEmpty ? .clear : Color.brandStart.opacity(0.3), radius: 8, y: 4)
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
        // ✅ 新增：在导航栏右侧添加中英切换按钮
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        transManager.toggle()
                    }
                } label: {
                    Text(transManager.language == .chinese ? "英" : "中")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle().fill(Color.primary.opacity(0.1))
                        )
                }
            }
        }
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
    
    // MARK: - 新分类发现提示条
    private var newCategoryBanner: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16))
                    .foregroundStyle(LinearGradient.brandGradient)
                Text("发现 \(newSubtypes.count) 个新分类")
                    .font(.subheadline.bold())
                    .foregroundColor(.primary)
                Spacer()
            }
            Text("带有 NEW 标记的为新增分类，勾选后保存即可追踪")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.brandStart.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.brandStart.opacity(0.2), lineWidth: 1)
                )
        )
    }
}


// MARK: - 类别卡片（✅ 新增 newSubtypes 参数，支持 "NEW" 标记）
struct CategoryCard: View {
    let typeName: String
    let subtypes: [String]
    let isExpanded: Bool
    @Binding var selectedSubtypes: Set<String>
    let onToggleExpand: () -> Void
    var newSubtypes: Set<String> = []
    @EnvironmentObject var transManager: TranslationManager
    
    private var selectedCount: Int {
        subtypes.filter { selectedSubtypes.contains($0) }.count
    }
    
    /// 本类别中有多少个新 subtype
    private var newCountInCategory: Int {
        subtypes.filter { newSubtypes.contains($0) }.count
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 大类标题（不可选，点击展开/收起）
            Button(action: onToggleExpand) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(transManager.type(typeName))
                                .font(.headline)
                                .foregroundColor(.primary)
                            // ✅ 如果本类别包含新 subtype，显示提示
                            if newCountInCategory > 0 {
                                HStack(spacing: 2) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 10))
                                    Text("\(newCountInCategory) new")
                                        .font(.system(size: 10, weight: .bold))
                                }
                                .foregroundColor(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.12))
                                .cornerRadius(6)
                            }
                        }
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
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            
            // 子类标签（可选）
            if isExpanded {
                
                // 分类级别的局部全选/全不选按钮
                HStack(spacing: 12) {
                    Spacer()
                    
                    Button {
                        withAnimation(.spring(response: 0.25)) {
                            selectedSubtypes.formUnion(subtypes)
                        }
                    } label: {
                        Text("全选本类")
                            .font(.caption2.bold())
                            .foregroundColor(.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.08))
                            .cornerRadius(8)
                    }
                    
                    Button {
                        withAnimation(.spring(response: 0.25)) {
                            selectedSubtypes.subtract(subtypes)
                        }
                    } label: {
                        Text("全不选")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.08))
                            .cornerRadius(8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                
                let columns = [GridItem(.adaptive(minimum: 120, maximum: 200), spacing: 10)]
                
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(subtypes, id: \.self) { subtype in
                        let isSelected = selectedSubtypes.contains(subtype)
                        let isNew = newSubtypes.contains(subtype)
                        
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
                                // 空心圆圈与实心对勾指示器
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 14, weight: isSelected ? .bold : .regular))
                                Text(transManager.subtype(subtype))
                                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                                    .lineLimit(1)
                                // ✅ 新增：NEW 标记
                                if isNew {
                                    Text("NEW")
                                        .font(.system(size: 8, weight: .heavy))
                                        .foregroundColor(.orange)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                        .background(
                                            isSelected
                                                ? Color.white.opacity(0.25)
                                                : Color.orange.opacity(0.15)
                                        )
                                        .cornerRadius(4)
                                }
                            }
                            .foregroundColor(isSelected ? .white : .primary.opacity(0.8))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Group {
                                    if isSelected {
                                        LinearGradient.brandGradientHorizontal
                                    } else {
                                        Color.primary.opacity(0.06)
                                    }
                                }
                            )
                            .cornerRadius(16)
                        }
                        .buttonStyle(PlainButtonStyle())
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