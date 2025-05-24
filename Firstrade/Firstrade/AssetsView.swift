import SwiftUI

struct AssetsView: View {
    @StateObject private var viewModel = AssetsViewModel()
    @State private var showingDateFilter = false

    // 颜色定义
    private let pageBackgroundColor = Color(red: 25/255, green: 30/255, blue: 39/255)
    private let textColor = Color.white
    private let secondaryTextColor = Color.gray
    private let chartLineColor = Color.gray // 曲线颜色
    private let positiveReturnColor = Color.green
    private let negativeReturnColor = Color.red

    // タブの定義 (新股盈亏は削除)
    private enum AssetSubTab: String, CaseIterable, Identifiable {
        case assetAnalysis = "资产分析"
        case profitLossAnalysis = "盈亏分析"
        var id: String { self.rawValue }
    }
    @State private var selectedSubTab: AssetSubTab = .assetAnalysis

    // 日付フォーマッタ (グラフのX軸用)
    private let chartDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter
    }()

    var body: some View {
        NavigationView {
            ZStack {
                pageBackgroundColor.ignoresSafeArea()

                VStack(spacing: 0) {
                    // 上部タブ (资产分析 / 盈亏分析)
                    Picker("分析类型", selection: $selectedSubTab) {
                        ForEach(AssetSubTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding(.horizontal)
                    .padding(.top, 10)
                    .background(pageBackgroundColor) // SegmentedPickerの背景が透明にならないように
                    .onChange(of: selectedSubTab) { _ in
                        // 必要に応じてタブ変更時の処理を記述
                        // 現在はどちらのタブも同じデータを表示するため、特別な処理は不要
                        print("Selected sub-tab: \(selectedSubTab.rawValue)")
                    }

                    // 走势分析セクション
                    trendAnalysisControlsSection
                        .padding(.top, 15)

                    // 收益率走势セクション
                    returnSummarySection
                        .padding(.top, 20)

                    // 折れ線グラフエリア
                    chartArea
                        .padding(.top, 10)
                        .padding(.bottom, 5) // X軸ラベルとの間隔

                    // グラフのX軸ラベル (開始日と終了日)
                    xAxisLabels
                        .padding(.horizontal, 25) // グラフの左右マージンに合わせる

                    Spacer()
                }
            }
            .navigationTitle("我的资产")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("我的资产").font(.headline).foregroundColor(textColor)
                }
                // 右上のアイコンは指示になかったため省略
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .sheet(isPresented: $showingDateFilter) {
                DateFilterView(
                    startDate: $viewModel.customStartDate,
                    endDate: $viewModel.customEndDate,
                    onApply: { start, end in
                        viewModel.applyCustomDateRange(start: start, end: end)
                    }
                )
            }
            .onAppear {
                // ビューが表示されたときに初期データをロード (ViewModelのinitでも実行されるが、再表示時にも対応)
                if viewModel.chartData.isEmpty && !viewModel.isLoading {
                    viewModel.fetchDataForSelectedRange()
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    // MARK: - Subviews
    private var trendAnalysisControlsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("走势分析")
                    .font(.headline)
                    .foregroundColor(textColor)
                Image(systemName: "info.circle")
                    .foregroundColor(secondaryTextColor)
                Spacer()
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(TimeRangeOption.allCases.filter { $0 != .custom }) { range in
                        timeRangeButton(for: range)
                    }
                    filterButton
                }
                .padding(.horizontal)
            }
        }
    }

    private func timeRangeButton(for range: TimeRangeOption) -> some View {
        Button(action: {
            viewModel.selectTimeRange(range)
        }) {
            Text(range.rawValue)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(viewModel.selectedTimeRange == range && !viewModel.isFilterActive ? viewModel.selectedButtonColor : viewModel.defaultButtonBackgroundColor)
                .foregroundColor(viewModel.selectedTimeRange == range && !viewModel.isFilterActive ? .white : viewModel.deselectedButtonTextColor)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(viewModel.selectedTimeRange == range && !viewModel.isFilterActive ? viewModel.selectedButtonColor : secondaryTextColor.opacity(0.5), lineWidth: 0.5)
                )
        }
    }

    private var filterButton: some View {
        Button(action: {
            // viewModel.selectedTimeRange = .custom // 内部的にカスタムを選択状態にする
            // viewModel.isFilterActive = true      // フィルターボタンを強調
            showingDateFilter = true
        }) {
            HStack(spacing: 4) {
                Text(TimeRangeOption.custom.rawValue) // "筛选"
                Image(systemName: "slider.horizontal.3")
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(viewModel.isFilterActive ? viewModel.selectedButtonColor : viewModel.defaultButtonBackgroundColor)
            .foregroundColor(viewModel.isFilterActive ? .white : viewModel.deselectedButtonTextColor)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(viewModel.isFilterActive ? viewModel.selectedButtonColor : secondaryTextColor.opacity(0.5), lineWidth: 0.5)
            )
        }
    }
    
    private var returnSummarySection: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("收益率走势")
                    .font(.headline)
                    .foregroundColor(textColor)
                Image(systemName: "square.and.arrow.up") // デザイン画像のアイコン
                    .foregroundColor(secondaryTextColor)
                Spacer()
            }
            .padding(.horizontal)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("累计收益 · USD")
                        .font(.caption)
                        .foregroundColor(secondaryTextColor)
                    Text(String(format: "%@%.2f", viewModel.cumulativeReturn >= 0 ? "+" : "", viewModel.cumulativeReturn))
                        .font(.title2.bold())
                        .foregroundColor(viewModel.cumulativeReturn >= 0 ? positiveReturnColor : negativeReturnColor)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 4) { // デザイン画像のテキストとアイコン
                        Text("收益率·时间加权")
                            .font(.caption)
                            .foregroundColor(secondaryTextColor)
                        // Image(systemName: "chevron.down") // デザイン画像のアイコン、意味が不明瞭なため一旦コメントアウト
                        //    .font(.caption)
                        //    .foregroundColor(secondaryTextColor)
                    }
                    Text(String(format: "%@%.2f%%", viewModel.returnRate * 100 >= 0 ? "+" : "", viewModel.returnRate * 100))
                        .font(.title3.bold())
                        // デザイン画像ではオレンジだが、意味合い的には収益率なので緑/赤
                        .foregroundColor(viewModel.returnRate >= 0 ? positiveReturnColor : negativeReturnColor)
                }
            }
            .padding(.horizontal)
        }
    }

    private var chartArea: some View {
        Group {
            if viewModel.isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: textColor))
                    .frame(height: 220) // グラフの高さに合わせる
                    .frame(maxWidth: .infinity)
            } else if let errorMsg = viewModel.errorMessage, viewModel.chartData.isEmpty {
                // データがなく、エラーがある場合のみエラーメッセージを大きく表示
                Text(errorMsg)
                    .font(.callout)
                    .foregroundColor(.red)
                    .padding()
                    .frame(height: 220)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                // データがある場合、またはデータがありエラーもある場合はグラフを表示
                LineChartView(
                    dataPoints: viewModel.chartData,
                    strokeColor: chartLineColor,
                    axisColor: secondaryTextColor,
                    axisLabelColor: secondaryTextColor
                )
                .frame(height: 220) // グラフの高さを指定
                .padding(.horizontal, 15) // グラフ描画エリアの左右パディング

                // グラフの下に軽微なエラーメッセージを表示（データはあるが、一部情報が欠けている場合など）
                if let errorMsg = viewModel.errorMessage, !viewModel.chartData.isEmpty {
                    Text(errorMsg)
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .padding(.horizontal, 20)
                        .lineLimit(2)
                }
            }
        }
    }

    private var xAxisLabels: some View {
        HStack {
            if let firstDate = viewModel.chartData.first?.date {
                Text(chartDateFormatter.string(from: firstDate))
            } else {
                Text("----/--/--") // データがない場合のプレースホルダー
            }
            Spacer()
            if let lastDate = viewModel.chartData.last?.date, viewModel.chartData.count > 1 { // データが2つ以上ある場合のみ終了日を表示
                Text(chartDateFormatter.string(from: lastDate))
            } else if viewModel.chartData.count == 1, let firstDate = viewModel.chartData.first?.date {
                 Text(chartDateFormatter.string(from: firstDate)) // データが1つの場合は開始日と同じ
            }
            else {
                Text("----/--/--") // データがない場合のプレースホルダー
            }
        }
        .font(.caption)
        .foregroundColor(secondaryTextColor)
    }
}

// MARK: - Preview
struct AssetsView_Previews: PreviewProvider {
    static var previews: some View {
        AssetsView()
            .preferredColorScheme(.dark) // ダークモードでプレビュー
    }
}
