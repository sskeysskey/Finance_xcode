import SwiftUI

struct ArticleListView: View {
    let source: NewsSource
    // @ObservedObject 订阅从父视图传递过来的 ViewModel 的变化
    @ObservedObject var viewModel: NewsViewModel

    var body: some View {
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
                    // 为每个文章行添加上下文菜单
                    .contextMenu {
                        // “标记为已读”按钮
                        Button {
                            viewModel.markAsRead(articleID: article.id)
                        } label: {
                            Label("标记为已读", systemImage: "checkmark.circle")
                        }
                        // 如果文章本身已读，则禁用此按钮
                        .disabled(article.isRead)
                        
                        // “标记为未读”按钮
                        Button {
                            viewModel.markAsUnread(articleID: article.id)
                        } label: {
                            Label("标记为未读", systemImage: "circle")
                        }
                        // 如果文章本身未读，则禁用此按钮
                        .disabled(!article.isRead)
                    }
                    // =================================================
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(PlainListStyle())
        .navigationTitle("Unread")
        .navigationBarTitleDisplayMode(.inline)
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
                        // 为每个文章行添加上下文菜单 (与上面完全相同)
                        .contextMenu {
                            // “标记为已读”按钮
                            Button {
                                viewModel.markAsRead(articleID: article.id)
                            } label: {
                                Label("标记为已读", systemImage: "checkmark.circle")
                            }
                            // 如果文章本身已读，则禁用此按钮
                            .disabled(article.isRead)
                            
                            // “标记为未读”按钮
                            Button {
                                viewModel.markAsUnread(articleID: article.id)
                            } label: {
                                Label("标记为未读", systemImage: "circle")
                            }
                            // 如果文章本身未读，则禁用此按钮
                            .disabled(!article.isRead)
                        }
                        // =================================================
                    }
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(PlainListStyle())
        .navigationTitle("All Articles")
        .navigationBarTitleDisplayMode(.inline)
    }
}
