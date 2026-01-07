import Foundation
import SwiftUI

struct Localized {
    
    // 内部帮助函数：读取 UserDefaults（AppStorage 的底层存储）
    private static var isEnglish: Bool {
        UserDefaults.standard.bool(forKey: "isGlobalEnglishMode")
    }
    
    // 帮助函数：简化写法
    private static func tr(_ zh: String, _ en: String) -> String {
        return isEnglish ? en : zh
    }
    
    // MARK: - 通用词汇
    static var loading: String { tr("正在加载...", "Loading...") }
    static var searchPlaceholder: String { tr("搜索标题或正文关键字", "Search titles or content") }
    static var cancel: String { tr("取消", "Cancel") }
    static var confirm: String { tr("确定", "Confirm") }
    static var close: String { tr("关闭", "Close") }
    static var refresh: String { tr("刷新", "Refresh") }
    static var search: String { tr("搜索", "Search") }
    static var unknownError: String { tr("未知错误", "Unknown Error") }
    static var networkError: String { tr("网络连接失败", "Network Connection Failed") }
    
    // MARK: - 主页 / 列表页
    static var mySubscriptions: String { tr("我的订阅", "My Subscriptions") }
    static var allArticles: String { tr("全部文章", "All Articles") }
    static var allArticlesDesc: String { tr("汇集所有订阅源", "Aggregated Feed") }
    static var unread: String { tr("未读", "Unread") }
    static var read: String { tr("已读", "Read") }
    static var searchResults: String { tr("搜索结果", "Results") }
    static var noMatch: String { tr("未找到匹配的文章", "No matches found") }
    static var needSubscription: String { tr("需订阅", "Premium") }
    static var contentMatch: String { tr("正文匹配", "Content Match") }
    
    // MARK: - 上下文菜单
    static var markAsRead_text: String { tr("标记为已读", "Mark as Read") }
    static var markAsUnread_text: String { tr("标记为未读", "Mark as Unread") }
    static var readAbove: String { tr("以上全部已读", "Mark Above as Read") }
    static var readBelow: String { tr("以下全部已读", "Mark Below as Read") }
    
    // MARK: - 添加源页面
    static var addSourceTitle: String { tr("添加内容", "Add Content") }
    static var availableSources: String { tr("可用新闻源", "Available Sources") }
    static var fetchingSources: String { tr("正在获取最新源...", "Fetching sources...") }
    static var addAll: String { tr("一键添加所有", "Add All") }
    static var finishSetup: String { tr("完成设置", "Finish") }
    static var selectAtLeastOne: String { tr("请至少选择一个", "Select at least one") }
    static var noSubscriptions: String { tr("您还没有订阅任何新闻源", "No subscriptions yet") }
    static var addSubscriptionBtn: String { tr("添加订阅", "Add Subscription") }
    
    // MARK: - 详情页
    static var originalLink: String { tr("原文链接", "Original Link") }
    static var readNext: String { tr("读取下一篇", "Read Next") }
    static var imageLoading: String { tr("正在加载图片...", "Loading images...") }
    static var imagePrepare: String { tr("准备中...", "Preparing...") }
    static var imageDownloaded: String { tr("已下载", "Downloaded") }
    static var shareTo: String { tr("分享至", "Share to") }
    static var more: String { tr("更多", "More") }
    static var wechatCopied: String { tr("文章内容已复制", "Content Copied") }
    static var wechatGuide: String { tr("由于微信限制请手动去微信粘贴文章内容", "Please paste manually in WeChat") }
    
    // MARK: - 登录与个人中心
    static var loginAccount: String { tr("登录账户", "Sign In") }
    static var logout: String { tr("退出登录", "Sign Out") }
    static var feedback: String { tr("问题反馈", "Feedback") }
    static var profileTitle: String { tr("账户", "Account") }
    static var premiumUser: String { tr("专业版会员", "Pro Member") }
    static var freeUser: String { tr("免费版用户", "Free User") }
    static var validUntil: String { tr("有效期至", "Valid until") }
    static var notLoggedIn: String { tr("未登录", "Not Logged In") }
    static var loginWelcome: String { tr("登录【环球要闻】", "Login to ONews") }
    static var loginDesc: String { tr("成功登录后\n即使更换设备\n也可以同步您的订阅状态", "Sync your subscriptions\nacross devices\nafter logging in") }
    static var later: String { tr("稍后再说", "Not Now") }
    
    // MARK: - 订阅页 (Subscription)
    static var subTitle: String { tr("最近三天的新闻需付费观看🥲", "Recent news requires Pro🥲") }
    static var subDesc: String { tr("推荐选择“专业版”套餐\n订阅成功后的一个月内畅享所有日期资讯\n如果实在不想付费😓\n三天前资讯也可永久免费享用", "Unlock full access with Pro.\nOr enjoy older news (3+ days) for free forever.") }
    static var planFree: String { tr("【当前】免费版", "[Current] Free Plan") }
    static var planFreeDesc: String { tr("可免费浏览 三天前 的所有文章", "Access articles older than 3 days") } // 简化逻辑
    static var planFreeDescSubbed: String { tr("可免费浏览 全部 的所有文章", "Access ALL articles") }
    static var planPro: String { tr("专业版套餐", "Pro Plan") }
    static var planProDesc: String { tr("解锁最新日期资讯，与世界同频", "Unlock latest news instantly") }
    static var processingPayment: String { tr("正在处理支付...", "Processing Payment...") }
    static var restorePurchase: String { tr("恢复购买", "Restore Purchase") }
    static var terms: String { tr("使用条款 (EULA)", "Terms of Use") }
    static var privacy: String { tr("隐私政策", "Privacy Policy") }
}
