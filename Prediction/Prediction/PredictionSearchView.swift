import SwiftUI

struct PredictionSearchView: View {
    let items: [PredictionItem]
    let isSubscribed: Bool
    let onLockedTap: () -> Void
    
    @Environment(\.dismiss) var dismiss
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    
    private var results: [PredictionItem] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return [] }
        
        return items.filter { item in
            if item.name.lowercased().contains(keyword) { return true }
            for opt in item.options {
                if opt.label.lowercased().contains(keyword) { return true }
            }
            return false
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
                            TextField("搜索预测话题或选项...", text: $searchText)
                                .foregroundColor(.white)
                                .focused($isSearchFocused)
                                .autocorrectionDisabled()
                            
                            if !searchText.isEmpty {
                                Button { searchText = "" } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(10)
                        .background(Color.cardBg)
                        .cornerRadius(12)
                        
                        Button("取消") { dismiss() }
                            .foregroundColor(.blue)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    
                    // 结果
                    if searchText.isEmpty {
                        VStack(spacing: 16) {
                            Spacer()
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary.opacity(0.3))
                            Text("输入关键词搜索")
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
                                        onLockedTap: onLockedTap
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
            .onAppear { isSearchFocused = true }
        }
    }
}