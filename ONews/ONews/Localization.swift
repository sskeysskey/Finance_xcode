import Foundation
import SwiftUI

struct Localized {
    // 内部帮助函数
    static var isEnglish: Bool {
        UserDefaults.standard.bool(forKey: "isGlobalEnglishMode")
    }
    
    // 帮助函数：简化写法
    private static func tr(_ zh: String, _ en: String) -> String {
        return isEnglish ? en : zh
    }

    // MARK: - 区域与格式化
    static var currentLocale: Locale {
        isEnglish ? Locale(identifier: "en_US") : Locale(identifier: "zh_CN")
    }
    
    // 日期格式化模板
    static var dateFormatFull: String {
        tr("yyyy年M月d日, EEEE", "EEEE, MMMM d, yyyy")
    }
    
    static var dateFormatShort: String {
        tr("M月d日 EEEE", "EEEE, MMM d")
    }


    // MARK: - 推广页 (Promo View)
    static var promoTitle: String { tr("每日AI大模型算法荐股\n全球财经数据一站搞定", "AI-Powered Stock Picks\nGlobal Financial Data at Once") }
    static var promoFeature: String { tr("「美股精灵」 特色介绍：", "FEATURES OF 'STOCK GENIE':") }
    static var promoDesc: String { tr("业界首创财报和价格线完美结合。无论你是擅长抄底还是做空抑或追高，总有一种荐股分类适合你。通过期权数据对AI算法结果做二次验证，确保成功率...", "The first to combine earnings reports with price lines. Whether you're bottom-fishing or short-selling, we have the right strategy for you. Success rates are verified by AI and options data...") }
    static var downloadInStore: String { tr("跳转到商店页面下载", "Download on the App Store") }
    static var promoLinkText: String { tr("毛遂自荐：博主另一款精品应用\n炒美股必备伴侣——“美股精灵”", "Recommendation: My other premium app\nStock Genie - Your US Stock Companion") }

    // MARK: - 补充缺失的 UI 词条
    static var sourceUnavailable: String { tr("新闻源不再可用", "News source no longer available") }
    static var parseError: String { tr("数据解析失败，请稍后重试。", "Data parsing failed, please try again later.") }
    static var unknownErrorMsg: String { tr("发生未知错误，请稍后重试。", "An unknown error occurred, please try again.") }
    static var syncResources: String { tr("正在同步资源...", "Syncing resources...") }
    
    // MARK: - 通用词汇
    static var loading: String { tr("正在加载...", "Loading...") }
    static var searchPlaceholder: String { tr("搜索标题或正文关键字", "Search titles or content") }
    static var cancel: String { tr("取消", "Cancel") }
    static var confirm: String { tr("确定", "Confirm") }
    static var ok: String { tr("好的", "OK") }
    static var close: String { tr("关闭", "Close") }
    static var refresh: String { tr("刷新", "Refresh") }
    static var search: String { tr("搜索", "Search") }
    static var unknownError: String { tr("未知错误", "Unknown Error") }
    static var networkError: String { tr("网络连接失败，请检查设置", "Network error, please check your settings") }
    static var syncFailed: String { tr("同步失败，请重试", "Sync failed, please try again.") }
    static var fetchFailed: String { tr("获取失败", "Fetch Failed") }

    // MARK: - 音频播放器 (Audio Player)
    static var playingArticle: String { tr("正在播放的文章", "Now Playing") }
    static var autoPlay: String { tr("自动连播", "Auto Play") }
    static var singlePlay: String { tr("单次播放", "Single Play") }
    static var synthesizing: String { tr("正在合成语音，请稍候...", "Synthesizing voice, please wait...") }
    static var playbackSpeed: String { tr("播放速度", "Speed") }
    static var minimizePlayer: String { tr("最小化播放器", "Minimize") }
    static var linkPlaceholder: String { tr("链接", "Link") }
    
    // MARK: - 音频错误提示
    static var errEmptyText: String { tr("文本内容为空，无法播放。", "Content is empty, cannot play.") }
    static var errPCMBuffer: String { tr("无法获取 PCM 缓冲。", "Failed to get PCM buffer.") }
    static var errTempURL: String { tr("无法创建音频文件：临时 URL 缺失。", "Temp URL missing.") }
    static var errSynthesisTimeout: String { tr("语音合成阶段长时间无响应，已中止。", "Synthesis timeout, aborted.") }
    static var errPlayerFailed: String { tr("播放器启动失败", "Player failed to start") }
    static var errSessionFailed: String { tr("音频会话激活失败", "Audio session failed") }
    
