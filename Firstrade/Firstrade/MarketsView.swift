import SwiftUI

// MARK: - Data Models for MarketsView

struct MarketIndex: Identifiable {
    let id = UUID()
    let name: String
    let value: String
    let change: String
    let changePercent: String
    let isNegative: Bool
}

struct BuzzItem: Identifiable {
    let id = UUID()
    let ticker: String
    let color: Color
    let size: CGFloat
    var isLarge: Bool = false
}

// MARK: - Main MarketsView

struct MarketsView: View {
    @State private var searchText: String = ""
    @State private var selectedMarketTab: MarketPageTab = .overview

    // Sample Data - Replace with actual data fetching logic
    let indices: [MarketIndex] = [
        MarketIndex(name: "DOW", value: "41,603.07", change: "-256.02", changePercent: "(-0.61%)", isNegative: true),
        MarketIndex(name: "S&P 500", value: "5,802.82", change: "-39.19", changePercent: "(-0.67%)", isNegative: true),
        MarketIndex(name: "NASDAQ", value: "18,737.21", change: "-188.52", changePercent: "(-1.00%)", isNegative: true)
    ]

    // Approximate sizes and colors from the image
    let buzzItems: [BuzzItem] = [
        BuzzItem(ticker: "MORN", color: .red, size: 130, isLarge: true),
        BuzzItem(ticker: "PYPL", color: Color(hex: "3B82F6"), size: 80), // Blue color
        BuzzItem(ticker: "GLXY", color: .green, size: 75),
        BuzzItem(ticker: "NOW", color: .red, size: 60),
        BuzzItem(ticker: "BURL", color: .green, size: 60)
    ]

    enum MarketPageTab: String, CaseIterable {
        case overview = "Overview"
        case technicalInsight = "Technical Insight"
        case themes = "Themes"
    }

    // Consistent color palette
    let appBackgroundColor = Color(red: 25/255, green: 30/255, blue: 39/255)
    let textColor = Color.white

    var body: some View {
        NavigationView {
            ZStack {
                appBackgroundColor.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        MarketTabsView(selectedTab: $selectedMarketTab)
                            .padding(.top, 10) // Add some padding from the top edge of ScrollView

                        MarketStatusInfoView()

                        IndexCardsDisplayView(indices: indices)

                        MarketBuzzDisplayView(buzzItems: buzzItems)

                        TechnicalInsightLink()

                        MostPopularSectionView()
                        
                        Spacer() // Ensures content is pushed up if ScrollView is not full
                    }
                    .padding(.horizontal) // Horizontal padding for the entire content stack
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    MarketSearchBar(searchText: $searchText)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    UserProfileIcon()
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar) // Consistent with AssetsView
        }
        .navigationViewStyle(StackNavigationViewStyle()) // Consistent with other main views
    }
}

// MARK: - Subviews for MarketsView

struct MarketSearchBar: View {
    @Binding var searchText: String
    private let searchBarBackgroundColor = Color(red: 40/255, green: 45/255, blue: 55/255)

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.gray)
            TextField("Search", text: $searchText)
                .foregroundColor(.white)
                .accentColor(.gray) // Cursor color
                .preferredColorScheme(.dark) // Ensures keyboard appearance is dark
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .background(searchBarBackgroundColor)
        .cornerRadius(10)
        .frame(height: 36)
    }
}

struct UserProfileIcon: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [Color(hex: "FDB813"), Color(hex: "F7971E"), Color(hex: "E23D7E"), Color(hex: "9B59B6")]), // Yellow, Orange, Pink, Purple
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 30, height: 30)
            // Example: Add initials if needed
            // Text("YZ").font(.system(size: 12, weight: .bold)).foregroundColor(.white)
        }
    }
}

struct MarketTabsView: View {
    @Binding var selectedTab: MarketsView.MarketPageTab
    
    private let activeTabBorderColor = Color(hex: "3B82F6") // Blue from LoginView buttons
    private let activeTabTextColor = Color(hex: "3B82F6")
    private let inactiveTabBackgroundColor = Color(red: 40/255, green: 45/255, blue: 55/255)
    private let inactiveTabTextColor = Color.gray

    var body: some View {
        HStack(spacing: 10) {
            ForEach(MarketsView.MarketPageTab.allCases, id: \.self) { tab in
                Button(action: {
                    selectedTab = tab
                }) {
                    Text(tab.rawValue)
                        .font(.system(size: 14, weight: .medium))
                        .padding(.vertical, 10)
                        .padding(.horizontal, 18)
                        .background(inactiveTabBackgroundColor)
                        .foregroundColor(selectedTab == tab ? activeTabTextColor : inactiveTabTextColor)
                        .cornerRadius(20) // More rounded pill shape
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(selectedTab == tab ? activeTabBorderColor : Color.clear, lineWidth: 1.5)
                        )
                }
            }
        }
        .frame(maxWidth: .infinity) // Allow HStack to center its content if not filling width
    }
}

struct MarketStatusInfoView: View {
    private let primaryTextColor = Color.white
    private let secondaryTextColor = Color.gray.opacity(0.8)

