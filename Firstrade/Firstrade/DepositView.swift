import Combine
import SQLite3
import SwiftUI

struct TransactionRecord: Identifiable {
    let id: Int
    let date: String
    let value: Double
    let type: Int  // 0 for deposit, 1 for withdrawal

    var transactionTypeString: String {
        type == 0 ? "Deposit" : "Withdrawal"
    }

    var formattedValue: String {
        // Ensuring two decimal places for currency
        String(format: "$%.2f", value)
    }

    // As per database structure, status is not available. Defaulting to "已完成".
    // The design image's "已驳回" for 2024-08-21 $1000 cannot be derived from the current DB.
    var status: String {
        return "Complete"
    }
}

class DepositWithdrawViewModel: ObservableObject {
    @Published var transactions: [TransactionRecord] = []
    @Published var isLoadingPage = false
    @Published var canLoadMorePages = true
    @Published var databaseError: String? = nil

    private var currentPage = 0
    private let itemsPerPage = 15
    private var db: OpaquePointer?
    private let dbPath: String

    init() {
        guard let path = Bundle.main.path(forResource: "Firstrade", ofType: "db") else {
            let errorMsg =
                "❌ Failed to find Firstrade.db in bundle. Ensure it's added to the target and 'Copy Bundle Resources'."
            print(errorMsg)
            self.dbPath = ""
            self.databaseError = errorMsg
            // fatalError(errorMsg) // Or handle more gracefully
            return
        }
        self.dbPath = path
        print("Database path: \(dbPath)")

        if !openDatabase() {
            // Error already set in openDatabase()
            return
        }
        fetchTransactions(isRefresh: true)  // Initial fetch
    }

    deinit {
        if db != nil {
            sqlite3_close(db)
            db = nil
            print("🗃️ Database closed.")
        }
    }

    private func openDatabase() -> Bool {
        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            print("✅ Database opened successfully at \(dbPath)")
            databaseError = nil
            return true
        } else {
            let errorMsg =
                "❌ Error opening database \(dbPath): \(String(cString: sqlite3_errmsg(db)))"
            print(errorMsg)
            databaseError = errorMsg
            if db != nil {
                sqlite3_close(db)
                db = nil
            }
            return false
        }
    }

    func refreshTransactions() {
        guard !isLoadingPage else { return }
        print("🔄 Refreshing transactions...")
        currentPage = 0
        transactions = []
        canLoadMorePages = true  // Reset ability to load more
        databaseError = nil  // Clear previous errors

        if db == nil {  // Attempt to reopen if closed
            guard openDatabase() else { return }
        }
        fetchTransactions(isRefresh: true)
    }

    func fetchTransactions(isRefresh: Bool = false) {
        if isLoadingPage && !isRefresh {
            print("ℹ️ Already loading page, request ignored.")
            return
        }
        if !canLoadMorePages && !isRefresh {
            print("ℹ️ No more pages to load.")
            return
        }

        isLoadingPage = true
        if isRefresh {
            DispatchQueue.main.async {  // Ensure UI updates on main thread for refresh start
                self.transactions = []
            }
        }

        // Ensure DB is open
        if db == nil {
            print("⚠️ Database was nil, attempting to reopen.")
            guard openDatabase() else {
                DispatchQueue.main.async {
                    self.isLoadingPage = false
                }
                return
            }
        }

        let offset = currentPage * itemsPerPage
        // Note: SQLite date strings 'YYYY-MM-DD' can be sorted lexicographically for date order.
        let query =
            "SELECT id, date, value, type FROM Deposit ORDER BY date DESC LIMIT \(itemsPerPage) OFFSET \(offset);"
        var statement: OpaquePointer?

        print("➡️ Preparing query: \(query)")
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            var newTransactions: [TransactionRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = Int(sqlite3_column_int(statement, 0))
                // Ensure date is read correctly; it should be TEXT in DB
                let dateChars = sqlite3_column_text(statement, 1)
                let date = dateChars != nil ? String(cString: dateChars!) : "Unknown Date"

                let value = sqlite3_column_double(statement, 2)
                let type = Int(sqlite3_column_int(statement, 3))

                let record = TransactionRecord(id: id, date: date, value: value, type: type)
                newTransactions.append(record)
            }
            sqlite3_finalize(statement)

            DispatchQueue.main.async {
                if isRefresh {
                    self.transactions = newTransactions
                } else {
                    self.transactions.append(contentsOf: newTransactions)
                }

                if !newTransactions.isEmpty {
                    self.currentPage += 1
                }

                self.canLoadMorePages = newTransactions.count == self.itemsPerPage
                self.isLoadingPage = false
                self.databaseError = nil  // Clear error on successful fetch
                print(
                    "✅ Fetched \(newTransactions.count) transactions. Total: \(self.transactions.count). Current Page: \(self.currentPage). Can load more: \(self.canLoadMorePages)"
                )
                if newTransactions.isEmpty && !isRefresh {
                    print("ℹ️ Fetched an empty page, likely end of data.")
                }
            }
        } else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            print("❌ SELECT statement could not be prepared: \(errorMessage). Query: \(query)")
            DispatchQueue.main.async {
                self.isLoadingPage = false
                self.databaseError = "Failed to fetch records: \(errorMessage)"
            }
        }
    }
}

