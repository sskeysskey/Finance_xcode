import SwiftUI

struct DateFilterView: View {
    @Binding var startDate: Date
    @Binding var endDate: Date
    var onApply: (Date, Date) -> Void
    @Environment(\.presentationMode) var presentationMode

    // 色定義
    private let pageBackgroundColor = Color(red: 25/255, green: 30/255, blue: 39/255)
    private let textColor = Color.white
    private let accentButtonColor = Color(hex: "3B82F6") // Firstradeの標準的なアクセントカラー

    @State private var tempStartDate: Date
    @State private var tempEndDate: Date
    @State private var dateError: String? = nil

    init(startDate: Binding<Date>, endDate: Binding<Date>, onApply: @escaping (Date, Date) -> Void) {
        _startDate = startDate
        _endDate = endDate
        self.onApply = onApply
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
                        .colorScheme(.dark) // DatePickerのUIをダークテーマに
                        .accentColor(accentButtonColor) // カレンダー内の選択色
                        .padding(.horizontal)

                    DatePicker("截止日期", selection: $tempEndDate, in: tempStartDate..., displayedComponents: .date)
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
            .toolbarColorScheme(.dark, for: .navigationBar) // ナビゲーションバーのアイテムを明るく
        }
        .navigationViewStyle(StackNavigationViewStyle()) // モーダル表示に適したスタイル
    }
}
