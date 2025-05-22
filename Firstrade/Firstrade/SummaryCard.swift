import SwiftUI

struct SummaryCard: View {
    @ObservedObject var vm: AccountSummaryViewModel

    private func fmt(_ v: Double) -> String {
        String(format: "$%.2f", v)
    }
    private func fmtChange(_ v: Double) -> String {
        let sign = v >= 0 ? "+" : "−"
        return String(format: "\(sign)$%.2f", abs(v))
    }
    private func fmtPct(_ p: Double) -> String {
        String(format: "(%.2f%%)", p)
    }

    var body: some View {
        HStack(spacing: 0) {
            // 左侧：账户总值 + 现金购买力
            VStack(alignment: .leading, spacing: 6) {
                Text("账户总值")
                    .font(.caption)
                    .foregroundColor(.gray)
                Text(fmt(vm.totalBalance))
                    .font(.title)
                    .foregroundColor(.white)

                HStack(spacing: 4) {
                    Text("现金购买力")
                        .font(.caption2)
                        .foregroundColor(.gray)
                    Spacer()
                }
                Text(fmt(vm.cashBuyingPower))
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 右侧：今日变动 + 已交割资金
            VStack(alignment: .leading, spacing: 6) {
                Text("今日变动")
                    .font(.caption)
                    .foregroundColor(.gray)
                HStack(spacing: 4) {
                    Text(fmtChange(vm.dailyChange))
                    Text(fmtPct(vm.dailyChangePercent))
                }
                .font(.title)
                .foregroundColor(vm.dailyChange >= 0 ? .green : .red)

                HStack(spacing: 4) {
                    Text("已交割资金")
                        .font(.caption2)
                        .foregroundColor(.gray)
                    Spacer()
                }
                Text(fmt(vm.cashBuyingPower))
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(Color(red: 40/255, green: 45/255, blue: 55/255))
        .cornerRadius(12)
        .padding(.horizontal)
    }
}