struct DepositWithdrawView: View {
    @StateObject private var viewModel = DepositWithdrawViewModel()

    // Colors matching the screenshot
    let pageBackgroundColor = Color(red: 25 / 255, green: 30 / 255, blue: 39 / 255)  // #191E27
    let cardBackgroundColor = Color(red: 40 / 255, green: 45 / 255, blue: 55 / 255)
    let primaryTextColor = Color.white
    let secondaryTextColor = Color.gray
    let accentColor = Color(hex: "3B82F6")  // Blue for button and highlights

    // Account details from the image (hardcoded as per image)
    let userEmail = "ZhangYan  sskeysys@hotmail.com"  // From image
    // --- MODIFICATION START ---
    // Original: let accountType = "ACH SAVINGS Powered by Standard chartered"    // From image
    let accountType = "ACH SAVINGS\nPowered by Standard Chartered"  // From image
    // --- MODIFICATION END ---
    let bankName = "China Merchants Bank (*2056)"  // From image
    let bankStatus = "Active"  // From image

    var body: some View {
        ZStack {
            pageBackgroundColor.ignoresSafeArea()

            VStack(spacing: 0) {
                accountInfoSection
                    .padding(.horizontal)
                    .padding(.top, 10)  // Adjusted top padding

                requestTransferButton
                    .padding(.horizontal)
                    .padding(.vertical, 20)  // Increased vertical padding

                transferHistorySection

                if let errorMsg = viewModel.databaseError {
                    Text(errorMsg)
                        .foregroundColor(.red)
                        .padding()
                }
            }
        }
        .navigationTitle("Deposit / Withdrawal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Deposit / Withdrawal")
                    .font(.headline)
                    .foregroundColor(primaryTextColor)
            }
        }
        .toolbarColorScheme(.dark, for: .navigationBar)  // Match MyView's toolbar style
        .onAppear {
            if viewModel.transactions.isEmpty && viewModel.canLoadMorePages {
                print("DepositWithdrawView appeared, initial data load if needed.")
                // ViewModel's init already calls fetch. This is a fallback.
                // viewModel.fetchTransactions(isRefresh: true)
            }
        }
    }

    private var accountInfoSection: some View {
        VStack(alignment: .leading, spacing: 10) {  // Increased spacing
            HStack(spacing: 12) {  // Increased spacing
                Image(systemName: "building.columns.fill")
                    .font(.system(size: 30))  // Slightly larger icon
                    .foregroundColor(accentColor)
                VStack(alignment: .leading, spacing: 2) {  // Reduced inner spacing
                    Text(userEmail)
                        .font(.system(size: 16, weight: .medium))  // Adjusted font
                        .foregroundColor(primaryTextColor)
                    Text(accountType)
                        .font(.system(size: 13))  // Adjusted font
                        .foregroundColor(secondaryTextColor)
                }
            }
            Text(bankName)
                .font(.system(size: 15, weight: .medium))  // Adjusted font
                .foregroundColor(primaryTextColor)
                .padding(.top, 4)  // Added small top padding

            HStack {
                Text("Profile Status: \(bankStatus)")
                    .font(.system(size: 13))  // Adjusted font
                    .foregroundColor(secondaryTextColor)
                Spacer()
                Button("Delete Profile") {
                    print("Delete bank setting tapped (not implemented)")
                }
                .font(.system(size: 13, weight: .medium))  // Adjusted font
                .foregroundColor(accentColor)
            }
        }
        .padding(16)  // Standard padding
        .background(cardBackgroundColor)
        .cornerRadius(12)  // Slightly larger corner radius
    }

    // 上記を下記に置き換えます：
    private var requestTransferButton: some View {
        NavigationLink(destination: RequestTransferView()) { // ◀️ ここを変更
            Text("Request Transfer")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(accentColor)
                .cornerRadius(8)
        }
    }

    private var transferHistorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transfer History")
                    .font(.system(size: 18, weight: .bold))  // Adjusted font
                    .foregroundColor(primaryTextColor)
                Spacer()
                Button(action: {
                    viewModel.refreshTransactions()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .medium))  // Adjusted icon size
                        .foregroundColor(accentColor)
                }
            }
            .padding(.horizontal)

            //            Text("点击转账记录查看详细信息")
            //                .font(.system(size: 12)) // Adjusted font
            //                .foregroundColor(secondaryTextColor)
            //                .padding(.horizontal)
            //                .padding(.bottom, 10) // Increased bottom padding

            List {
                if viewModel.transactions.isEmpty && !viewModel.isLoadingPage
                    && viewModel.databaseError == nil
                {
                    Text("No Transfer History")
                        .font(.system(size: 15))
                        .foregroundColor(secondaryTextColor)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                        .listRowBackground(pageBackgroundColor)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(viewModel.transactions) { record in
                        TransactionRowView(record: record)
                            .listRowBackground(pageBackgroundColor)
                            .listRowSeparator(.automatic, edges: .bottom)
                            .listRowSeparatorTint(secondaryTextColor.opacity(0.3))
                            .onAppear {
                                if record.id == viewModel.transactions.last?.id
                                    && viewModel.canLoadMorePages && !viewModel.isLoadingPage
                                {
                                    print(
                                        "📜 Reached last item (\(record.id) - \(record.date)), attempting to load more."
                                    )
                                    viewModel.fetchTransactions()
                                }
                            }
                    }
                }

                if viewModel.isLoadingPage {
                    HStack {
                        Spacer()
                        ProgressView().progressViewStyle(
                            CircularProgressViewStyle(tint: primaryTextColor))
                        Spacer()
                    }
                    .listRowBackground(pageBackgroundColor)
                    .listRowSeparator(.hidden)
                    .padding(.vertical, 10)
                }

                if !viewModel.canLoadMorePages && !viewModel.transactions.isEmpty
                    && !viewModel.isLoadingPage
                {
                    Text("No more records")
                        .font(.caption)
                        .foregroundColor(secondaryTextColor)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 10)
                        .listRowBackground(pageBackgroundColor)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(PlainListStyle())
            .background(pageBackgroundColor)
            .frame(maxHeight: .infinity)
        }
    }
}

