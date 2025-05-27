import SwiftUI

// MARK: - Common Colors (can be centralized if used across many files)
private let pageBackgroundColorGlobal = Color(red: 25 / 255, green: 30 / 255, blue: 39 / 255)  // #191E27
private let primaryTextColorGlobal = Color.white
private let secondaryTextColorGlobal = Color(white: 0.65)  // For dimmer text like account numbers in headers
private let descriptiveTextColorGlobal = Color(white: 0.75)  // For body/description text
private let separatorColorGlobal = Color(white: 0.35)
private let accentBlueColorGlobal = Color(hex: "3B82F6")  // Standard blue for buttons

// MARK: - Account Profile View and its components

struct AccountProfileView: View {
    let accountNumber: String = "90185542"  // Sample data

    var body: some View {
        ZStack {
            pageBackgroundColorGlobal.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Account Number Display - Using the new reusable header
                AccountHeaderView(
                    accountNumber: accountNumber,
                    textColor: secondaryTextColorGlobal,  // Dimmer text for header
                    iconName: "line.horizontal.3"
                )
                .padding(.leading, 16)  // Original padding for this specific layout
                .padding(.top, 20)
                .padding(.bottom, 25)

                // Trading Privileges Row - MODIFIED
                NavigationLink(
                    destination: TradingPrivilegesView(accountNumber: self.accountNumber)
                ) {
                    AccountDetailRow(
                        title: "Trading Privileges",
                        details: "Margin, Options, Extended Hour Trading"
                    )
                }
                CustomDividerView(color: separatorColorGlobal, leadingPadding: 16)

                // Required Documents Row
                NavigationLink(destination: Text("Required Documents Details View (Placeholder)")) {
                    AccountDetailRow(
                        title: "Required Documents",
                        details: "W-8BEN"
                    )
                }
                CustomDividerView(color: separatorColorGlobal, leadingPadding: 16)

                Spacer()
            }
        }
        .navigationTitle("Account Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Account Profile")
                    .font(.headline)
                    .foregroundColor(primaryTextColorGlobal)
            }
        }
    }
}

// Reusable struct for rows in AccountProfileView
struct AccountDetailRow: View {
    let title: String
    let details: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 17))
                    .foregroundColor(primaryTextColorGlobal)
                Text(details)
                    .font(.system(size: 14))
                    .foregroundColor(secondaryTextColorGlobal)  // Dimmer subtitle
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(white: 0.55))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(pageBackgroundColorGlobal)
    }
}

// MARK: - Trading Privileges View and its components

// Reusable Account Header
struct AccountHeaderView: View {
    let accountNumber: String
    let textColor: Color
    let iconName: String  // e.g., "line.horizontal.3"

    var body: some View {
        HStack(spacing: 8) {
            Text(accountNumber)
                .font(.system(size: 15))
                .foregroundColor(textColor)
            Image(systemName: iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(textColor)
        }
    }
}

// Custom Divider View
struct CustomDividerView: View {
    let color: Color
    let height: CGFloat = 0.5
    let leadingPadding: CGFloat

    var body: some View {
        Rectangle()
            .frame(height: height)
            .foregroundColor(color)
            .padding(.leading, leadingPadding)
    }
}

struct TradingPrivilegesView: View {
    let accountNumber: String

    // Colors specific to or customized for TradingPrivilegesView
    private let checkmarkColor = Color(red: 64 / 255, green: 192 / 255, blue: 160 / 255)  // Tealish green
    private let enrolledBadgeBackgroundColor = Color(
        red: 70 / 255, green: 115 / 255, blue: 95 / 255)  // Muted dark green
    private let enrolledBadgeTextColor = Color.white