    var body: some View {
        HStack {
            Text("Market is Closed")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(primaryTextColor)
            Spacer()
            Text("11:21:09 to open")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(secondaryTextColor)
        }
        .padding(.vertical, 5)
    }
}

struct IndexCardsDisplayView: View {
    let indices: [MarketIndex]
    private let cardBackgroundColor = Color(red: 40/255, green: 45/255, blue: 55/255)
    private let primaryTextColor = Color.white
    private let negativeColor = Color.red
    private let positiveColor = Color.green // Assuming positive changes are green

    var body: some View {
        HStack(spacing: 12) {
            ForEach(indices) { index in
                VStack(alignment: .leading, spacing: 5) {
                    Text(index.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(primaryTextColor)
                    Text(index.value)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(primaryTextColor)
                        .minimumScaleFactor(0.8) // Allow text to shrink if needed
                    HStack(spacing: 4) {
                        Text(index.change)
                        Text(index.changePercent)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(index.isNegative ? negativeColor : positiveColor)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardBackgroundColor)
                .cornerRadius(10)
            }
        }
    }
}

struct MarketBuzzDisplayView: View {
    let buzzItems: [BuzzItem]
    private let titleColor = Color.white
    private let subtitleColor = Color.gray.opacity(0.8)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Market Buzz")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(titleColor)

            SentimentIndicatorBar()
                .padding(.bottom, 10)

            // Relative positioning of buzz items. This is an approximation.
            // For pixel-perfect layout, GeometryReader or more complex calculations might be needed.
            ZStack {
                // MORN (Largest, slightly right and down from ZStack center)
                BuzzItemCircle(item: buzzItems.first(where: {$0.ticker == "MORN"})!)
                    .offset(x: 55, y: 5)

                // PYPL (Above left of MORN)
                BuzzItemCircle(item: buzzItems.first(where: {$0.ticker == "PYPL"})!)
                    .offset(x: -35, y: -50)

                // NOW (Left of PYPL)
                BuzzItemCircle(item: buzzItems.first(where: {$0.ticker == "NOW"})!)
                    .offset(x: -100, y: 0)
                
                // GLXY (Below PYPL, left of MORN)
                BuzzItemCircle(item: buzzItems.first(where: {$0.ticker == "GLXY"})!)
                    .offset(x: -50, y: 55)
                
                // BURL (Below MORN, slightly right)
                BuzzItemCircle(item: buzzItems.first(where: {$0.ticker == "BURL"})!)
                    .offset(x: 35, y: 85)
            }
            .frame(height: 200) // Allocate space for the buzz circles
            .frame(maxWidth: .infinity) // Ensure ZStack takes full width for centering offsets
        }
    }
}

struct SentimentIndicatorBar: View {
    private let textColor = Color.gray.opacity(0.8)
    // Colors for the sentiment bar segments based on the image
    private let sentimentColors: [Color] = [
        .red, .red.opacity(0.6), Color(hex: "3B82F6").opacity(0.7), .green.opacity(0.6), .green
    ]
    // The image shows the bar with 5 segments. The "indicator" is implied by these colors.

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Negative to positive")
                .font(.system(size: 12))
                .foregroundColor(textColor)
            
            HStack(spacing: 0) {
                ForEach(0..<sentimentColors.count, id: \.self) { index in
                    sentimentColors[index]
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())
        }
    }
}

struct BuzzItemCircle: View {
    let item: BuzzItem
    private let textColor = Color.white

    var body: some View {
        ZStack {
            Circle()
                .stroke(item.color, lineWidth: item.isLarge ? 2.5 : 2)
                .frame(width: item.size, height: item.size)
            Text(item.ticker)
                .font(item.isLarge ? .system(size: 28, weight: .medium) : .system(size: 16, weight: .medium))
                .foregroundColor(textColor)
        }
    }
}

struct TechnicalInsightLink: View {
    private let textColor = Color.white
    private let chevronColor = Color.gray

    var body: some View {
        NavigationLink(destination: Text("Technical Insight Page (Placeholder)")) { // Placeholder destination
            HStack {
                Text("Technical Insight")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(textColor)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(chevronColor)
            }
        }
        .padding(.vertical, 12)
    }
}

struct MostPopularSectionView: View {
    private let textColor = Color.white
    private let iconColor = Color.gray

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Most Popular")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(textColor)
                Image(systemName: "info.circle.fill") // Filled info icon
                    .foregroundColor(iconColor)
                Spacer()
            }
            // Placeholder for content - this part is not fully visible in the screenshot
            Text("Popular items will be listed here.")
                .font(.system(size: 14))
                .foregroundColor(.gray)
                .padding(.top, 4)
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Preview

struct MarketsView_Previews: PreviewProvider {
    static var previews: some View {
        // To make Color(hex:) work in previews if it's in a different file not compiled with previews:
        // You might need to ensure the App target (where FirstradeApp.swift is) is built.
        // Or, temporarily copy the Color(hex:) extension into this file for previewing.
        MarketsView()
            .environmentObject(SessionStore()) // If SessionStore is needed by sub-dependencies or navigation
            .preferredColorScheme(.dark) // Critical for matching the design
    }
}
