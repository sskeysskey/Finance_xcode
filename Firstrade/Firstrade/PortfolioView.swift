import SwiftUI

struct PortfolioView: View {
    let username: String
    @ObservedObject var vm: AccountSummaryViewModel
    @State private var selectedSegment = 0
    private let segments = ["持仓"]    // 这里只放一个

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 摘要卡片
                SummaryCard(vm: vm)
                    .onAppear { vm.fetchBalances() }

                // 分段控件
                Picker("", selection: $selectedSegment) {
                    ForEach(0..<segments.count, id: \.self) { idx in
                        Text(segments[idx]).tag(idx)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal)

                // 空仓位提示
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundColor(.gray.opacity(0.7))
                    Text("您没有持任何仓位")
                        .foregroundColor(.gray)
                    Button(action: {
                        // 搜索操作
                    }) {
                        HStack {
                            Image(systemName: "magnifyingglass")
                            Text("搜索代号")
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(Color.gray, lineWidth: 1)
                        )
                    }
                }
                Spacer()
            }
            .background(Color(red: 25/255, green: 30/255, blue: 39/255).ignoresSafeArea())
            .navigationBarTitle(username, displayMode: .inline)
            .toolbar {
                // 左侧公文包
                ToolbarItem(placement: .navigationBarLeading) {
                    Image(systemName: "briefcase")
                        .foregroundColor(.white)
                }
                // 右侧菜单 / 通知 / 搜索
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(action: {}) {
                        Image(systemName: "line.horizontal.3")
                    }
                    Button(action: {}) {
                        Image(systemName: "bell")
                    }
                    Button(action: {}) {
                        Image(systemName: "magnifyingglass")
                    }
                }
            }
        }
    }
}
