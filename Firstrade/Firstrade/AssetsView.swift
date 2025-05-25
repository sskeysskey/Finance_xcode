import Combine
import SQLite3
import SwiftUI

// グラフのデータポイント用構造体
struct DealDataPoint: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let value: Double
}

// 期間選択オプション
enum TimeRangeOption: String, CaseIterable, Identifiable {
    case all = "全部"
    // case last3Months = "近三个月"
    // case last6Months = "近半年"
    // case yearToDate = "年初至今"
    case last1Year = "近一年"  // 変更
    case last2Years = "近两年"  // 変更
    case custom = "筛选"  // "筛选" はボタンのラベルとして使用

    var id: String { self.rawValue }
}

class AssetsViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var selectedTimeRange: TimeRangeOption = .last1Year  // デフォルトを変更 (例: 近一年)
    @Published var customStartDate: Date =
        Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @Published var customEndDate: Date = Date()
    @Published var isFilterActive: Bool = false

    // 追加: 表示用の整形済みカスタム日付文字列
    @Published var displayCustomStartDateString: String? = nil
    @Published var displayCustomEndDateString: String? = nil

    @Published var chartData: [DealDataPoint] = []
    @Published var cumulativeReturn: Double = 0.0
    @Published var returnRate: Double = 0.0  // 収益率

    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil

    // データベース関連
    private var db: OpaquePointer?
    private let dbPath: String

    // private から internal に変更 (Viewでフォーマットする場合に備えて。今回はViewModelで整形)
    internal let dbDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // 色定義
    let selectedButtonColor = Color.gray
    let deselectedButtonTextColor = Color.white
    let defaultButtonBackgroundColor = Color(red: 40 / 255, green: 45 / 255, blue: 55 / 255)

    private let SQLITE_TRANSIENT_VALUE = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - Initialization
    init() {
        guard let path = Bundle.main.path(forResource: "Firstrade", ofType: "db") else {
            self.dbPath = ""
            self.errorMessage = "关键错误：Firstrade.db 未在应用包中找到。"
            // 本番アプリでは、より丁寧なエラー処理を検討してください。
            // fatalError("Firstrade.db not found in bundle.")
            return
        }
        self.dbPath = path
        print("资产页面数据库路径: \(dbPath)")

        if !openDatabase() {
            // openDatabase内でerrorMessageが設定されます
            return
        }
        fetchDataForSelectedRange()  // 初期データロード
    }

    deinit {
        closeDatabase()
    }

    // MARK: - Database Handling
    private func openDatabase() -> Bool {
        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            print("资产页面数据库成功打开。")
            errorMessage = nil
            return true
        } else {
            let errorMsg = "打开数据库时出错 \(dbPath): \(String(cString: sqlite3_errmsg(db)))"
            print(errorMsg)
            errorMessage = errorMsg
            if db != nil {  // エラーがあってもdbポインタがnilでない場合があるため閉じる
                sqlite3_close(db)
                db = nil
            }
            return false
        }
    }

    private func closeDatabase() {
        if db != nil {
            sqlite3_close(db)
            db = nil
            print("资产页面数据库已关闭。")
        }
    }

    // MARK: - Data Fetching and Processing
    func selectTimeRange(_ range: TimeRangeOption) {
        selectedTimeRange = range
        if range != .custom {
            isFilterActive = false
            displayCustomStartDateString = nil  // カスタム日付表示をクリア
            displayCustomEndDateString = nil  // カスタム日付表示をクリア
        }
        // isFilterActive は、カスタムフィルターが適用されたときに applyCustomDateRange で true に設定されます。
        // 他のボタンが押されたときは、ここで false に設定します。
        fetchDataForSelectedRange()
    }

    func applyCustomDateRange(start: Date, end: Date) {
        customStartDate = start
        customEndDate = end
        selectedTimeRange = .custom
        isFilterActive = true
        // 整形済み日付文字列を更新
        displayCustomStartDateString = dbDateFormatter.string(from: start)
        displayCustomEndDateString = dbDateFormatter.string(from: end)
        fetchDataForSelectedRange()
    }

    func fetchDataForSelectedRange() {
        guard db != nil || openDatabase() else {
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil

        let (effectiveStartDate, effectiveEndDate) = getDatesForCurrentSelection()
        let startDateString = dbDateFormatter.string(from: effectiveStartDate)
        let endDateString = dbDateFormatter.string(from: effectiveEndDate)

        print("正在为资产页面获取数据，范围: \(startDateString) 至 \(endDateString)")

        var fetchedDeals: [DealDataPoint] = []
        let dealsQuery =
            "SELECT date, value FROM Deals WHERE date >= ? AND date <= ? ORDER BY date ASC;"
        var stmtDeals: OpaquePointer?

        if sqlite3_prepare_v2(db, dealsQuery, -1, &stmtDeals, nil) == SQLITE_OK {
            // 修正箇所 1
            sqlite3_bind_text(stmtDeals, 1, startDateString, -1, SQLITE_TRANSIENT_VALUE)
            // 修正箇所 2
            sqlite3_bind_text(stmtDeals, 2, endDateString, -1, SQLITE_TRANSIENT_VALUE)

            while sqlite3_step(stmtDeals) == SQLITE_ROW {
                guard let dateStrChars = sqlite3_column_text(stmtDeals, 0) else { continue }
                let dateStr = String(cString: dateStrChars)
                let value = sqlite3_column_double(stmtDeals, 1)
                if let date = dbDateFormatter.date(from: dateStr) {
                    fetchedDeals.append(DealDataPoint(date: date, value: value))
                }
            }
            sqlite3_finalize(stmtDeals)
        } else {
            let queryError = "准备Deals查询失败: \(String(cString: sqlite3_errmsg(db)))"
            print(queryError)
            DispatchQueue.main.async {
                self.errorMessage = queryError
                self.isLoading = false
                self.chartData = []
                self.cumulativeReturn = 0.0
                self.returnRate = 0.0
            }
            return
        }

        var calculatedCumulativeReturn: Double = 0.0
        var calculatedReturnRate: Double = 0.0

        if let firstDealValue = fetchedDeals.first?.value,
            let lastDealValue = fetchedDeals.last?.value
        {
            calculatedCumulativeReturn = lastDealValue - firstDealValue

            var startBalanceValue: Double?
            let dealsStartDateString = dbDateFormatter.string(from: effectiveStartDate)  // Dealsの実際の開始日

            // 1. Dealsの開始日に対応するBalanceデータを検索
            let balanceQueryForDealsStart =
                "SELECT value FROM Balance WHERE date <= ? ORDER BY date DESC LIMIT 1;"
            var stmtBalance: OpaquePointer?
            if sqlite3_prepare_v2(db, balanceQueryForDealsStart, -1, &stmtBalance, nil) == SQLITE_OK
            {
                sqlite3_bind_text(stmtBalance, 1, dealsStartDateString, -1, SQLITE_TRANSIENT_VALUE)
                if sqlite3_step(stmtBalance) == SQLITE_ROW {
                    startBalanceValue = sqlite3_column_double(stmtBalance, 0)
                }
                sqlite3_finalize(stmtBalance)
            } else {
                let balanceQueryError =
                    "准备Balance查询(Deals开始日)失败: \(String(cString: sqlite3_errmsg(db)))"
                print(balanceQueryError)
                DispatchQueue.main.async {
                    self.errorMessage = (self.errorMessage ?? "") + "\n" + balanceQueryError
                }
            }

            // 2. 「全部」選択時で、上記で見つからなかった場合、Balanceテーブルの最古のデータを検索
            if selectedTimeRange == .all && startBalanceValue == nil {
                print("「全部」选择：未在Deals开始日期 \(dealsStartDateString) 找到Balance，尝试Balance表中的最早日期。")
                let oldestBalanceQuery = "SELECT value FROM Balance ORDER BY date ASC LIMIT 1;"
                var stmtOldestBalance: OpaquePointer?
                if sqlite3_prepare_v2(db, oldestBalanceQuery, -1, &stmtOldestBalance, nil)
                    == SQLITE_OK
                {
                    if sqlite3_step(stmtOldestBalance) == SQLITE_ROW {
                        startBalanceValue = sqlite3_column_double(stmtOldestBalance, 0)
                        if startBalanceValue != nil {
                            print("已找到Balance表中的最早余额: \(startBalanceValue!)")
                        } else {
                            print("Balance表中没有找到任何数据。")
                        }
                    }
                    sqlite3_finalize(stmtOldestBalance)
                } else {
                    let oldestBalanceQueryError =
                        "准备Balance最古数据查询失败: \(String(cString: sqlite3_errmsg(db)))"
                    print(oldestBalanceQueryError)
                    DispatchQueue.main.async {
                        self.errorMessage =
                            (self.errorMessage ?? "") + "\n" + oldestBalanceQueryError
                    }
                }
            }

            // 3. 収益率を計算
            if let startBalance = startBalanceValue {
                if startBalance != 0 {
                    calculatedReturnRate = (calculatedCumulativeReturn / startBalance)
                } else {
                    calculatedReturnRate = 0  // または未定義として扱う
                    print("警告: 用于计算收益率的期初余额为零。")
                    DispatchQueue.main.async {
                        self.errorMessage = (self.errorMessage ?? "") + "\n警告: 用于计算收益率的期初余额为零。"
                    }
                }
            } else {
                print("警告: 未能找到日期 \(startDateString) 的期初余额以计算收益率。")
                DispatchQueue.main.async {
                    self.errorMessage = (self.errorMessage ?? "") + "\n警告: 未能找到期初余额以计算收益率。"
                }
            }
        } else if !fetchedDeals.isEmpty {
            calculatedCumulativeReturn = 0.0
            calculatedReturnRate = 0.0
        }

        DispatchQueue.main.async {
            self.chartData = fetchedDeals
            self.cumulativeReturn = calculatedCumulativeReturn
            self.returnRate = calculatedReturnRate
            self.isLoading = false
            if fetchedDeals.isEmpty && self.errorMessage == nil {
                self.errorMessage = "在选定时间段内未找到任何交易数据。"
            }
        }
    }

    private func getDatesForCurrentSelection() -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let today = Date()

        switch selectedTimeRange {
        case .all:
            // "全部" の場合、Dealsテーブルの最初の日付を取得
            var earliestDate: Date?
            let queryMinDate = "SELECT MIN(date) FROM Deals;"
            var stmtMinDate: OpaquePointer?
            if sqlite3_prepare_v2(db, queryMinDate, -1, &stmtMinDate, nil) == SQLITE_OK {
                if sqlite3_step(stmtMinDate) == SQLITE_ROW {
                    if let dateStrChars = sqlite3_column_text(stmtMinDate, 0) {
                        let dateStr = String(cString: dateStrChars)
                        earliestDate = dbDateFormatter.date(from: dateStr)
                    }
                }
                sqlite3_finalize(stmtMinDate)
            }
            return (earliestDate ?? calendar.date(byAdding: .year, value: -5, to: today)!, today)  // フォールバックを5年前に変更
        case .last1Year:  // 変更
            return (calendar.date(byAdding: .year, value: -1, to: today)!, today)
        case .last2Years:  // 変更
            return (calendar.date(byAdding: .year, value: -2, to: today)!, today)
        // case .yearToDate: // 削除
        // let year = calendar.component(.year, from: today)
        // let startOfYear = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        // return (startOfYear, today)
        case .custom:
            return (customStartDate, customEndDate)
        }
    }
}

