import SwiftUI // 确保导入 SwiftUI

struct MainView: View {
    @ObservedObject var dataService = DataService()
    @State private var isLoading = true

    var body: some View {
        NavigationView {
            TabView {
                StockListView(title: "Top Gainers", items: dataService.topGainers)
                    .tabItem {
                        Label("Top Gainers", systemImage: "arrow.up")
                    }
                
                StockListView(title: "Top Losers", items: dataService.topLosers)
                    .tabItem {
                        Label("Top Losers", systemImage: "arrow.down")
                    }
                
                ETFListView(title: "ETF Gainers", items: dataService.etfGainers)
                    .tabItem {
                        Label("ETF Gainers", systemImage: "chart.line.uptrend.xyaxis")
                    }
                
                ETFListView(title: "ETF Losers", items: dataService.etfLosers)
                    .tabItem {
                        Label("ETF Losers", systemImage: "chart.line.downtrend.xyaxis")
                    }
            }
            .onAppear {
                dataService.loadData()
                isLoading = false
            }
            .overlay(
                Group {
                    if isLoading {
                        LoadingView()
                    }
                }
            )
        }
    }
}

struct LoadingView: View {
    var body: some View {
        ZStack {
            Color.white.opacity(0.8)
                .ignoresSafeArea()
            VStack {
                ProgressView("加载中，请稍候...")
                    .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                    .scaleEffect(1.5, anchor: .center)
            }
        }
    }
}
