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
    
    // ✅ 核心修改 1：将 results 改为 @State，以便在异步搜索完成后更新
    @State private var results: [PredictionItem] = []
    
    // ✅ 核心修改 2：新增搜索中状态
    @State private var isSearching = false
    
    // ✅ 核心修改 3：将搜索逻辑改为异步执行
    private func performSearch() {
        searchQuery = searchText
        isSearchFocused = false // 收起键盘
        
        let keyword = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else {
            results = []
            return
        }
        
        // 开启搜索状态
        isSearching = true
        
        Task {
            // ✅ 关键点：短暂休眠让出主线程，确保“搜索中...”的 UI 能够先渲染出来
            try? await Task.sleep(nanoseconds: 50_000_000) // 0.05秒
            
            // 执行耗时的过滤逻辑
            let filteredResults = items.filter { item in
                // 1. 匹配标题 (name) 的中英文
                if item.name.lowercased().contains(keyword) { return true }
                // 中文译文匹配
                let translatedName = transManager.name(item.name).lowercased()
                if translatedName.contains(keyword) { return true }
                
                // 2. 匹配大类 (type) 的中英文
                if item.type.lowercased().contains(keyword) { return true }
                let translatedType = transManager.type(item.type).lowercased()
                if translatedType.contains(keyword) { return true }
                
                // 3. 匹配子类 (subtype) 的中英文
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
            
            // 搜索完成，更新结果并关闭 Loading 状态
            results = filteredResults
            isSearching = false
        }
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
                            
                            // 监听回车键事件
                            TextField("搜索预测话题、分类或选项...", text: $searchText)
                                .foregroundColor(.primary)
                                .focused($isSearchFocused)
                                .autocorrectionDisabled()
                                .submitLabel(.search) // 将键盘回车键设为“搜索”
                                .disabled(isSearching) // 搜索中禁用输入
                                .onSubmit {
                                    if !isSearching { performSearch() }
                                }
                            
                            if !searchText.isEmpty {
                                Button { 
                                    searchText = "" 
                                    searchQuery = "" // 清空搜索结果
                                    results = []     // ✅ 清空结果数组
                                    isSearching = false // ✅ 重置搜索状态
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
                        
                        // 根据输入状态显示“搜索”或“取消”
                        if !searchText.isEmpty {
                            Button("搜索") {
                                performSearch()
                            }
                            .foregroundColor(isSearching ? .gray : .blue)
                            .bold()
                            .disabled(isSearching) // ✅ 搜索中禁用按钮
                        } else {
                            Button("取消") { dismiss() }
                                .foregroundColor(.primary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    
                    // ✅ 核心修改 4：结果展示逻辑增加 isSearching 状态判断
                    if isSearching {
                        VStack(spacing: 16) {
                            Spacer()
                            ProgressView() // 菊花转轮
                                .scaleEffect(1.2)
                            Text("搜索中，请稍候...")
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    } else if searchQuery.isEmpty {
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