struct AssetsView: View {
    @StateObject private var viewModel = AssetsViewModel()
    @State private var showingDateFilter = false

    // 颜色定义
    private let pageBackgroundColor = Color(red: 25 / 255, green: 30 / 255, blue: 39 / 255)
    private let textColor = Color.white
    private let secondaryTextColor = Color.gray
    private let chartLineColor = Color.gray  // 曲线颜色
    private let positiveReturnColor = Color.green
    private let negativeReturnColor = Color.red
    private let accentDateColor = Color.blue  // 日付の強調色としてオレンジを定義

    // タブの定義 (新股盈亏は削除)
    // private enum AssetSubTab: String, CaseIterable, Identifiable {
    //     case assetAnalysis = "资产分析"
    //     case profitLossAnalysis = "盈亏分析"
    //     var id: String { self.rawValue }
    // }
    // @State private var selectedSubTab: AssetSubTab = .assetAnalysis

    // 日付フォーマッタ (グラフのX軸用)
    private let chartDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter
    }()

    // MARK: - Colors for Transaction History (as per new request)
    private let timelineActualColor = Color.gray.opacity(0.4)
    private var dotBuyActualColor: Color { positiveReturnColor } // Reuse existing
    private var dotSellActualColor: Color { negativeReturnColor } // Reuse existing
    private let dotOtherActualColor = Color(white: 0.6)
    private var accentColorForTabUnderline: Color { accentDateColor }


    var body: some View {
        NavigationView {
            ZStack {
                pageBackgroundColor.ignoresSafeArea()

                ScrollView { // Added ScrollView to accommodate new section
                    VStack(spacing: 0) {
                        // 上部タブ (资产分析 / 盈亏分析)
                        // Picker("分析类型", selection: $selectedSubTab) {
                        //     ForEach(AssetSubTab.allCases) { tab in
                        //         Text(tab.rawValue).tag(tab)
                        //     }
                        // }
                        // .pickerStyle(SegmentedPickerStyle())
                        // .padding(.horizontal)
                        // .padding(.top, 10)
                        // .background(pageBackgroundColor) // SegmentedPickerの背景が透明にならないように
                        // .onChange(of: selectedSubTab) { _ in
                        //     // 必要に応じてタブ変更時の処理を記述
                        //     // 現在はどちらのタブも同じデータを表示するため、特別な処理は不要
                        //     print("Selected sub-tab: \(selectedSubTab.rawValue)")
                        // }

                        // 走势分析セクション
                        trendAnalysisControlsSection
                            .padding(.top, 15)

                        // --- ここから追加 ---
                        // フィルターがアクティブで、日付文字列が利用可能な場合に表示
                        if viewModel.isFilterActive,
                            let startDateStr = viewModel.displayCustomStartDateString,
                            let endDateStr = viewModel.displayCustomEndDateString
                        {
                            HStack(spacing: 5) {
                                Text("   ")
                                    .font(.subheadline)  // フォントサイズを調整
                                    .foregroundColor(self.secondaryTextColor)
                                    .padding(.leading, 16)  // 左端のパディング
                                Text(startDateStr)
                                    .font(.headline.bold())  // サイズを大きく、太字に
                                    .foregroundColor(self.accentDateColor)  // 目立つ色 (オレンジ)

                                Text("    ～～   ")
                                    .font(.subheadline)
                                    .foregroundColor(self.secondaryTextColor)
                                    .padding(.horizontal, 2)  // "到" の左右に少しスペース

                                Text(endDateStr)
                                    .font(.headline.bold())
                                    .foregroundColor(self.accentDateColor)

                                Spacer()  // 右側の余白を埋めて全体を左寄せにする
                            }
                            .frame(maxWidth: .infinity)  // HStackを画面幅いっぱいに広げる
                            .padding(.vertical, 12)  // 上下のパディング
                            // 背景色をページ背景より少し明るく、または区別できる色に
                            .background(viewModel.defaultButtonBackgroundColor.opacity(0.85))
                            // .background(Color(red: 35/255, green: 40/255, blue: 50/255)) // 例: 少し明るい背景
                            .padding(.top, 15)  // 上の trendAnalysisControlsSection との間隔
                        }
                        // --- ここまで追加 ---

                        returnSummarySection
                            // 上に要素が追加された場合も考慮し、一貫したスペースを保つ
                            .padding(.top, 15)  // 上の要素 (trendAnalysisControlsSection または追加された日付行) との間隔

                        // 折れ線グラフエリア
                        chartArea
                            .padding(.top, 10)
                            .padding(.bottom, 5)  // X軸ラベルとの間隔

                        // グラフのX軸ラベル (開始日と終了日)
                        xAxisLabels
                            .padding(.horizontal, 25)  // グラフの左右マージンに合わせる
                            .padding(.bottom, 20) // Add some space before the new section

                        // --- NEW TRANSACTION HISTORY SECTION ---
                        transactionHistorySection
                            .padding(.top, 10) // Spacing from elements above
                        // --- END NEW TRANSACTION HISTORY SECTION ---

                        // Spacer() // Removed Spacer from here, ScrollView handles empty space
                    }
                }
            }
            .navigationTitle("资产走势分析")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("资产走势分析   (ZhangYan)").font(.headline).foregroundColor(textColor)
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
//                Text(" ")
//                    .font(.headline)
//                    .foregroundColor(textColor)
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
                .background(
                    viewModel.selectedTimeRange == range && !viewModel.isFilterActive
                        ? viewModel.selectedButtonColor : viewModel.defaultButtonBackgroundColor
                )
                .foregroundColor(
                    viewModel.selectedTimeRange == range && !viewModel.isFilterActive
                        ? .white : viewModel.deselectedButtonTextColor
                )
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            viewModel.selectedTimeRange == range && !viewModel.isFilterActive
                                ? viewModel.selectedButtonColor : secondaryTextColor.opacity(0.5),
                            lineWidth: 0.5)
                )
        }
    }

    // MARK: - 修正箇所
    private var filterButton: some View {
        Button(action: {
            // 筛选ボタンが押されたときに、DateFilterView に渡すデフォルトの日付を設定します。
            // viewModel の dbDateFormatter を使用して日付文字列を Date オブジェクトに変換します。
            let defaultStartDateString = "2022-01-01"
            let defaultEndDateString = "2023-01-01"

            if let newStartDate = viewModel.dbDateFormatter.date(from: defaultStartDateString),
                let newEndDate = viewModel.dbDateFormatter.date(from: defaultEndDateString)
            {
                // viewModel のカスタム日付プロパティを更新します。
                // これにより、DateFilterView が表示される際にこれらの日付が初期値として使用されます。
                viewModel.customStartDate = newStartDate
                viewModel.customEndDate = newEndDate
            } else {
                // 日付の解析に失敗した場合のフォールバック処理です。
                // エラーメッセージをコンソールに出力し、既存のカスタム日付（またはViewModelの初期デフォルト値）が使用されます。
                print("错误：无法解析筛选的默认自定义日期。将使用ViewModel当前的自定义日期或其初始默认值。")
            }

            // DateFilterView を表示します。
            showingDateFilter = true
        }) {
            HStack(spacing: 4) {
                Text(TimeRangeOption.custom.rawValue)  // "筛选"
                Image(systemName: "slider.horizontal.3")
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                viewModel.isFilterActive
                    ? viewModel.selectedButtonColor : viewModel.defaultButtonBackgroundColor
            )
            .foregroundColor(
                viewModel.isFilterActive ? .white : viewModel.deselectedButtonTextColor
            )
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        viewModel.isFilterActive
                            ? viewModel.selectedButtonColor : secondaryTextColor.opacity(0.5),
                        lineWidth: 0.5)
            )
        }
    }
    // MARK: - 修正箇所ここまで

    private var returnSummarySection: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