    var body: some View {
        ZStack {
            pageBackgroundColorGlobal.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {  // Overall container for content
                    // THIS SECTION HAS BEEN REMOVED:
                    // // Account Number Header
                    // AccountHeaderView(
                    //     accountNumber: accountNumber,
                    //     textColor: secondaryTextColorGlobal, // Dimmer text for header
                    //     iconName: "line.horizontal.3"
                    // )
                    // .padding(.top, 5)
                    // .padding(.bottom, 20)

                    // Margin Trading Section
                    TradingSectionView(
                        title: "Margin Trading",
                        description: "This account is not yet approved for margin.",
                        buttonText: "Upgrade",
                        buttonAction: {
//                            print("Margin Upgrade Tapped for account: \(accountNumber)")  // accountNumber might still be useful for actions
                            // Add navigation or action logic here
                        },
                        items: [],
                        statusBadgeText: nil,
                        colors: sectionColors
                    )
                    CustomDividerView(color: separatorColorGlobal, leadingPadding: 0)  // Full width divider

                    // Options Trading Section
                    TradingSectionView(
                        title: "Options Trading",
                        description: "Your account is already approved for level 2 option trading.",
                        buttonText: "Upgrade",
                        buttonAction: {
                            print("Options Upgrade Tapped")
                            // Add navigation or action logic here
                        },
                        items: [
                            "Write Covered Calls",
                            "Write Cash-Secured Equity Puts",
                            "Purchase Calls and Puts",
                        ],
                        statusBadgeText: nil,
                        colors: sectionColors
                    )
                    CustomDividerView(color: separatorColorGlobal, leadingPadding: 0)  // Full width divider

                    // Extended Hour Trading Section
                    TradingSectionView(
                        title: "Extended Hour Trading",
                        description: "This account is approved for Extended Hour Trading",
                        buttonText: nil,  // No button
                        buttonAction: {},
                        items: [],
                        statusBadgeText: "Enrolled",
                        colors: sectionColors
                    )
                    // No divider after the last section

                    Spacer()  // Ensures content pushes up if ScrollView is not full
                }
                .padding(.horizontal, 16)  // Horizontal padding for all content inside ScrollView
            }
        }
        .navigationTitle("Account Profile")  // Title remains "Account Profile" as per screenshot
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Account Profile")
                    .font(.headline)
                    .foregroundColor(primaryTextColorGlobal)
            }
            // Back button will be automatically handled by NavigationView
        }
    }

    private var sectionColors: TradingSectionView.Colors {
        TradingSectionView.Colors(
            primaryText: primaryTextColorGlobal,
            descriptionText: descriptiveTextColorGlobal,  // Specific color for descriptions
            sectionTitle: primaryTextColorGlobal,  // Section titles are primary white
            buttonBackground: accentBlueColorGlobal,
            buttonText: primaryTextColorGlobal,  // White text on blue button
            checkmark: checkmarkColor,
            badgeBackground: enrolledBadgeBackgroundColor,
            badgeText: enrolledBadgeTextColor
        )
    }
}

struct TradingSectionView: View {
    struct Colors {
        let primaryText: Color
        let descriptionText: Color
        let sectionTitle: Color
        let buttonBackground: Color
        let buttonText: Color
        let checkmark: Color
        let badgeBackground: Color
        let badgeText: Color
    }

    let title: String
    let description: String
    let buttonText: String?
    let buttonAction: () -> Void
    let items: [String]
    let statusBadgeText: String?
    let colors: Colors

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(colors.sectionTitle)
                Spacer()
                if let badgeText = statusBadgeText {
                    Text(badgeText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(colors.badgeText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)  // Adjusted padding for badge
                        .background(colors.badgeBackground)
                        .clipShape(Capsule())
                }
            }
            .padding(.top, 20)

            Text(description)
                .font(.system(size: 15))
                .foregroundColor(colors.descriptionText)  // Use specific description color
                .lineSpacing(4)

            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 10) {  // Increased spacing for checklist items
                    ForEach(items, id: \.self) { item in
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark")
                                .foregroundColor(colors.checkmark)
                                .font(.system(size: 14, weight: .semibold))
                            Text(item)
                                .font(.system(size: 15))
                                .foregroundColor(colors.descriptionText)  // Checklist items also use description color
                        }
                    }
                }
                .padding(.top, 8)  // Space before checklist
            }

            if let btnText = buttonText {
                Button(action: buttonAction) {
                    Text(btnText)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(colors.buttonText)
                        .frame(height: 48)
                        .frame(maxWidth: .infinity)
                        .background(colors.buttonBackground)
                        .cornerRadius(8)
                }
                .padding(.top, 16)
            }
        }
        .padding(.bottom, 20)  // Space after section content before a potential divider
    }
}