struct TransactionRowView: View {
    let record: TransactionRecord
    let primaryTextColor = Color.white
    let secondaryTextColor = Color.gray
    let statusCompletedColor = Color.green  // Or use secondaryTextColor as per design
    let statusRejectedColor = Color.red  // For future if status is available

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {  // Added spacing
                Text(record.transactionTypeString)
                    .font(.system(size: 16, weight: .medium))  // Adjusted font
                    .foregroundColor(primaryTextColor)
                Text(record.date)  // Date format from DB: YYYY-MM-DD
                    .font(.system(size: 13))  // Adjusted font
                    .foregroundColor(secondaryTextColor)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {  // Added spacing
                Text(record.formattedValue)
                    .font(.system(size: 16, weight: .medium))  // Adjusted font
                    .foregroundColor(primaryTextColor)

                // Status display (currently always "已完成" from DB)
                // Design image shows "已完成" in gray, "已驳回" in a different color (likely red, though image is monochrome for status)
                Text(record.status)
                    .font(.system(size: 13))  // Adjusted font
                    .foregroundColor(
                        record.status == "Rejected"
                            ? statusRejectedColor
                            : (record.status == "Complete" ? secondaryTextColor : secondaryTextColor))
            }
        }
        .padding(.vertical, 10)  // Increased vertical padding for row
    }
}