//                Text("  ")
//                    .font(.headline)
//                    .foregroundColor(textColor)
                Spacer()
            }
            .padding(.horizontal)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("累计收益 · USD")
                        .font(.caption)
                        .foregroundColor(secondaryTextColor)
                    Text(
                        String(
                            format: "%@%.2f", viewModel.cumulativeReturn >= 0 ? "+" : "",
                            viewModel.cumulativeReturn)
                    )
                    .font(.title2.bold())
                    .foregroundColor(
                        viewModel.cumulativeReturn >= 0 ? positiveReturnColor : negativeReturnColor)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 4) {  // デザイン画像のテキストとアイコン
                        Text("收益率")
                            .font(.caption)
                            .foregroundColor(secondaryTextColor)
                        // Image(systemName: "chevron.down") // デザイン画像のアイコン、意味が不明瞭なため一旦コメントアウト
                        //    .font(.caption)
                        //    .foregroundColor(secondaryTextColor)
                    }
                    Text(
                        String(
                            format: "%@%.2f%%", viewModel.returnRate * 100 >= 0 ? "+" : "",
                            viewModel.returnRate * 100)
                    )
                    .font(.title3.bold())
                    // デザイン画像ではオレンジだが、意味合い的には収益率なので緑/赤
                    .foregroundColor(
                        viewModel.returnRate >= 0 ? positiveReturnColor : negativeReturnColor)
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
                    .frame(height: 220)  // グラフの高さに合わせる
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
                .frame(height: 220)  // グラフの高さを指定
                .padding(.horizontal, 15)  // グラフ描画エリアの左右パディング

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
                Text("----/--/--")  // データがない場合のプレースホルダー
            }
            Spacer()
            if let lastDate = viewModel.chartData.last?.date, viewModel.chartData.count > 1 {  // データが2つ以上ある場合のみ終了日を表示
                Text(chartDateFormatter.string(from: lastDate))
            } else if viewModel.chartData.count == 1,
                let firstDate = viewModel.chartData.first?.date
            {
                Text(chartDateFormatter.string(from: firstDate))  // データが1つの場合は開始日と同じ
            } else {
                Text("----/--/--")  // データがない場合のプレースホルダー
            }
        }
        .font(.caption)
        .foregroundColor(secondaryTextColor)
    }

    // MARK: - New Transaction History Section (as per request)
    private var transactionHistorySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tab-like header
            HStack(spacing: 0) {
                // VStack 包含 "账户记录" 和 下划线，现在是第一个元素
                VStack(spacing: 3) {
                    Text("账户记录")
                        .font(.system(size: 15, weight: .medium))
                        .padding(.vertical, 10)
                        .padding(.horizontal, 20)
                        .foregroundColor(textColor) // "账户记录" 保持 textColor，因为它现在是选中的/主要的
                    Rectangle()
                        .frame(width: 40, height: 2.5) // 修改这里：增加了 width 使其变短，40 是一个示例值，您可以根据需要调整
                        .foregroundColor(accentColorForTabUnderline)
                }

                // "订单现况" 现在是第二个元素
                Text("订单现况")
                    .font(.system(size: 15, weight: .medium))
                    .padding(.vertical, 10)
                    .padding(.horizontal, 20)
                    .foregroundColor(secondaryTextColor) // "订单现况" 保持 secondaryTextColor

                Spacer()
            }
            .padding(.leading) // Align with content below
            .padding(.bottom, 8)

            // List of transactions
            VStack(alignment: .leading, spacing: 0) {
                transactionRowView(month: "3月", day: "25", year: "2025", transactionType: "卖出 CHAU", transactionDetails: "38.68 股数 @ $16.88", dotColor: dotSellActualColor)
                transactionRowView(month: "3月", day: "19", year: "2025", transactionType: "买进 CHAU", transactionDetails: "38.68 @ $25.36", dotColor: dotBuyActualColor)
                transactionRowView(month: "12月", day: "01", year: "2024", transactionType: "卖出 IBIT", transactionDetails: "14 股数 @ $35.64", dotColor: dotSellActualColor)
                transactionRowView(month: "6月", day: "05", year: "2024", transactionType: "取款", transactionDetails: "$5,000.00", dotColor: dotOtherActualColor)
                transactionRowView(month: "6月", day: "01", year: "2024", transactionType: "买进 IBIT", transactionDetails: "14 股数 @ $36.04", dotColor: dotBuyActualColor)
                // 利息 (Interest) entry for 9月 16 is intentionally omitted as per request
                transactionRowView(month: "5月", day: "27", year: "2024", transactionType: "卖出 TLT", transactionDetails: "23.84 @ $25.36", dotColor: dotBuyActualColor)
                transactionRowView(month: "5月", day: "19", year: "2024", transactionType: "买进 TLT", transactionDetails: "23.84 @ $29.36", dotColor: dotBuyActualColor)
            }
            .padding(.leading, 20) // Indent the transaction list slightly for the timeline
            .padding(.trailing, 15) // Overall right padding
        }
    }

    private func transactionRowView(
        month: String, day: String, year: String,
        transactionType: String, transactionDetails: String,
        dotColor: Color
    ) -> some View {
        HStack(alignment: .center, spacing: 10) { // Adjusted spacing
            // Date Column
            VStack(alignment: .center, spacing: 2) {
                Text(month)
                    .font(.caption)
                    .foregroundColor(secondaryTextColor)
                Text(day)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(textColor)
                Text(year)
                    .font(.caption)
                    .foregroundColor(secondaryTextColor)
            }
            .frame(width: 40) // Date column width

            // Timeline Column
            ZStack {
                // The continuous vertical line for this row's segment
                Rectangle()
                    .fill(timelineActualColor) // Use the defined timeline color
                    .frame(width: 1.5)

                // Circle to "punch out" the line behind the dot
                Circle()
                    .fill(pageBackgroundColor) // Use the main page background color
                    .frame(width: 12, height: 12) // Size of the punch-out

                // The actual colored dot
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8) // Size of the transaction dot
            }
            .frame(width: 12) // Width of the timeline ZStack

            // Details Column
            VStack(alignment: .leading, spacing: 3) {
                Text(transactionType)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(textColor)
                Text(transactionDetails)
                    .font(.system(size: 12))
                    .foregroundColor(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true) // Allow text to wrap
            }
            .padding(.leading, 4) // Small space after timeline

            Spacer() // Pushes content to the left
        }
        .padding(.vertical, 12) // Vertical padding for the row, defines its height and spacing
    }

}

