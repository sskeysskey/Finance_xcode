import SwiftUI

struct MainTabView: View {
    let username: String
    @StateObject private var vm = AccountSummaryViewModel()

    var body: some View {
        TabView {
            PortfolioView(username: username, vm: vm)
                .tabItem {
                    Image(systemName: "briefcase.fill")
                    Text("持仓")
                }

            Text("自选股")
                .tabItem {
                    Image(systemName: "star")
                    Text("自选股")
                }

            Text("市场")
                .tabItem {
                    Image(systemName: "globe")
                    Text("市场")
                }

            Text("订单现况")
                .tabItem {
                    Image(systemName: "rectangle.stack")
                    Text("订单现况")
                }

            Text("我的")
                .tabItem {
                    Image(systemName: "person")
                    Text("我的")
                }
        }
        .accentColor(Color(red: 70/255, green: 130/255, blue: 220/255))
    }
}
