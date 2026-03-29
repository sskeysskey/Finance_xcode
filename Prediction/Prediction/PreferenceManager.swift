import SwiftUI
import Foundation
import Combine

@MainActor
class PreferenceManager: ObservableObject {
    
    @Published var selectedSubtypes: Set<String> = []
    @Published var knownSubtypes: Set<String> = []
    
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
    
    /// 老用户迁移：如果已有偏好但 knownSubtypes 为空，说明是从旧版本升级的
    /// 此时将当前所有 subtype 视为"已知"，避免误弹窗
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
    
    /// ✅ 新增：安全的新分类检测入口
    /// 同步进行中时直接返回空，避免在数据不稳定期间误检测
    func safeDetectNewSubtypes(from items: [PredictionItem], isSyncing: Bool) -> [(type: String, subtypes: [String])] {
        guard !isSyncing else {
            print("⏳ 新分类检测跳过：数据同步进行中")
            return []
        }
        return detectNewSubtypes(from: items)
    }
    
    func markAllAsKnown(from items: [PredictionItem]) {
        let allSubs = Set(items.map { $0.subtype })
        knownSubtypes.formUnion(allSubs)
        saveKnown()
    }
    
    /// 将指定的 subtype 集合标记为已知
    func markAsKnown(_ subtypes: Set<String>) {
        knownSubtypes.formUnion(subtypes)
        saveKnown()
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


// MARK: - 完整偏好设置页面（已有，增加 markAllAsKnown 调用）
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
                        .foregroundColor(.primary)
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
                    // ✅ 保存时将当前所有 subtype 标记为"已知"
                    let allItems = syncManager.polymarketItems + syncManager.kalshiItems
                    prefManager.markAllAsKnown(from: allItems)
                    if isOnboarding {
                        onComplete?()
                    } else {
                        dismiss()
                    }
                } label: {
                    Text(isOnboarding ? "开始探索" : "保存设置")
                        .font(.headline)
                        .foregroundColor(.primary)
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


// MARK: - 新分类弹窗
struct NewCategorySheet: View {
    let newCategories: [(type: String, subtypes: [String])]
    @EnvironmentObject var prefManager: PreferenceManager
    @Environment(\.dismiss) var dismiss
    
    @State private var tempSelected: Set<String> = []
    
    private var allNewSubtypes: [String] {
        newCategories.flatMap { $0.subtypes }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // 顶部标题
                    VStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 40))
                            .foregroundColor(.yellow)
                        Text("发现新分类")
                            .font(.title2.bold())
                            .foregroundColor(.primary)
                        Text("数据更新后出现了新的预测分类，请选择是否关注")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 16)
                    
                    // 全选 / 全不选
                    HStack {
                        Button("全选") {
                            withAnimation { tempSelected = Set(allNewSubtypes) }
                        }
                        .font(.caption.bold())
                        .foregroundColor(.blue)
                        
                        Text("·").foregroundColor(.secondary)
                        
                        Button("全不选") {
                            withAnimation { tempSelected.removeAll() }
                        }
                        .font(.caption.bold())
                        .foregroundColor(.blue)
                        
                        Spacer()
                        
                        Text("已选 \(tempSelected.count)/\(allNewSubtypes.count) 项")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    
                    // 新分类列表
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(newCategories, id: \.type) { category in
                                NewCategorySectionCard(
                                    typeName: category.type,
                                    subtypes: category.subtypes,
                                    selectedSubtypes: $tempSelected
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 120)
                    }
                    
                    Spacer()
                }
                
                // 底部按钮
                VStack {
                    Spacer()
                    VStack(spacing: 10) {
                        Button {
                            confirmSelection()
                        } label: {
                            Text("确认添加 (\(tempSelected.count))")
                                .font(.headline)
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(
                                    LinearGradient(colors: [.blue, .purple],
                                                   startPoint: .leading, endPoint: .trailing)
                                )
                                .cornerRadius(16)
                        }
                        
                        Button {
                            skipSelection()
                        } label: {
                            Text("暂不关注这些分类")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.bottom, 4)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
                    .background(
                        LinearGradient(colors: [Color.appBg.opacity(0), Color.appBg],
                                       startPoint: .top, endPoint: .bottom)
                        .frame(height: 120)
                        .allowsHitTesting(false)
                    )
                }
            }
            .interactiveDismissDisabled(true)
        }
        .onAppear {
            // ✅ 修复：如果传入的 newCategories 实际为空（防御性处理），直接关闭
            if allNewSubtypes.isEmpty {
                dismiss()
                return
            }
            tempSelected = Set(allNewSubtypes)
        }
    }
    
    private func confirmSelection() {
        // 将用户勾选的新 subtype 加入偏好
        prefManager.selectedSubtypes.formUnion(tempSelected)
        prefManager.save()
        // 所有新 subtype（无论是否勾选）标记为已知
        prefManager.markAsKnown(Set(allNewSubtypes))
        dismiss()
    }
    
    private func skipSelection() {
        // 不加入偏好，但标记为已知，下次不再弹窗
        prefManager.markAsKnown(Set(allNewSubtypes))
        dismiss()
    }
}

// MARK: - 新分类卡片（单个 type 分组）
struct NewCategorySectionCard: View {
    let typeName: String
    let subtypes: [String]
    @Binding var selectedSubtypes: Set<String>
    
    private var selectedCount: Int {
        subtypes.filter { selectedSubtypes.contains($0) }.count
    }
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(typeName)
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Text("\(selectedCount)/\(subtypes.count) 已选")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            
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
                                .foregroundColor(isSelected ? .primary : .secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(isSelected ? Color.blue.opacity(0.2) : Color.primary.opacity(0.05))
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
        .background(Color.cardBg)
        .cornerRadius(16)
    }
}


// MARK: - 类别卡片（完整偏好页面用）
struct CategoryCard: View {
    let typeName: String
    let subtypes: [String]
    let isExpanded: Bool
    @Binding var selectedSubtypes: Set<String>
    let onToggleExpand: () -> Void
    @EnvironmentObject var transManager: TranslationManager // ← 新增
    
    private var selectedCount: Int {
        subtypes.filter { selectedSubtypes.contains($0) }.count
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 大类标题（不可选）
            Button(action: onToggleExpand) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(transManager.type(typeName)) // ← 替换
                            .font(.headline)
                            .foregroundColor(.primary)
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
                                
                                Text(transManager.subtype(subtype)) // ← 替换
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(isSelected ? .primary : .secondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(isSelected ? Color.blue.opacity(0.2) : Color.primary.opacity(0.05))
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