struct DateFilterView: View {
    @Binding var startDate: Date
    @Binding var endDate: Date
    var onApply: (Date, Date) -> Void
    @Environment(\.presentationMode) var presentationMode

    // 色定義
    private let pageBackgroundColor = Color(red: 25 / 255, green: 30 / 255, blue: 39 / 255)
    private let textColor = Color.white
    private let accentButtonColor = Color(hex: "3B82F6")  // Firstradeの標準的なアクセントカラー

    @State private var tempStartDate: Date
    @State private var tempEndDate: Date
    @State private var dateError: String? = nil

    init(startDate: Binding<Date>, endDate: Binding<Date>, onApply: @escaping (Date, Date) -> Void)
    {
        _startDate = startDate
        _endDate = endDate
        self.onApply = onApply
        // tempStartDate と tempEndDate は、親ビューから渡されたバインディングの現在の値で初期化されます。
        // AssetsView の filterButton アクションで viewModel.customStartDate と viewModel.customEndDate が
        // 更新されていれば、ここでその新しい値が tempStartDate と tempEndDate の初期値となります。
        _tempStartDate = State(initialValue: startDate.wrappedValue)
        _tempEndDate = State(initialValue: endDate.wrappedValue)
    }

    var body: some View {
        NavigationView {
            ZStack {
                pageBackgroundColor.ignoresSafeArea()
                VStack(spacing: 20) {
                    Text("选择日期范围")
                        .font(.title2.bold())
                        .foregroundColor(textColor)
                        .padding(.top, 30)

                    DatePicker("起始日期", selection: $tempStartDate, displayedComponents: .date)
                        .foregroundColor(textColor)
                        .colorScheme(.dark)  // DatePickerのUIをダークテーマに
                        .accentColor(accentButtonColor)  // カレンダー内の選択色
                        .padding(.horizontal)

                    DatePicker(
                        "截止日期", selection: $tempEndDate, in: tempStartDate...,
                        displayedComponents: .date
                    )
                    .foregroundColor(textColor)
                    .colorScheme(.dark)
                    .accentColor(accentButtonColor)
                    .padding(.horizontal)

                    if let error = dateError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.horizontal)
                    }

                    Button(action: {
                        if tempEndDate < tempStartDate {
                            dateError = "截止日期不能早于起始日期。"
                            return
                        }
                        dateError = nil
                        onApply(tempStartDate, tempEndDate)
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        Text("确定")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(height: 48)
                            .frame(maxWidth: .infinity)
                            .background(accentButtonColor)
                            .cornerRadius(8)
                    }
                    .padding(.horizontal)
                    .padding(.top, 20)

                    Spacer()
                }
            }
            .navigationTitle("筛选日期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("筛选日期").foregroundColor(textColor)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("取消") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .foregroundColor(accentButtonColor)
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)  // ナビゲーションバーのアイテムを明るく
        }
        .navigationViewStyle(StackNavigationViewStyle())  // モーダル表示に適したスタイル
    }
}

