import SwiftUI

// MARK: - WatchlistView

struct WatchlistView: View {
    // MARK: - Color Palette
    // These colors are chosen to match the design image.
    let pageBackgroundColor = Color(hex: "101419")         // Very dark background for the main content area
    let headerRowBackgroundColor = Color(red: 25/255, green: 30/255, blue: 39/255) // Background for the "SYMBOL" row, matches tab bar
    let primaryTextColor = Color.white                     // For main text elements like titles and important messages
    let secondaryTextColor = Color.gray                    // For less prominent text or icons
    let symbolHeaderTextColor = Color.white.opacity(0.85)  // Slightly dimmed white for "SYMBOL ▲"
    let navigationBarItemColor = Color.white               // Color for icons and text in the navigation bar

    // MARK: - State Variables
    @State private var showingWatchlistSelectionSheet = false
    @State private var showingSymbolSearchSheet = false
    // In a real app, you'd have @State or @ObservedObject for the actual watchlist symbols
    // @State private var symbols: [String] = [] // Example

    var body: some View {
        NavigationView {
            ZStack {
                pageBackgroundColor.ignoresSafeArea() // Extend the darkest background to screen edges

                VStack(spacing: 0) { // Use spacing 0 to have direct contact between header and content
                    // Header Row for "SYMBOL"
                    SymbolHeaderView(
                        textColor: symbolHeaderTextColor,
                        backgroundColor: headerRowBackgroundColor
                    )

                    // Content Area
                    // If symbols list were populated, you'd switch between this and the list view
                    // For now, it always shows the empty state.
                    Spacer() // Pushes the empty content view towards the center vertically

                    EmptyStateContentView(
                        messageTextColor: primaryTextColor,
                        buttonTextColor: primaryTextColor,
                        buttonBorderColor: secondaryTextColor,
                        searchAction: {
                            showingSymbolSearchSheet = true
                            print("Search for a symbol button tapped.")
                        }
                    )

                    Spacer() // Balances the empty content view in the center
                }
            }
            .navigationBarTitleDisplayMode(.inline) // Ensures title is centered if space allows
            .toolbar {
                // Leading Navigation Bar Item: Star Icon
                ToolbarItem(placement: .navigationBarLeading) {
                    Image(systemName: "star.fill")
                        .foregroundColor(navigationBarItemColor)
                        .font(.title3) // Slightly larger and more prominent star
                }

                // Principal Navigation Bar Item: Title "Favorites" + Hamburger Menu
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Text("Favorites")
                            .font(.headline)
                            .foregroundColor(primaryTextColor)
                        Button(action: {
                            showingWatchlistSelectionSheet = true
                            print("Favorites menu tapped.")
                        }) {
                            Image(systemName: "line.3.horizontal")
                                .foregroundColor(navigationBarItemColor)
                        }
                    }
                }

                // Trailing Navigation Bar Items: Bell and Search Icons
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(action: {
                        print("Bell icon tapped.")
                        // Action for bell notification
                    }) {
                        Image(systemName: "bell")
                            .foregroundColor(navigationBarItemColor)
                    }
                    Button(action: {
                        print("Navigation bar search icon tapped.")
                        // Action for navigation bar search icon
                        // This might be different from the empty state search
                    }) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(navigationBarItemColor)
                    }
                }
            }
            // Sheets for modal presentation
            .sheet(isPresented: $showingWatchlistSelectionSheet) {
                // Placeholder for Watchlist Selection View
                Text("Watchlist Selection Sheet (Placeholder)")
                    .padding()
            }
            .sheet(isPresented: $showingSymbolSearchSheet) {
                // Placeholder for Symbol Search View
                Text("Symbol Search Sheet (Placeholder)")
                    .padding()
            }
        }
        .navigationViewStyle(StackNavigationViewStyle()) // Consistent with other views
    }
}

// MARK: - Subviews for WatchlistView

struct SymbolHeaderView: View {
    let textColor: Color
    let backgroundColor: Color

    var body: some View {
        HStack {
            Text("SYMBOL")
                .font(.caption.weight(.semibold)) // Slightly bolder caption
            Image(systemName: "arrow.up")
                .font(.caption.weight(.semibold))
            Spacer()
        }
        .foregroundColor(textColor)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(backgroundColor)
    }
}

struct EmptyStateContentView: View {
    let messageTextColor: Color
    let buttonTextColor: Color
    let buttonBorderColor: Color
    let searchAction: () -> Void

    var body: some View {
        VStack(spacing: 25) { // Increased spacing for better visual separation
            Text("There are no symbols in this watchlist")
                .font(.system(size: 17, weight: .medium)) // Adjusted font size and weight
                .foregroundColor(messageTextColor)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20) // Ensure text doesn't touch edges on smaller screens

            Button(action: searchAction) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text("Search for a symbol")
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(buttonTextColor)
                .padding(.horizontal, 25) // More horizontal padding for the button
                .padding(.vertical, 12)   // More vertical padding for the button
                .overlay(
                    RoundedRectangle(cornerRadius: 8) // Standard corner radius
                        .stroke(buttonBorderColor, lineWidth: 1)
                )
            }
        }
        .padding(.horizontal, 30) // Overall padding for the empty state content
    }
}

// MARK: - Preview

struct WatchlistView_Previews: PreviewProvider {
    static var previews: some View {
        WatchlistView()
            .environmentObject(SessionStore()) // Include if SessionStore is used by Navigation or subviews
            .preferredColorScheme(.dark) // Ensure preview matches the dark theme
    }
}
