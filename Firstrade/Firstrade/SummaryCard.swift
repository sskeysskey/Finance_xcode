import SwiftUI

struct SummaryCard: View {
    @ObservedObject var vm: AccountSummaryViewModel

    // 只保留整数金额，百分比保留两位小数
    private func fmt(_ v: Double) -> String {
        String(format: "$%.0f", v)
    }
    private func fmtChange(_ v: Double) -> String {
        let sign = v >= 0 ? "+" : "−"
        return String(format: "\(sign)$%.0f", abs(v))
    }
    private func fmtPct(_ p: Double) -> String {
        String(format: "(%.2f%%)", p)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {  // ← alignment: .top
            // 左侧：账户总值 + 现金购买力
            VStack(alignment: .leading, spacing: 6) {
                Text("账户总值")
                    .font(.caption)
                    .foregroundColor(.gray)
                Text(fmt(vm.totalBalance))
                    .font(.title2)
                    .foregroundColor(.white)

                Text("现金购买力")
                    .font(.caption2)
                    .foregroundColor(.gray)
                Text(fmt(vm.cashBuyingPower))
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 右侧：今日变动
            VStack(alignment: .leading, spacing: 6) {
                Text("今日变动")
                    .font(.caption)
                    .foregroundColor(.gray)

                HStack(spacing: 4) {
                    Text(fmtChange(vm.dailyChange))
                        .font(.title3)  // ← 调小为 .title2
                    Text(fmtPct(vm.dailyChangePercent))
                        .font(.caption)  // 比数字更小的字体
                }
                .foregroundColor(vm.dailyChange >= 0 ? .green : .red)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(Color(red: 40 / 255, green: 45 / 255, blue: 55 / 255))
        .cornerRadius(12)
        .padding(.horizontal)
    }
}
