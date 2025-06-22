import Foundation

// 用于UI展示的新闻来源结构体
// Identifiable 协议让它可以在 SwiftUI 的 List 中直接使用
struct NewsSource: Identifiable {
    let id = UUID() // 唯一标识符
    let name: String
    var articles: [Article]
}

// 文章的结构体
// Identifiable 和 Codable 协议
struct Article: Identifiable, Codable {
    var id = UUID() // 为每个文章实例生成唯一ID
    let topic: String
    let article: String
    let images: [String]
    
    // `isRead` 状态不在JSON中，所以我们自定义解码过程
    var isRead: Bool = false

    // 定义JSON中的键，这样解码器就知道要解析哪些字段
    enum CodingKeys: String, CodingKey {
        case topic, article, images
    }
}