// 取引タイプを定義
enum TransferType: String, CaseIterable, Identifiable {
    case deposit = "Deposit to My Account"
    case withdraw = "Withdraw from My Account"
    var id: String { self.rawValue }
}

class RequestTransferViewModel: ObservableObject {
    @Published var selectedTransferType: TransferType = .withdraw
    @Published var amountString: String = ""
    @Published var latestBalance: Double = 0.0
    @Published var databaseError: String? = nil
    @Published var isLoading: Bool = false
    @Published var isSubmitting: Bool = false

    private var db: OpaquePointer?
    private var dbPath: String // このパスを書き込み可能な場所のパスに変更します

    var isPreviewButtonEnabled: Bool {
        guard !isSubmitting,
              let amount = Double(amountString)
        else {
            return false
        }
        return amount >= 1.0
    }

    init() {
        // 1. 書き込み可能なデータベースパスを取得し、必要ならバンドルからコピー
        guard let writablePath = Self.setupWritableDbPath() else {
            let errorMsg = "❌ Critical Error: Could not set up writable database path."
            print(errorMsg)
            self.dbPath = "" // dbPathを空に設定して後続処理でのエラーを防ぐ
            self.databaseError = errorMsg
            // isLoading や isSubmitting はデフォルトのfalseのまま
            return
        }
        self.dbPath = writablePath
        print("✅ Using writable database path: \(self.dbPath)")

        // 2. データベースを開いて最新の残高を取得
        if openDatabase() {
            fetchLatestBalance()
        } else {
            // openDatabase内でdatabaseErrorが設定される
            print("❌ Failed to open database during init.")
        }
    }

    // --- 追加: 書き込み可能なDBパスを設定し、必要ならバンドルからコピーする ---
    private static func setupWritableDbPath() -> String? {
        let fileManager = FileManager.default
        guard let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("❌ Could not get documents directory.")
            return nil
        }

        let dbName = "Firstrade.db" // データベースファイル名
        let writableDbPath = documentsDirectory.appendingPathComponent(dbName).path