    // MARK: - 欢迎页 (WelcomeView)
    static var appName: String { tr("「国外消息」", "ONews") }
    static var appSlogan: String { tr("可以听的双语海外资讯", "Bilingual global news you can listen to") }
    static var welcomeInstruction: String { tr("点击右下角按钮\n定制您的专属新闻源", "Tap the button below\nto customize your news feed") }
    static var upToDateMessage: String { tr("请点击右下角“+”按钮来选择你喜欢的新闻源。", "Connection is OK. Tap the '+' button to select your news sources.") }

    // MARK: - 主页 / 列表页
    static var mySubscriptions: String { tr("我的订阅", "My Subscriptions") }
    static var allArticles: String { tr("全部文章", "All Articles") }
    static var allArticlesDesc: String { tr("汇集所有订阅源", "Aggregated Feed") }
    static var unread: String { tr("未读", "Unread") }
    static var read: String { tr("已读", "Read") }
    static var searchResults: String { tr("搜索结果", "Results") }
    static var noMatch: String { tr("未找到匹配的文章", "No matches found") }
    static var noMore: String { tr("该分组内已无更多文章", "No more articles in this group") }
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
    
    // MARK: - 详情页与分享
    static var originalLink: String { tr("原文链接", "Original Link") }
    static var paragraphCopied: String { tr("选中段落已复制", "Paragraph copied") }
    static var unreadCount: String { tr("未读", "Unread") }
    static var imageLoadFailed: String { tr("图片加载失败", "Image load failed") }
    static var saveToAlbum: String { tr("已保存到相册", "Saved to Photos") }
    static var saveFailed: String { tr("保存失败", "Save failed") }
    static var noPhotoPermission: String { tr("没有相册权限，保存失败", "No photo permission") }
    static var imageLoadError: String { tr("图片加载失败，无法保存", "Load error, cannot save") }
    static var shareFooter: String {
        tr("\n\n...\n\n阅读全文请前往App Store免费下载“国外消息“应用程序",
        "\n\n...\n\nRead full article in ONews app, available on the App Store.")
    }
    static var readNext: String { tr("读取下一篇", "Read Next") }
    static var imageLoading: String { tr("正在加载图片...", "Loading images...") }
    static var imagePrepare: String { tr("准备中...", "Preparing...") }
    static var imageDownloaded: String { tr("已下载", "Downloaded") }
    
    // 分页菜单相关
    static var shareTo: String { tr("分享至", "Share to") }
    static var weChat: String { tr("微信", "WeChat") }
    static var more: String { tr("更多", "More") }
    static var contentCopied: String { tr("文章内容已复制", "Content Copied") }
    static var weChatLimitHint: String { 
        tr("由于微信限制，请手动去微信粘贴文章内容", "Due to WeChat limitations, please paste the content manually in the app.") 
    }
    static var openWeChat: String { tr("打开微信", "Open WeChat") }
    static var weChatNotInstalled: String { tr("未安装微信", "WeChat not installed") }
    
    // MARK: - 登录与个人中心
    static var loginAccount: String { tr("登录账户", "Sign In") }
    static var logout: String { tr("退出登录", "Sign Out") }
    static var feedback: String { tr("问题反馈", "Feedback") }
    static var profileTitle: String { tr("账户", "Account") }
    static var premiumUser: String { tr("专业版会员", "Pro Member") }
    static var freeUser: String { tr("免费版用户", "Free User") }
    static var validUntil: String { tr("有效期至", "Valid until") }
    static var notLoggedIn: String { tr("未登录", "Not Logged In") }
    static var loginWelcome: String { tr("登录【国外消息】", "Login to ONews") }
    static var loginDesc: String { tr("成功登录后\n即使更换设备\n也可以同步您的订阅状态", "Sync your subscriptions\nacross devices\nafter logging in") }
    static var later: String { tr("稍后再说", "Not Now") }
    
