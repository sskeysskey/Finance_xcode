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

// Preview Provider for DepositWithdrawView (optional, but helpful)
struct DepositWithdrawView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {  // Wrap in NavigationView for previewing navigation bar
            DepositWithdrawView()
        }
        .preferredColorScheme(.dark)  // Preview in dark mode
    }
}
