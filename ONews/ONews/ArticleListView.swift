import SwiftUI

enum ArticleFilterMode: String, CaseIterable {
    case unread = "Unread"
    case read = "Read"
}

struct ArticleListView: View {
    let source: NewsSource
    @ObservedObject var viewModel: NewsViewModel
    
    @State private var filterMode: ArticleFilterMode = .unread
    
    private var filteredArticles: [Article] {
        switch filterMode {
        case .unread:
            return source.articles.filter { !$0.isRead }
        case .read:
            return source.articles.filter { $0.isRead }
        }
    }
    
    // ===== 新增 (1/2): 计算未读和已读文章数量 =====
    // 计算该来源下未读文章的数量
    private var unreadCount: Int {
        source.articles.filter { !$0.isRead }.count
    }
    
    // 计算该来源下已读文章的数量
    private var readCount: Int {
        source.articles.filter { $0.isRead }.count
    }
    // ===========================================

    var body: some View {
        VStack {
            ScrollViewReader { proxy in
                List {
                    Text(formattedDate())
                        .font(.caption)
                        .foregroundColor(.gray)
                        .padding(.top)
                        .listRowSeparator(.hidden)
                    
                    ForEach(filteredArticles) { article in
                        NavigationLink(destination: ArticleContainerView(
                            article: article,
                            sourceName: source.name,
                            context: .fromSource(source.name),
                            viewModel: viewModel
                        )) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(source.name)
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                Text(article.topic)
                                    .fontWeight(.semibold)
                                    .foregroundColor(article.isRead ? .gray : .primary)
                            }
                            .padding(.vertical, 8)
                            .contextMenu {
                                if article.isRead {
                                    Button {
                                        viewModel.markAsUnread(articleID: article.id)
                                    } label: {
                                        Label("标记为未读", systemImage: "circle")
                                    }
                                } else {
                                    Button {
                                        viewModel.markAsRead(articleID: article.id)
                                    } label: {
                                        Label("标记为已读", systemImage: "checkmark.circle")
                                    }
                                }
                            }
                        }
                        .listRowSeparator(.hidden)
                        .id(article.id)
                    }
                }
                .listStyle(PlainListStyle())
                .navigationTitle("Unread")
                .navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    if let lastID = viewModel.lastViewedArticleID {
                        if filteredArticles.contains(where: { $0.id == lastID }) {
                            withAnimation {
                                proxy.scrollTo(lastID, anchor: .center)
                            }
                        }
                    }
                }
            }
            
            // ===== 修改 (2/2): 在 Picker 中显示文章数量 =====
            Picker("Filter", selection: $filterMode) {
                ForEach(ArticleFilterMode.allCases, id: \.self) { mode in
                    // 根据当前的 mode，决定显示哪个数量
                    let count = (mode == .unread) ? unreadCount : readCount
                    // 使用字符串插值来构建带数量的文本
                    Text("\(mode.rawValue) (\(count))")
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
            // ===============================================
        }
    }
    
    private func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        
        if Calendar.current.isDateInToday(Date()) {
            formatter.dateFormat = "EEEE, MMMM d, yyyy"
            return "TODAY, \(formatter.string(from: Date()).uppercased())"
        } else if Calendar.current.isDateInYesterday(Date()) {
            return "YESTERDAY"
        } else {
            formatter.dateFormat = "EEEE, MMMM d, yyyy"
            return formatter.string(from: Date()).uppercased()
        }
    }
}

struct AllArticlesListView: View {
    @ObservedObject var viewModel: NewsViewModel
    
    @State private var filterMode: ArticleFilterMode = .unread
    
    // ===== 新增 (与 ArticleListView 类似的逻辑) =====
    // 计算所有来源下未读文章的总数
    private var totalUnreadCount: Int {
        viewModel.sources.flatMap { $0.articles }.filter { !$0.isRead }.count
    }
    
    // 计算所有来源下已读文章的总数
    private var totalReadCount: Int {
        viewModel.sources.flatMap { $0.articles }.filter { $0.isRead }.count
    }
    // ==============================================
    
    var body: some View {
        VStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(viewModel.sources) { source in
                        let articlesToDisplay = source.articles.filter { article in
                            switch filterMode {
                            case .unread:
                                return !article.isRead
                            case .read:
                                return article.isRead
                            }
                        }
                        
                        if !articlesToDisplay.isEmpty {
                            ForEach(articlesToDisplay) { article in
                                NavigationLink(destination: ArticleContainerView(
                                    article: article,
                                    sourceName: source.name,
                                    context: .fromAllArticles,
                                    viewModel: viewModel
                                )) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(source.name)
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                        Text(article.topic)
                                            .fontWeight(.semibold)
                                            .foregroundColor(article.isRead ? .gray : .primary)
                                    }
                                    .padding(.vertical, 8)
                                    .contextMenu {
                                        if article.isRead {
                                            Button {
                                                viewModel.markAsUnread(articleID: article.id)
                                            } label: {
                                                Label("标记为未读", systemImage: "circle")
                                            }
                                        } else {
                                            Button {
                                                viewModel.markAsRead(articleID: article.id)
                                            } label: {
                                                Label("标记为已读", systemImage: "checkmark.circle")
                                            }
                                        }
                                    }
                                }
                                .listRowSeparator(.hidden)
                                .id(article.id)
                            }
                        }
                    }
                }
                .listStyle(PlainListStyle())
                .navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    if let lastID = viewModel.lastViewedArticleID {
                        let allFilteredArticles = viewModel.sources.flatMap { $0.articles }.filter {
                            filterMode == .unread ? !$0.isRead : $0.isRead
                        }
                        if allFilteredArticles.contains(where: { $0.id == lastID }) {
                            withAnimation {
                                proxy.scrollTo(lastID, anchor: .center)
                            }
                        }
                    }
                }
            }
            
            // ===== 修改 (与 ArticleListView 相同的逻辑) =====
            Picker("Filter", selection: $filterMode) {
                ForEach(ArticleFilterMode.allCases, id: \.self) { mode in
                    let count = (mode == .unread) ? totalUnreadCount : totalReadCount
                    Text("\(mode.rawValue) (\(count))")
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
            // =============================================
        }
    }
}
