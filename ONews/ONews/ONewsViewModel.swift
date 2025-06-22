import Foundation

// ObservableObject 使得 SwiftUI 视图可以订阅它的变化
class NewsViewModel: ObservableObject {
    
    // @Published 属性包装器会在数据改变时自动通知所有订阅的视图
    @Published var sources: [NewsSource] = []
    
    // 计算所有来源中未读文章的总数
    var totalUnreadCount: Int {
        // flatMap 将所有来源的文章合并成一个数组，然后过滤出未读的并计数
        sources.flatMap { $0.articles }.filter { !$0.isRead }.count
    }
    
    init() {
        loadNews()
    }
    
    // 从项目包中加载并解析JSON文件
    func loadNews() {
        guard let url = Bundle.main.url(forResource: "onews", withExtension: "json") else {
            fatalError("无法在项目包中找到 news_250622.json 文件。")
        }
        
        guard let data = try? Data(contentsOf: url) else {
            fatalError("无法加载 news_250622.json 文件。")
        }
        
        let decoder = JSONDecoder()
        
        // 将JSON解码为一个字典，键是来源名称，值是文章数组
        guard let decodedData = try? decoder.decode([String: [Article]].self, from: data) else {
            fatalError("解析 news_250622.json 文件失败。")
        }
        
        // 将解码后的字典转换为我们在UI中使用的 NewsSource 数组
        // .sorted 按名称排序，确保每次加载顺序一致
        self.sources = decodedData.map { (sourceName, articles) in
            NewsSource(name: sourceName, articles: articles)
        }.sorted { $0.name < $1.name }
    }
    
    // 根据文章ID将特定文章标记为已读
    func markAsRead(articleID: UUID) {
        // 在主线程上更新，因为这会触发UI变化
        DispatchQueue.main.async {
            // 遍历所有来源
            for i in 0..<self.sources.count {
                // 查找包含该文章的来源
                if let j = self.sources[i].articles.firstIndex(where: { $0.id == articleID }) {
                    // 如果文章当前是未读状态，则将其标记为已读
                    if !self.sources[i].articles[j].isRead {
                        self.sources[i].articles[j].isRead = true
                    }
                    // 找到后即可退出循环
                    return
                }
            }
        }
    }
}