        // ドキュメントディレクトリにDBファイルが存在しない場合、バンドルからコピーする
        if !fileManager.fileExists(atPath: writableDbPath) {
            print("ℹ️ Database file not found in documents directory. Attempting to copy from bundle...")
            guard let bundleDbPath = Bundle.main.path(forResource: "Firstrade", ofType: "db") else {
                print("❌ Failed to find Firstrade.db in app bundle.")
                return nil
            }
            do {
                try fileManager.copyItem(atPath: bundleDbPath, toPath: writableDbPath)
                print("✅ Successfully copied database from bundle to: \(writableDbPath)")
            } catch {
                print("❌ Error copying database from bundle: \(error.localizedDescription)")
                return nil
            }
        } else {
            print("ℹ️ Database file already exists at: \(writableDbPath)")
        }
        return writableDbPath
    }
    // --- 追加ここまで ---

    deinit {
        if db != nil {
            sqlite3_close(db)
            db = nil
            print("🗃️ Database closed in RequestTransferViewModel.")
        }
    }

    private func openDatabase() -> Bool {
        // dbPathが空（初期化失敗など）の場合は開けない
        if dbPath.isEmpty {
            self.databaseError = "Database path is not configured."
            print("❌ \(self.databaseError!)")
            return false
        }

        // sqlite3_open_v2 を使用して読み書きモードで開くことを推奨
        // SQLITE_OPEN_READWRITE: 読み書きモードで開く
        // SQLITE_OPEN_CREATE: ファイルが存在しない場合に作成する (今回はコピーするので通常は既に存在する)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        if sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK {
            print("✅ Database opened successfully (read-write) at \(dbPath)")
            databaseError = nil
            return true
        } else {
            let errorMsg = "❌ Error opening database (read-write) at \(dbPath): \(String(cString: sqlite3_errmsg(db)))"
            print(errorMsg)
            databaseError = errorMsg
            if db != nil { // エラーがあってもdbポインタがnilでない場合があるため、閉じる試み
                sqlite3_close(db)
                db = nil
            }
            return false
        }
    }

    func fetchLatestBalance() {
        guard !dbPath.isEmpty else {
            self.databaseError = "Database path not set for fetching balance."
            print("❌ \(self.databaseError!)")
            self.isLoading = false
            return
        }
        
        guard openDatabase() else {
            // databaseError は openDatabase() 内で設定される
            self.isLoading = false
            return
        }
        
        self.isLoading = true
        // self.databaseError = nil // openDatabase成功時にクリアされる

        let query = "SELECT value FROM Balance ORDER BY date DESC LIMIT 1;"
        var statement: OpaquePointer?

        print("➡️ Preparing query for balance: \(query)")
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                let balanceValue = sqlite3_column_double(statement, 0)
                DispatchQueue.main.async {
                    self.latestBalance = balanceValue
                    print("✅ Latest balance fetched: \(balanceValue)")
                }
            } else {
                let errorMsg = "ℹ️ No balance data found in Balance table."
                print(errorMsg)
                DispatchQueue.main.async {
                    // self.databaseError = errorMsg // データがないことはDBエラーではない場合もある
                    self.latestBalance = 0.0
                }
            }
            sqlite3_finalize(statement)
        } else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            print("❌ SELECT statement for balance could not be prepared: \(errorMessage). Query: \(query)")
            DispatchQueue.main.async {
                self.databaseError = "Failed to fetch balance: \(errorMessage)"
            }
        }
        DispatchQueue.main.async {
            self.isLoading = false
        }
        // データベース接続を維持する場合、ここでは閉じない
    }

    func submitTransfer(completion: @escaping (Bool, String?) -> Void) {
        DispatchQueue.main.async {
            self.isSubmitting = true
            // self.databaseError = nil // openDatabaseでクリアされるか、ここで明示的に
        }

        guard let amount = Double(amountString) else {
            let errorMsg = "Invalid amount."
            print("❌ \(errorMsg)")
            DispatchQueue.main.async {
                self.isSubmitting = false
                completion(false, errorMsg)
            }
            return
        }

        guard !dbPath.isEmpty else {
            let errorMsg = "Database path not set for submitting transfer."
            print("❌ \(errorMsg)")
            DispatchQueue.main.async {
                self.isSubmitting = false
                self.databaseError = errorMsg // ViewModelのエラー状態も更新
                completion(false, errorMsg)
            }
            return
        }

        guard openDatabase() else {
            // databaseError は openDatabase() 内で設定される
            DispatchQueue.main.async {
                self.isSubmitting = false
                // completionにはViewModelのdatabaseErrorを渡す
                completion(false, self.databaseError ?? "Unknown error opening database for transfer.")
            }
            return
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let currentDateString = dateFormatter.string(from: Date())
        let transferTypeInt = 2
        let insertSQL = "INSERT INTO Deposit (date, value, type) VALUES (?, ?, ?);"
        var statement: OpaquePointer?

        print("➡️ Preparing insert: \(insertSQL) with date: \(currentDateString), value: \(amount), type: \(transferTypeInt)")

        if sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (currentDateString as NSString).utf8String, -1, nil)
            sqlite3_bind_double(statement, 2, amount)
            sqlite3_bind_int(statement, 3, Int32(transferTypeInt))

            if sqlite3_step(statement) == SQLITE_DONE {
                print("✅ Successfully inserted new record into Deposit table.")
                sqlite3_finalize(statement)
                DispatchQueue.main.async {
                    completion(true, nil)
                }
            } else {
                let errorMessage = String(cString: sqlite3_errmsg(db))
                print("❌ Failed to insert row: \(errorMessage)")
                sqlite3_finalize(statement)
                DispatchQueue.main.async {
                    self.isSubmitting = false
                    self.databaseError = "Failed to save record: \(errorMessage)"
                    completion(false, self.databaseError)
                }
            }
        } else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            print("❌ INSERT statement could not be prepared: \(errorMessage)")
            DispatchQueue.main.async {
                self.isSubmitting = false
                self.databaseError = "Database error during insert preparation: \(errorMessage)"
                completion(false, self.databaseError)
            }
        }
        // データベース接続を維持する場合、ここでは閉じない
    }
}

struct RequestTransferView: View {
    @StateObject private var viewModel = RequestTransferViewModel()
    @Environment(\.presentationMode) var presentationMode // 画面を閉じるために追加

    // --- 追加 ---
    @State private var showAlert = false
    @State private var alertMessage = ""