struct LineChartView: View {
    let dataPoints: [DealDataPoint]
    let strokeColor: Color
    let axisColor: Color
    let axisLabelColor: Color

    private var maxY: Double { (dataPoints.map { $0.value }.max() ?? 0) }
    private var minY: Double { (dataPoints.map { $0.value }.min() ?? 0) }
    private var ySpread: Double {
        let spread = maxY - minY
        return spread == 0 ? 1 : spread  // 0除算を避ける
    }

    var body: some View {
        GeometryReader { geometry in
            if dataPoints.isEmpty {
                Text("图表无可用数据")
                    .foregroundColor(axisLabelColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                Path { path in
                    // グラフの描画領域を少し内側にオフセットする（ラベルのため）
                    let drawingWidth = geometry.size.width * 0.9  // 左右に5%ずつのマージン
                    let drawingHeight = geometry.size.height * 0.9  // 上下に5%ずつのマージン
                    let xOffset = geometry.size.width * 0.05
                    let yOffset = geometry.size.height * 0.05

                    for i in dataPoints.indices {
                        let dataPoint = dataPoints[i]

                        // X座標の計算 (データポイントの数に基づいて均等に配置)
                        let xPosition: CGFloat
                        if dataPoints.count == 1 {
                            xPosition = drawingWidth / 2  // データが1つなら中央に
                        } else {
                            xPosition = CGFloat(i) * (drawingWidth / CGFloat(dataPoints.count - 1))
                        }

                        // Y座標の計算 (Y軸は反転し、スプレッドに基づいてスケーリング)
                        let yPosition =
                            drawingHeight * (1 - CGFloat((dataPoint.value - minY) / ySpread))

                        let actualX = xPosition + xOffset
                        let actualY = yPosition + yOffset

                        if i == 0 {
                            path.move(to: CGPoint(x: actualX, y: actualY))
                        } else {
                            path.addLine(to: CGPoint(x: actualX, y: actualY))
                        }
                        // データポイントに円を描画 (オプション)
                        // path.addEllipse(in: CGRect(x: actualX - 2, y: actualY - 2, width: 4, height: 4))
                    }
                }
                .stroke(strokeColor, lineWidth: 2)
            }
        }
    }
}
