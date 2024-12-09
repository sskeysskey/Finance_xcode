import SwiftUI
import Foundation

@main
struct Finance: App {
    var body: some Scene {
        WindowGroup {
            MainContentView()
        }
    }
}

struct MainContentView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) { // spacing: 0 可以更好地控制间距
                // 1. 上部：扇区展示
                IndicesContentView()
                    .frame(maxHeight: .infinity, alignment: .top)
                
                Divider()
                
                // 2. 中部：搜索框
                SearchContentView()
                    .frame(height: 100)
                    .padding(.vertical, 10)
                
                Divider()
                
                // 3. 下部：自定义标签栏
                TopContentView()
                    .frame(height: 60) // 给标签栏一个合适的高度
                    .background(Color(.systemBackground)) // 确保底部有背景色
            }
            .navigationBarTitle("经济数据与搜索", displayMode: .inline)
        }
    }
}
