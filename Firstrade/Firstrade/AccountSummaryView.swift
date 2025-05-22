import SwiftUI

struct AccountSummaryView: View {
    @StateObject private var vm = AccountSummaryViewModel()

    // 简单的格式化
    private func fmtCurrency(_ v: Double) -> String {
        String(format: "$%.2f", v)
    }
    private func fmtChange(_ v: Double) -> String {
        let sign = v >= 0 ? "+" : "-"
        return String(format: "\(sign)$%.2f", abs(v))
    }
    private func fmtPercent(_ p: Double) -> String {
        String(format: "(%.2f%%)", p)
    }

    var body: some View {
        ZStack {
            Color(red: 25/255, green: 30/255, blue: 39/255)
                .ignoresSafeArea()

            VStack(spacing: 30) {
                Spacer().frame(height: 20)

                Text("账户总览")
                    .font(.largeTitle)
                    .foregroundColor(.white)

                VStack(spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("账户总额")
                                .font(.caption)
                                .foregroundColor(.gray)
                            Text(fmtCurrency(vm.totalBalance))
                                .font(.title2)
                                .foregroundColor(.white)
                        }
                        Spacer()
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("现金购买力")
                                .font(.caption)
                                .foregroundColor(.gray)
                            Text(fmtCurrency(vm.cashBuyingPower))
                                .font(.title2)
                                .foregroundColor(.white)
                        }
                        Spacer()
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("今日变动")
                                .font(.caption)
                                .foregroundColor(.gray)
                            HStack {
                                Text(fmtChange(vm.dailyChange))
                                    .font(.title2)
                                    .foregroundColor(vm.dailyChange >= 0 ? .green : .red)
                                Text(fmtPercent(vm.dailyChangePercent))
                                    .font(.subheadline)
                                    .foregroundColor(vm.dailyChange >= 0 ? .green : .red)
                            }
                        }
                        Spacer()
                    }
                }
                .padding()
                .background(Color(red: 40/255, green: 45/255, blue: 55/255))
                .cornerRadius(12)
                .padding(.horizontal, 30)

                Spacer()
            }
        }
        .onAppear {
            vm.fetchBalances()
        }
        .navigationBarTitle("账户概览", displayMode: .inline)
    }
}

struct AccountSummaryView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            AccountSummaryView()
        }
    }
}
