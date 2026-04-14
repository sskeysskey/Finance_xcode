import SwiftUI
import Combine

struct PredictionSearchView: View {
    let items: [PredictionItem]
    let isSubscribed: Bool
    let onLockedTap: () -> Void
    
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var transManager: TranslationManager
    
    @State private var searchText = ""
    // ✅ 核心修改：专门用于存储“已确认”的搜索关键词
    @State private var searchQuery = "" 
    @FocusState private var isSearchFocused: Bool
    
    // ✅ 新增：用于管理详情页导航
    @State private var selectedDetailItem: PredictionItem?
    
    // ✅ 核心修改：基于 searchQuery 进行过滤
    private var results: [PredictionItem] {
        let keyword = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return [] }

        return items.filter { item in
            // 1. 匹配标题 (name) 的中英文
            if item.name.lowercased().contains(keyword) { return true }
            // 中文译文匹配
            let translatedName = transManager.name(item.name).lowercased()
            if translatedName.contains(keyword) { return true }
            
            // ✅ 2. 新增：匹配大类 (type) 的中英文
            if item.type.lowercased().contains(keyword) { return true }
            let translatedType = transManager.type(item.type).lowercased()
            if translatedType.contains(keyword) { return true }
            
            // ✅ 3. 新增：匹配子类 (subtype) 的中英文
            if item.subtype.lowercased().contains(keyword) { return true }
            let translatedSubtype = transManager.subtype(item.subtype).lowercased()
            if translatedSubtype.contains(keyword) { return true }

            // 4. 匹配选项 (options) 的中英文
            for opt in item.options {
                if opt.label.lowercased().contains(keyword) { return true }
                if opt.displayLabel.lowercased().contains(keyword) { return true }
                let translatedOpt = transManager.option(opt.displayLabel).lowercased()
                if translatedOpt.contains(keyword) { return true }
            }
            return false
        }
    }
    
    // ✅ 辅助函数：执行搜索操作
    private func performSearch() {
        searchQuery = searchText
        isSearchFocused = false // 收起键盘
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // 搜索栏
                    HStack(spacing: 12) {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                            
                            // ✅ 修改：监听回车键事件
                            TextField("搜索预测话题、分类或选项...", text: $searchText)
                                .foregroundColor(.primary)
                                .focused($isSearchFocused)
                                .autocorrectionDisabled()
                                .submitLabel(.search) // 将键盘回车键设为“搜索”
                                .onSubmit {
                                    performSearch()
                                }
                            
                            if !searchText.isEmpty {
                                Button { 
                                    searchText = "" 
                                    searchQuery = "" // 清空搜索结果
                                    // 3. ✅ 关键修改：手动将焦点重新设置回输入框
                                    isSearchFocused = true 
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(10)
                        .background(Color.cardBg)
                        .cornerRadius(12)
                        
                        // ✅ 修改：根据输入状态显示“搜索”或“取消”
                        if !searchText.isEmpty {
                            Button("搜索") {
                                performSearch()
                            }
                            .foregroundColor(.blue)
                            .bold()
                        } else {
                            Button("取消") { dismiss() }
                                .foregroundColor(.primary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    
                    // 结果展示逻辑
                    if searchQuery.isEmpty {
                        VStack(spacing: 16) {
                            Spacer()
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary.opacity(0.3))
                            Text("输入关键词并点击搜索")
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    } else if results.isEmpty {
                        VStack(spacing: 16) {
                            Spacer()
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary.opacity(0.3))
                            Text("未找到匹配结果")
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                Text("\(results.count) 个结果")
                                    .font(.caption).foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16)
                                
                                ForEach(results) { item in
                                    PredictionCardView(
                                        item: item,
                                        isSubscribed: isSubscribed,
                                        onLockedTap: onLockedTap,
                                        onNavigateToDetail: { selectedDetailItem = item }
                                    )
                                    .padding(.horizontal, 16)
                                }
                                
                                Spacer().frame(height: 40)
                            }
                            .padding(.top, 8)
                        }
                    }
                }
            }
            // ✅ 关键修复：navigationDestination 放在 NavigationStack 的直接子视图上，
            //    而不是 LazyVStack 内部
            .navigationDestination(isPresented: Binding(
                get: { selectedDetailItem != nil },
                set: { if !$0 { selectedDetailItem = nil } }
            )) {
                if let item = selectedDetailItem {
                    PredictionDetailView(item: item)
                }
            }
            .onAppear { isSearchFocused = true }
        }
    }
}