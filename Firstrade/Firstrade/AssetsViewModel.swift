import SwiftUI
import SQLite3
import Combine

// グラフのデータポイント用構造体
struct DealDataPoint: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let value: Double
}

// 期間選択オプション
enum TimeRangeOption: String, CaseIterable, Identifiable {
    case all = "全部"
    case last3Months = "近三个月"
    case last6Months = "近半年"
    case yearToDate = "年初至今"
    case custom = "筛选" // "筛选" はボタンのラベルとして使用

    var id: String { self.rawValue }
}

class AssetsViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var selectedTimeRange: TimeRangeOption = .yearToDate {
        didSet {
            if oldValue != selectedTimeRange && selectedTimeRange != .custom {
                isFilterActive = false // "筛选" 以外が選択されたらフィルターボタンの強調を解除
            }
        }
    }
    @Published var customStartDate: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @Published var customEndDate: Date = Date()
    @Published var isFilterActive: Bool = false // "筛选"ボタンがアクティブかどうか

    @Published var chartData: [DealDataPoint] = []
    @Published var cumulativeReturn: Double = 0.0
    @Published var returnRate: Double = 0.0 // 収益率

    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil
    
    // データベース関連
    private var db: OpaquePointer?
    private let dbPath: String

    // 日付フォーマッタ
    private let dbDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // 色定義
    let selectedButtonColor = Color.gray
    let deselectedButtonTextColor = Color.white
    let defaultButtonBackgroundColor = Color(red: 40/255, green: 45/255, blue: 55/255)


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
        fetchDataForSelectedRange() // 初期データロード
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
            if db != nil { // エラーがあってもdbポインタがnilでない場合があるため閉じる
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
        // isFilterActive は selectedTimeRange の didSet で処理
        fetchDataForSelectedRange()
    }

    func applyCustomDateRange(start: Date, end: Date) {
        customStartDate = start
        customEndDate = end
        selectedTimeRange = .custom // 内部的にカスタム範囲が選択されたことを示す
        isFilterActive = true       // フィルターボタンをアクティブにする
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
            let dealsQuery = "SELECT date, value FROM Deals WHERE date >= ? AND date <= ? ORDER BY date ASC;"
            var stmtDeals: OpaquePointer?

            // SQLITE_TRANSIENTの代わりに unsafeBitCast を使用
            let SQLITE_TRANSIENT_VALUE = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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

            if let firstDealValue = fetchedDeals.first?.value, let lastDealValue = fetchedDeals.last?.value {
                calculatedCumulativeReturn = lastDealValue - firstDealValue

                let balanceQuery = "SELECT value FROM Balance WHERE date <= ? ORDER BY date DESC LIMIT 1;"
                var stmtBalance: OpaquePointer?
                var startBalanceValue: Double?

                if sqlite3_prepare_v2(db, balanceQuery, -1, &stmtBalance, nil) == SQLITE_OK {
                    // 修正箇所 3
                    sqlite3_bind_text(stmtBalance, 1, startDateString, -1, SQLITE_TRANSIENT_VALUE)
                    if sqlite3_step(stmtBalance) == SQLITE_ROW {
                        startBalanceValue = sqlite3_column_double(stmtBalance, 0)
                    }
                    sqlite3_finalize(stmtBalance)
                } else {
                    let balanceQueryError = "准备Balance查询失败: \(String(cString: sqlite3_errmsg(db)))"
                    print(balanceQueryError)
                     DispatchQueue.main.async {
                        self.errorMessage = (self.errorMessage ?? "") + "\n" + balanceQueryError
                     }
                }

                if let startBalance = startBalanceValue, startBalance != 0 {
                    calculatedReturnRate = (calculatedCumulativeReturn / startBalance)
                } else if startBalanceValue == 0 {
                    calculatedReturnRate = 0
                    print("警告: 用于计算收益率的期初余额为零。")
                     DispatchQueue.main.async {
                        self.errorMessage = (self.errorMessage ?? "") + "\n警告: 用于计算收益率的期初余额为零。"
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
        let today = Date() // endDateは基本的に今日

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
            // 最小日付が見つからない場合のフォールバック（例: 1年前）
            return (earliestDate ?? calendar.date(byAdding: .year, value: -1, to: today)!, today)
        case .last3Months:
            return (calendar.date(byAdding: .month, value: -3, to: today)!, today)
        case .last6Months:
            return (calendar.date(byAdding: .month, value: -6, to: today)!, today)
        case .yearToDate:
            let year = calendar.component(.year, from: today)
            let startOfYear = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
            return (startOfYear, today)
        case .custom:
            return (customStartDate, customEndDate)
        }
    }
}
