import SwiftUI
import SQLite3 // SQLiteを使用するためにインポート

// 取引タイプを定義
enum TransferType: String, CaseIterable, Identifiable {
    case deposit = "Deposit to My Account"
    case withdraw = "Withdraw from My Account"
    var id: String { self.rawValue }
}

class RequestTransferViewModel: ObservableObject {
    @Published var selectedTransferType: TransferType = .withdraw // デフォルトは "Withdraw"
    @Published var amountString: String = ""
    @Published var latestBalance: Double = 0.0
    @Published var databaseError: String? = nil
    @Published var isLoading: Bool = false

    private var db: OpaquePointer?
    private let dbPath: String

    // Previewボタンが有効かどうかを判定するコンピューテッドプロパティ
    var isPreviewButtonEnabled: Bool {
        guard let amount = Double(amountString) else { return false }
        return amount >= 1.0
    }

    init() {
        // データベースファイルのパスを取得
        guard let path = Bundle.main.path(forResource: "Firstrade", ofType: "db") else {
            let errorMsg = "❌ Failed to find Firstrade.db in bundle."
            print(errorMsg)
            self.dbPath = ""
            self.databaseError = errorMsg
            return
        }
        self.dbPath = path
        print("Database path for RequestTransferViewModel: \(dbPath)")

        // データベースを開いて最新の残高を取得
        if openDatabase() {
            fetchLatestBalance()
            // このViewModelの生存期間中DBを開いたままにするか、都度閉じるかはアプリの要件による
            // ここではfetch後に閉じる例は示さず、deinitで閉じる
        }
    }

    deinit {
        if db != nil {
            sqlite3_close(db)
            db = nil
            print("🗃️ Database closed in RequestTransferViewModel.")
        }
    }

    private func openDatabase() -> Bool {
        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            print("✅ Database opened successfully for RequestTransferViewModel at \(dbPath)")
            databaseError = nil
            return true
        } else {
            let errorMsg = "❌ Error opening database \(dbPath): \(String(cString: sqlite3_errmsg(db)))"
            print(errorMsg)
            databaseError = errorMsg
            if db != nil {
                sqlite3_close(db) // エラー時は閉じる
                db = nil
            }
            return false
        }
    }

    func fetchLatestBalance() {
        guard db != nil else {
            databaseError = "Database not open. Cannot fetch balance."
            print(databaseError!)
            return
        }
        isLoading = true
        databaseError = nil

        // Balanceテーブルから最新のvalueを取得するクエリ
        let query = "SELECT value FROM Balance ORDER BY date DESC LIMIT 1;"
        var statement: OpaquePointer?

        print("➡️ Preparing query: \(query)")
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
                    self.databaseError = errorMsg
                    self.latestBalance = 0.0 // データがない場合は0に
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
    }
}

struct RequestTransferView: View {
    @StateObject private var viewModel = RequestTransferViewModel()

    // デザインに基づいた色定義
    private let pageBackgroundColor = Color(red: 25 / 255, green: 30 / 255, blue: 39 / 255)
    private let cardBackgroundColor = Color(red: 40 / 255, green: 45 / 255, blue: 55 / 255)
    private let primaryTextColor = Color.white
    private let secondaryTextColor = Color.gray
    private let accentColor = Color(hex: "3B82F6") // FirstradeApp.swiftのColor extensionが必要

    var body: some View {
        ZStack {
            pageBackgroundColor.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                if viewModel.isLoading {
                    ProgressView("Loading Cash Amount...")
                        .progressViewStyle(CircularProgressViewStyle(tint: primaryTextColor))
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if let dbError = viewModel.databaseError {
                    Text(dbError)
                        .foregroundColor(.red)
                        .padding()
                }

                // MARK: - Transfer Type Selection
//                Text("Please select transfer type")
//                    .font(.headline)
//                    .foregroundColor(primaryTextColor)
//                    .padding(.horizontal)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(TransferType.allCases) { type in
                        Button(action: {
                            viewModel.selectedTransferType = type
                        }) {
                            HStack {
                                Image(systemName: viewModel.selectedTransferType == type ? "largecircle.fill.circle" : "circle")
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
                                .fill(Color(red: 30/255, green: 35/255, blue: 45/255)) // Slightly different for input field
                        )
                        .keyboardType(.decimalPad)
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

                // MARK: - Preview Button
                Button(action: {
                    // Preview button action (to be implemented later)
                    print("Preview tapped. Amount: \(viewModel.amountString), Type: \(viewModel.selectedTransferType.rawValue)")
                }) {
                    Text("Preview")
                        .font(.headline)
                        .foregroundColor(viewModel.isPreviewButtonEnabled ? .white : .gray)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(accentColor.opacity(viewModel.isPreviewButtonEnabled ? 1.0 : 0.5))
                        .cornerRadius(8)
                }
                .disabled(!viewModel.isPreviewButtonEnabled)
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
            // ViewModelのinitでデータ取得が開始されるが、必要に応じて再取得
            // viewModel.fetchLatestBalance()
        }
    }
}

struct RequestTransferView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            RequestTransferView()
        }
        .preferredColorScheme(.dark)
    }
}
