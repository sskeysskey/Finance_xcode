
import Foundation
import SwiftUI

// MARK: - 买卖点配色（与 mac 端 ft_trades 的 BUY_COLOR / SELL_COLOR 一致）
extension Color {
    static let ftBuy  = Color(red: 94/255,  green: 129/255, blue: 172/255)   // #5E81AC
    static let ftSell = Color(red: 208/255, green: 135/255, blue: 112/255)   // #D08770
}

enum FTSide: Sendable {
    case buy, sell
    var title: String { self == .buy ? "买入" : "卖出" }
    var short: String { self == .buy ? "买" : "卖" }
}

// MARK: - 日期键工具（yyyyMMdd 整数，避免大量 Calendar.isSameDay 比较）
enum FTDay {
    static func key(_ date: Date, calendar: Calendar = Calendar.current) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    /// 支持 "2026-07-01"、"2026/07/01"、"2026-07-01 10:30"、"07/01/2026"
    static func key(from string: String) -> Int? {
        let nums = string.split(whereSeparator: { !$0.isNumber }).map(String.init)
        guard nums.count >= 3 else { return nil }
        var y = 0, m = 0, d = 0
        if nums[0].count == 4 {
            y = Int(nums[0]) ?? 0; m = Int(nums[1]) ?? 0; d = Int(nums[2]) ?? 0
        } else if nums[2].count == 4 {
            m = Int(nums[0]) ?? 0; d = Int(nums[1]) ?? 0; y = Int(nums[2]) ?? 0
        } else {
            return nil
        }
        guard y > 1900, (1...12).contains(m), (1...31).contains(d) else { return nil }
        return y * 10000 + m * 100 + d
    }

    static func date(fromKey k: Int, calendar: Calendar = Calendar.current) -> Date? {
        calendar.date(from: DateComponents(year: k / 10000, month: (k / 100) % 100, day: k % 100))
    }

    static func monthDay(fromKey k: Int) -> String {
        String(format: "%02d-%02d", (k / 100) % 100, k % 100)
    }
}

// MARK: - 某日某方向的成交汇总
struct FTTradeAgg: Sendable {
    var count: Int = 0
    var amount: Double = 0          // 成交总额
    var shares: Double = 0          // 股数（展示用）
    var sharesExact: Bool = true    // false 表示有部分股数是用 金额/价格 估算的
    var pricedAmount: Double = 0    // 参与均价计算的金额
    var pricedShares: Double = 0    // 参与均价计算的股数

    /// 成交量加权均价
    var avgPrice: Double? {
        pricedShares > 0 ? pricedAmount / pricedShares : nil
    }

    /// 只保留有限的正数，否则返回 nil
    private static func positive(_ v: Double?) -> Double? {
        guard let x = v, x.isFinite else { return nil }
        let y = Swift.abs(x)
        return y > 0 ? y : nil
    }

    mutating func add(amount amt: Double?, quantity qty: Double?, price pr: Double?) {
        count += 1

        let q: Double? = FTTradeAgg.positive(qty)
        let p: Double? = FTTradeAgg.positive(pr)
        var a: Double? = FTTradeAgg.positive(amt)

        // 金额缺失时用 数量 × 价格 推算
        if a == nil, let qv = q, let pv = p {
            a = qv * pv
        }
        if let av = a {
            amount += av
        }

        // 股数：优先用真实数量，否则用 金额 / 价格 估算
        var sh: Double? = q
        var exact: Bool = (q != nil)
        if sh == nil, let av = a, let pv = p {
            sh = av / pv
            exact = false
        }

        if let shv = sh {
            shares += shv
            if !exact { sharesExact = false }
            if let av = a {
                pricedAmount += av
                pricedShares += shv
            }
        }
    }

    mutating func merge(_ o: FTTradeAgg) {
        count += o.count
        amount += o.amount
        shares += o.shares
        sharesExact = sharesExact && o.sharesExact
        pricedAmount += o.pricedAmount
        pricedShares += o.pricedShares
    }
}

struct FTTradeDay: Sendable {
    let dayKey: Int
    let date: Date
    var buy: FTTradeAgg? = nil
    var sell: FTTradeAgg? = nil
}

// MARK: - 解析 / 文案
enum FTTradeStore {
    /// 与 mac 端 _ft_norm_sym 一致：大写、'.' → '-'
    static func normSymbol(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().replacingOccurrences(of: ".", with: "-")
    }

