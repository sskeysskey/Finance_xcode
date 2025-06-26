import SwiftUI

struct ArticleListView: View {
    let source: NewsSource
    // @ObservedObject 订阅从父视图传递过来的 ViewModel 的变化
    @ObservedObject var viewModel: NewsViewModel

    var body: some View {
        // ==================== 主要修改点 1 ====================
        // 使用 ScrollViewReader 包裹 List
        ScrollViewReader { proxy in
            List {
                // 日期显示
                Text(formattedDate())
                    .font(.caption)
                    .foregroundColor(.gray)
                    .padding(.top)
                    .listRowSeparator(.hidden)
                
                // 遍历该来源下的所有文章
                ForEach(source.articles) { article in
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
                            // 根据 isRead 状态决定文字颜色
                                .foregroundColor(article.isRead ? .gray : .primary)
                        }
                        .padding(.vertical, 8)
                        // ==================== 主要修改点 1 ====================
                        // 使用 if-else 结构来只显示一个相关的菜单项
                        .contextMenu {
                            if article.isRead {
                                // 如果文章已读，只显示“标记为未读”
                                Button {
                                    viewModel.markAsUnread(articleID: article.id)
                                } label: {
                                    Label("标记为未读", systemImage: "circle")
                                }
                            } else {
                                // 如果文章未读，只显示“标记为已读”
                                Button {
                                    viewModel.markAsRead(articleID: article.id)
                                } label: {
                                    Label("标记为已读", systemImage: "checkmark.circle")
                                }
                            }
                        }
                        // =================================================
                    }
                    .listRowSeparator(.hidden)
                    // ==================== 主要修改点 2 ====================
                    // 为每一行设置一个明确的 ID，以便 ScrollViewReader 可以找到它
                    .id(article.id)
                }
            }
            .listStyle(PlainListStyle())
            .navigationTitle("Unread")
            .navigationBarTitleDisplayMode(.inline)
            // ==================== 主要修改点 3 ====================
            // 当视图出现时，检查并执行滚动
            .onAppear {
                // 检查 viewModel 中是否记录了上次查看的文章 ID
                if let lastID = viewModel.lastViewedArticleID {
                    // 如果有，使用 proxy 滚动到该 ID 对应的行
                    // anchor: .center 会将该行滚动到屏幕中央，更易于用户发现
                    withAnimation {
                        proxy.scrollTo(lastID, anchor: .center)
                    }
                }
            }
        }
    }
    
    // 格式化日期的辅助函数
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

// 新建的视图，用于展示所有来源的文章
struct AllArticlesListView: View {
    // @ObservedObject 订阅从父视图传递过来的 ViewModel 的变化
    @ObservedObject var viewModel: NewsViewModel
    
    var body: some View {
        // ==================== 对 AllArticlesListView 应用同样的修改 ====================
        ScrollViewReader { proxy in
            List {
                // 首先遍历所有的新闻来源
                ForEach(viewModel.sources) { source in
                    // 然后遍历该来源下的所有文章
                    ForEach(source.articles) { article in
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
                            // ==================== 主要修改点 2 ====================
                            // 对“所有文章”列表也应用同样的逻辑
                            .contextMenu {
                                if article.isRead {
                                    // 如果文章已读，只显示“标记为未读”
                                    Button {
                                        viewModel.markAsUnread(articleID: article.id)
                                    } label: {
                                        Label("标记为未读", systemImage: "circle")
                                    }
                                } else {
                                    // 如果文章未读，只显示“标记为已读”
                                    Button {
                                        viewModel.markAsRead(articleID: article.id)
                                    } label: {
                                        Label("标记为已读", systemImage: "checkmark.circle")
                                    }
                                }
                            }
                            // =================================================
                        }
                        .listRowSeparator(.hidden)
                        // 为每一行设置 ID
                        .id(article.id)
                    }
                }
            }
            .listStyle(PlainListStyle())
            .navigationBarTitleDisplayMode(.inline)
            // 当视图出现时执行滚动
            .onAppear {
                if let lastID = viewModel.lastViewedArticleID {
                    withAnimation {
                        proxy.scrollTo(lastID, anchor: .center)
                    }
                }
            }
        }
    }
}