    // デザインに基づいた色定義 (既存のまま)
    private let pageBackgroundColor = Color(red: 25 / 255, green: 30 / 255, blue: 39 / 255)
    private let cardBackgroundColor = Color(red: 40 / 255, green: 45 / 255, blue: 55 / 255)
    private let primaryTextColor = Color.white
    private let secondaryTextColor = Color.gray
    private let accentColor = Color(hex: "3B82F6")

    var body: some View {
        ZStack {
            pageBackgroundColor.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 20) {
                if viewModel.isLoading && !viewModel.isSubmitting { // 送金処理中は別の表示
                    ProgressView("Loading Cash Amount...")
                        .progressViewStyle(CircularProgressViewStyle(tint: primaryTextColor))
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if let dbError = viewModel.databaseError, !viewModel.isSubmitting { // 送金処理エラーは別途アラートで
                    Text(dbError)
                        .foregroundColor(.red)
                        .padding()
                }

                // MARK: - Transfer Type Selection
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(TransferType.allCases) { type in
                        Button(action: {
                            if !viewModel.isSubmitting { // 処理中でなければ変更可能
                                viewModel.selectedTransferType = type
                            }
                        }) {
                            HStack {
                                Image(
                                    systemName: viewModel.selectedTransferType == type ? "largecircle.fill.circle" : "circle"
                                )
                                .foregroundColor(accentColor)
                                Text(type.rawValue)
                                    .foregroundColor(primaryTextColor)
                                Spacer()
                            }
                            .padding()
                            .background(cardBackgroundColor)
                            .cornerRadius(8)
                        }
                    }
                }
                .padding(.horizontal)
                .disabled(viewModel.isSubmitting) // 処理中は無効化

                // MARK: - Cash Amount Display
                VStack(alignment: .leading, spacing: 5) {
                    Text("Cash Amount")
                        .font(.subheadline)
                        .foregroundColor(secondaryTextColor)
                    Text(String(format: "$%.2f", viewModel.latestBalance))
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(primaryTextColor)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardBackgroundColor)
                .cornerRadius(8)
                .padding(.horizontal)

                // MARK: - Amount Input
                VStack(alignment: .leading, spacing: 5) {
                    Text("Amount")
                        .font(.subheadline)
                        .foregroundColor(secondaryTextColor)
                    TextField("Enter amount", text: $viewModel.amountString)
                        .foregroundColor(primaryTextColor)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(red: 30 / 255, green: 35 / 255, blue: 45 / 255))
                        )
                        .keyboardType(.decimalPad)
                        .disabled(viewModel.isSubmitting) // 処理中は無効化
                    Text("Minimum amount is $1.00")
                        .font(.caption)
                        .foregroundColor(secondaryTextColor)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardBackgroundColor)
                .cornerRadius(8)
                .padding(.horizontal)

                Spacer()

                // MARK: - Submit Button
                Button(action: {
                    // キーボードを閉じる
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    
                    viewModel.submitTransfer { success, errorMsg in
                        if success {
                            // 成功時: 1.5秒待って画面を閉じる
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                viewModel.isSubmitting = false // 状態をリセット
                                presentationMode.wrappedValue.dismiss()
                            }
                        } else {
                            // 失敗時: エラーメッセージを表示
                            viewModel.isSubmitting = false // 状態をリセット
                            alertMessage = errorMsg ?? "An unknown error occurred."
                            showAlert = true
                        }
                    }
                }) {
                    Text(viewModel.isSubmitting ? "Transfering..." : "Submit") // テキストを動的に変更
                        .font(.headline)
                        .foregroundColor(viewModel.isPreviewButtonEnabled ? .white : .gray)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            accentColor.opacity(viewModel.isPreviewButtonEnabled ? 1.0 : 0.5)
                        )
                        .cornerRadius(8)
                }
                .disabled(!viewModel.isPreviewButtonEnabled || viewModel.isSubmitting) // ボタンの有効/無効状態
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
        .navigationTitle("Request Transfer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Request Transfer")
                    .font(.headline)
                    .foregroundColor(primaryTextColor)
            }
        }
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
             // viewModel.fetchLatestBalance() // initで呼ばれるので通常は不要
        }
        .alert(isPresented: $showAlert) {
            Alert(title: Text("Transfer Failed"), message: Text(alertMessage), dismissButton: .default(Text("OK")))
        }
    }
}