    /// 解析 firstrade_orders_xxxxxx.json → [Symbol: [按日期升序的 FTTradeDay]]
    static func parse(_ data: Data) -> [String: [FTTradeDay]] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        // lean_v1: {"_meta":..., "orders": {...}}；兼容老格式：顶层就是订单
        let orders: [String: Any] = (root["orders"] as? [String: Any])
            ?? root.filter { !$0.key.hasPrefix("_") }

        let cal = Calendar.current
        var bucket: [String: [Int: FTTradeDay]] = [:]

        for (_, value) in orders {
            guard let o = value as? [String: Any],
                  let rawSym = o["symbol"] as? String else { continue }
            let sym = normSymbol(rawSym)
            guard !sym.isEmpty else { continue }

            let sideStr = ((o["side"] as? String) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            let side: FTSide
            if sideStr == "buy" { side = .buy } else if sideStr == "sell" { side = .sell } else { continue }

            guard isFilled(o) else { continue }   // 只统计已成交

            guard let ds = o["date"] as? String,
                  let k = FTDay.key(from: ds),
                  let d = FTDay.date(fromKey: k, calendar: cal) else { continue }

            let amount = number(o["amount"])
            let qty = number(o["quantity"]) ?? number(o["qty"])
            let price = number(o["price"])

            var day = bucket[sym]?[k] ?? FTTradeDay(dayKey: k, date: d)
            switch side {
            case .buy:
                var a = day.buy ?? FTTradeAgg()
                a.add(amount: amount, quantity: qty, price: price)
                day.buy = a
            case .sell:
                var a = day.sell ?? FTTradeAgg()
                a.add(amount: amount, quantity: qty, price: price)
                day.sell = a
            }
            bucket[sym, default: [:]][k] = day
        }
        return bucket.mapValues { $0.values.sorted { $0.dayKey < $1.dayKey } }
    }

    private static func isFilled(_ o: [String: Any]) -> Bool {
        if let st = (o["st"] as? String)?.trimmingCharacters(in: .whitespaces).uppercased(), !st.isEmpty {
            return st.hasPrefix("F")
        }
        // 兜底：没有 st 字段时看 status 文本
        let txt = "\(o["status"] ?? "") \(o["status_text"] ?? "")".lowercased()
        let negative = ["未成交", "取消", "撤", "拒绝", "失效", "过期", "cancel", "reject", "expire", "pending", "open"]
        if negative.contains(where: { txt.contains($0) }) { return false }
        return txt.contains("成交") || txt.contains("filled") || txt.contains("executed")
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        if let s = v as? String {
            let c = s.replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "$", with: "")
                .trimmingCharacters(in: .whitespaces)
            if let d = Double(c), d.isFinite { return d }
        }
        return nil
    }

    static func money(_ v: Double) -> String {
        if v >= 1_000_000_000 { return String(format: "$%.2fB", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: "$%.2fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "$%.2fK", v / 1_000) }
        return String(format: "$%.2f", v)
    }

    static func sharesText(_ v: Double) -> String {
        abs(v - v.rounded()) < 1e-6 ? String(format: "%.0f", v) : String(format: "%.2f", v)
    }

    /// 拖动时信息区显示的一行
    static func detailText(side: FTSide, agg: FTTradeAgg, latest: Double?) -> String {
        var parts = ["\(side.title) \(agg.count)笔"]
        if agg.shares > 0 { parts.append("\(agg.sharesExact ? "" : "≈")\(sharesText(agg.shares))股") }
        if agg.amount > 0 { parts.append(money(agg.amount)) }
        if let p = agg.avgPrice {
            parts.append("均价\(String(format: "%.2f", p))")
            if let l = latest, p > 0 {
                parts.append("至今" + String(format: "%+.2f%%", (l - p) / p * 100))
            }
        }
        return parts.joined(separator: " · ")
    }

    /// 气泡文案（两行）
    static func bubbleText(side: FTSide, agg: FTTradeAgg, dayKey: Int, latest: Double?) -> String {
        var line1 = "\(side.short) \(FTDay.monthDay(fromKey: dayKey))"
        if agg.amount > 0 { line1 += " \(money(agg.amount))" }
        var line2 = ""
        if let p = agg.avgPrice {
            line2 = "@\(String(format: "%.2f", p))"
            if let l = latest, p > 0 { line2 += " " + String(format: "%+.1f%%", (l - p) / p * 100) }
        } else if agg.count > 1 {
            line2 = "\(agg.count)笔"
        }
        return line2.isEmpty ? line1 : "\(line1)\n\(line2)"
    }
}
