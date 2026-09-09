import SwiftUI
import StoreKit

// 纯视频版文案表。播放器/缓存页若报缺某个 key，从老工程 Localized 里抄过来即可。
enum Localized {

    static var isEnglish: Bool { UserDefaults.standard.bool(forKey: "isGlobalEnglishMode") }
    private static func t(_ zh: String, _ en: String) -> String { isEnglish ? en : zh }

    // MARK: - 通用
    static var ok: String { t("好的", "OK") }
    static var cancel: String { t("取消", "Cancel") }
    static var confirm: String { t("确定", "Confirm") }
    static var close: String { t("关闭", "Close") }
    static var done: String { t("完成", "Done") }
    static var retry: String { t("重试", "Retry") }
    static var refresh: String { t("刷新", "Refresh") }
    static var search: String { t("搜索", "Search") }
    static var searchPlaceholder: String { t("搜索视频名称 / 导演 / 演员", "Search title / director / cast") }
    static var loading: String { t("加载中…", "Loading…") }
    static var networkError: String { t("网络连接失败，请检查网络后重试", "Network error. Please check your connection.") }
    static var fetchFailed: String { t("获取失败", "Fetch Failed") }
    static var upToDate: String { t("已是最新", "Up to date") }
    static var delete: String { t("删除", "Delete") }

    // MARK: - 账号
    static var loginAccount: String { t("登录", "Sign In") }
    static var logout: String { t("退出登录", "Sign Out") }
    static var profileTitle: String { t("个人中心", "Profile") }
    static var notLoggedIn: String { t("未登录", "Not signed in") }
    static var premiumUser: String { t("尊享会员", "Premium Member") }
    static var freeUser: String { t("免费用户", "Free User") }
    static var validUntil: String { t("有效期至", "Valid until") }
    static var feedback: String { t("意见反馈", "Feedback") }

    // MARK: - 订阅
    static var subTitle: String { t("解锁全部影视内容", "Unlock Everything") }
    static var subDesc: String { t("订阅后全部影视内容无限观看与缓存，不再消耗点数", "Unlimited streaming & downloads. No points needed.") }
    static var planFree: String { t("免费体验", "Free") }
    static var planFreeDetail: String { t("每日赠送免费点数，可观看少量内容", "A few free passes every day") }
    static var planFreeDetailSubbed: String { t("您已是会员，无需消耗点数", "You're a member — no points needed") }
    static var planPro: String { t("尊享会员（每月自动续订）", "Premium (Monthly)") }
    static var planProDesc: String { t("全部影视内容无限观看 / 无限缓存", "Unlimited streaming & downloads") }
    static var currentProUser: String { t("您当前是尊享会员", "You are a Premium member") }
    static var freePlanFootnote: String {
        t("订阅为自动续订商品，到期前 24 小时内自动扣费续订；可随时在「设置 - Apple ID - 订阅」中管理或取消。",
          "Auto-renewable subscription. It renews within 24 hours before the period ends. Manage or cancel anytime in Settings › Apple ID › Subscriptions.")
    }
    static var restorePurchase: String { t("恢复购买", "Restore Purchases") }
    static var restoring: String { t("正在恢复…", "Restoring…") }
    static var restoreResult: String { t("恢复结果", "Restore Result") }
    static var restoreSuccess: String { t("订阅已恢复，感谢支持！", "Subscription restored. Thank you!") }
    static var restoreNotFound: String { t("未找到该 Apple ID 下的有效订阅", "No active subscription found for this Apple ID.") }
    static var restoreFailed: String { t("恢复失败", "Restore failed") }
    static var processingPayment: String { t("正在处理支付…", "Processing…") }
    static var verifying: String { t("正在验证…", "Verifying…") }
    static var paymentFailed: String { t("操作失败", "Failed") }
    static var privacy: String { t("隐私政策", "Privacy Policy") }
    static var terms: String { t("使用条款", "Terms of Use") }
    static var internalTestTitle: String { t("内部测试", "Internal Test") }
    static var enterInviteCode: String { t("请输入邀请码", "Enter code") }
    static var inviteCodeInstruction: String { t("请输入内部邀请码以激活权限", "Enter the internal code to activate access.") }
    static var redeem: String { t("兑换", "Redeem") }

    // MARK: - 错误
    static var errProductNotFound: String { t("未找到订阅商品，请稍后再试", "Subscription product not found.") }
    static var errTransactionUnverified: String { t("交易验证失败", "Transaction could not be verified.") }
    static var errAppleIDCredentialFailed: String { t("获取 Apple ID 凭证失败", "Failed to get Apple ID credential.") }
    static var errNoIdentityToken: String { t("未获取到身份令牌", "No identity token.") }
    static var errServerVerifyFailed: String { t("服务器验证失败", "Server verification failed") }
    static var errLoginFailedRetry: String { t("登录失败，请稍后重试", "Sign in failed. Please try again.") }

    // MARK: - 首启引导
    static var welcomeInstruction: String { t("海量影视内容\n随时随地畅快观看", "Thousands of Movies & Shows\nWatch anytime, anywhere") }
    static var selectChannelTitle: String { t("选择你感兴趣的频道", "Choose Your Channels") }
    static var finishSetup: String { t("完成，进入首页", "Done — Let's Go") }
    static var selectAtLeastOne: String { t("请至少选择一个频道", "Select at least one channel") }

    // MARK: - 价格（StoreKit 拉到后写入缓存，保证展示的是本地化真实价）
    static var cachedDisplayPrice: String {
        UserDefaults.standard.string(forKey: "OVideo_CachedSubPrice") ?? "¥12"
    }
    static var cachedOriginalPrice: String { isEnglish ? "" : "¥24" }

    @ViewBuilder
    static var pricePerMonthView: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(cachedDisplayPrice).font(.title2.bold()).foregroundColor(.orange)
            Text(isEnglish ? "/ month" : "/ 每月").font(.caption).foregroundColor(.secondary)
        }
    }
}

// MARK: - StoreKit 价格缓存
@MainActor
final class StorePriceStore: ObservableObject {
    static let shared = StorePriceStore()
    static let productID = "com.zhangyan.ovideo.subscription.monthly"

    @Published var displayPrice: String =
        UserDefaults.standard.string(forKey: "OVideo_CachedSubPrice") ?? "¥12"

    private init() {}

    func load() async {
        guard let p = try? await Product.products(for: [Self.productID]).first else { return }
        displayPrice = p.displayPrice
        UserDefaults.standard.set(p.displayPrice, forKey: "OVideo_CachedSubPrice")
    }
}