    // MARK: - 错误提示 (Auth Errors)
    static var errNoIdentityToken: String { tr("无法获取身份令牌", "Could not get Identity Token") }
    static var errServerVerifyFailed: String { tr("服务器验证失败", "Server verification failed") }
    static var errAppleIDCredentialFailed: String { tr("获取 Apple ID 凭证失败", "Failed to get Apple ID credentials") }
    static var errLoginFailedRetry: String { tr("登录失败，请稍后重试", "Login failed, please try again later") }
    static var errProductNotFound: String { tr("未找到商品信息", "Product not found") }
    static var errUserCancelled: String { tr("用户取消支付", "Payment cancelled") }
    static var errTransactionUnverified: String { tr("交易验证失败", "Transaction unverified") }

    // MARK: - 订阅页与支付 (Subscription)
    static var subTitle: String { tr("最近三天的新闻\n需付费观看🥲", "Recent news requires Pro🥲") }
    static var subDesc: String { tr("如果实在不想付费😓\n三天前新闻可永久免费享用\n成功付费后一个月内畅享所有新闻资讯", "Unlock full access with Pro.\nOr enjoy older news (3+ days) for free forever.") }
    static var planFree: String { tr("【当前】免费版", "[Current] Free Plan") }
    static var planFreeDetail: String { tr("可免费浏览 三天前 的所有文章", "Access articles older than 3 days") }
    static var planFreeDetailSubbed: String { tr("可免费浏览 全部 文章", "Access ALL articles") }
    static var planPro: String { tr("专业版套餐", "Pro Plan") }
    static var planProDesc: String { tr("解锁最新日期资讯，与世界同频", "Unlock latest news instantly") }
    static var pricePerMonth: String { tr("¥12/月", "$1.99/mo") }
    static var currentProUser: String { tr("您当前是尊贵的专业版用户", "You are currently a Pro member") }
    static var freePlanFootnote: String { tr("如果不选择付费，您将继续使用免费版，仍可以浏览三天前的文章。", "If you don't upgrade, you can still enjoy articles older than 3 days for free.") }
    static var restorePurchase: String { tr("恢复购买", "Restore Purchase") }
    static var terms: String { tr("使用条款 (EULA)", "Terms of Use") }
    static var privacy: String { tr("隐私政策", "Privacy Policy") }
    static var processingPayment: String { tr("正在处理支付...", "Processing Payment...") }
    static var paymentFailed: String { tr("支付失败", "Payment Failed") }
    static var internalTestTitle: String { tr("内部测试/亲友通道", "Internal Testing") }
    static var enterInviteCode: String { tr("请输入邀请码", "Enter invite code") }
    static var inviteCodeInstruction: String { tr("请输入管理员提供的专用代码以解锁全部功能。", "Please enter the code provided by the admin.") }
    static var redeem: String { tr("兑换", "Redeem") }
    static var restoreResult: String { tr("恢复结果", "Restore Result") }
    static var restoreSuccess: String { tr("成功恢复订阅！您现在可以无限制访问数据。", "Subscription restored successfully!") }
    static var restoreNotFound: String { tr("未发现有效的订阅记录。", "No valid subscription found.") }
    static var restoreFailed: String { tr("恢复失败", "Restore Failed") }
    static var restoring: String { tr("正在恢复购买...", "Restoring...") }
    static var verifying: String { tr("正在验证...", "Verifying...") }

     // MARK: - 资源同步状态 (ResourceManager)
    static var syncStarting: String { tr("启动中...", "Starting...") }
    static var fetchingManifest: String { tr("正在获取新闻列表...", "Fetching news list...") }
    static var cleaningOldResources: String { tr("正在清理旧资源...", "Cleaning old resources...") }
    static var downloadingData: String { tr("正在加载数据...", "Loading Data and Files...") }
    static var downloadingFiles: String { tr("正在下载文件...", "Downloading files...") }
    static var checkingUpdates: String { tr("正在检查更新...", "Checking for updates...") }
    static var upToDate: String { tr("当前已是最新", "Already up to date") }
    static var updateComplete: String { tr("更新完成！", "Update complete!") }
    
    // MARK: - 欢迎页特效默认词汇 (Fallback)
    static var fallbackSource1: String { tr("流行的西方期刊", "Popular Western Journals") }
    static var fallbackSource2: String { tr("指尖的外媒报纸", "Foreign Newspapers at Fingertips") }
    static var fallbackSource3: String { tr("最酷最敢说", "Bold & Trendy Media") }
    static var fallbackSource4: String { tr("欧美媒体", "Euro-American Media") }
    static var fallbackSource5: String { tr("一手新闻源", "Primary News Sources") }
    static var fallbackSource6: String { tr("可以听的海外新闻", "Listen to Global News") }
}
