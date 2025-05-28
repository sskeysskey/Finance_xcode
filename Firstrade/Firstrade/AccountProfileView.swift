import SwiftUI

// MARK: - Common Colors (can be centralized if used across many files)
private let pageBackgroundColorGlobal = Color(red: 25 / 255, green: 30 / 255, blue: 39 / 255) // #191E27
private let primaryTextColorGlobal = Color.white
private let secondaryTextColorGlobal = Color(white: 0.65) // For dimmer text like account numbers in headers
private let descriptiveTextColorGlobal = Color(white: 0.75) // For body/description text
private let separatorColorGlobal = Color(white: 0.35)
private let accentBlueColorGlobal = Color(hex: "3B82F6") // Standard blue for buttons
fileprivate let certifiedBadgeBackgroundColor = Color(red: 70/255, green: 115/255, blue: 95/255) // Muted dark green (same as "Enrolled")
fileprivate let certifiedBadgeTextColor = Color.white
fileprivate let infoBoxBackgroundColor = Color(red: 40/255, green: 48/255, blue: 60/255) // Darker blue-gray for info box

// MARK: - Account Profile View and its components
struct AccountProfileView: View {
    let accountNumber: String = "90185542" // Sample data
    let phoneNumber: String = "139****705" // Sample data
    let email: String = "sskey***@hotmail.com" // Sample data

    var body: some View {
        ZStack {
            pageBackgroundColorGlobal.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                // Account Number Display - Using the new reusable header
                AccountHeaderView(
                    accountNumber: accountNumber,
                    textColor: secondaryTextColorGlobal, // Dimmer text for header
                    iconName: "line.horizontal.3"
                )
                .padding(.leading, 16) // Original padding for this specific layout
                .padding(.top, 20)
                .padding(.bottom, 25)

                // Trading Privileges Row - MODIFIED
                NavigationLink(
                    destination: TradingPrivilegesView(accountNumber: self.accountNumber)
                ) {
                    AccountDetailRow(
                        title: "Trading Privileges",
                        details: "Margin, Options, Extended Hour Trading"
                        // showChevron defaults to true
                    )
                }
                CustomDividerView(color: separatorColorGlobal, leadingPadding: 16)

                // MODIFIED: NavigationLink for Required Documents
                NavigationLink(destination: RequiredDocumentsView(accountNumber: self.accountNumber)) {
                    AccountDetailRow(
                        title: "Required Documents",
                        details: "HMRC Assessment Tax"
                        // showChevron defaults to true
                    )
                }
                CustomDividerView(color: separatorColorGlobal, leadingPadding: 16)

                // NEW: Phone Number Row
                AccountDetailRow(
                    title: "Phone Number",
                    details: phoneNumber,
                    showChevron: false // Do not show chevron
                )
                CustomDividerView(color: separatorColorGlobal, leadingPadding: 16)

                // NEW: Email Row
                AccountDetailRow(
                    title: "Email",
                    details: email,
                    showChevron: false // Do not show chevron
                )
                // Consider if a divider is needed after the last static item
                // For consistency with above, we'll add it.
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
    var showChevron: Bool = true // MODIFIED: Added parameter with default value

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 17))
                    .foregroundColor(primaryTextColorGlobal)
                Text(details)
                    .font(.system(size: 14))
                    .foregroundColor(secondaryTextColorGlobal) // Dimmer subtitle
                    .lineLimit(1)
            }
            Spacer()
            if showChevron { // MODIFIED: Conditionally show chevron
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(white: 0.55))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(pageBackgroundColorGlobal) // Ensure background is consistent
    }
}

// MARK: - Trading Privileges View and its components
// Reusable Account Header
struct AccountHeaderView: View {
    let accountNumber: String
    let textColor: Color
    let iconName: String // e.g., "line.horizontal.3"

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
    private let checkmarkColor = Color(red: 64 / 255, green: 192 / 255, blue: 160 / 255) // Tealish green
    private let enrolledBadgeBackgroundColor = Color(
        red: 70 / 255, green: 115 / 255, blue: 95 / 255) // Muted dark green
    private let enrolledBadgeTextColor = Color.white

    var body: some View {
        ZStack {
            pageBackgroundColorGlobal.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { // Overall container for content
                    // Margin Trading Section
                    TradingSectionView(
                        title: "Margin Trading",
                        description: "This account is not yet approved for margin.",
                        buttonText: "Upgrade",
                        buttonAction: {
                            // print("Margin Upgrade Tapped for account: \(accountNumber)")
                            // accountNumber might still be useful for actions
                            // Add navigation or action logic here
                        },
                        items: [],
                        statusBadgeText: nil,
                        colors: sectionColors
                    )
                    CustomDividerView(color: separatorColorGlobal, leadingPadding: 0) // Full width divider

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
                    CustomDividerView(color: separatorColorGlobal, leadingPadding: 0) // Full width divider

                    // Extended Hour Trading Section
                    TradingSectionView(
                        title: "Extended Hour Trading",
                        description: "This account is approved for Extended Hour Trading",
                        buttonText: nil, // No button
                        buttonAction: {},
                        items: [],
                        statusBadgeText: "Enrolled",
                        colors: sectionColors
                    )
                    // No divider after the last section
                    Spacer() // Ensures content pushes up if ScrollView is not full
                }
                .padding(.horizontal, 16) // Horizontal padding for all content inside ScrollView
            }
        }
        .navigationTitle("Account Profile") // Title remains "Account Profile" as per screenshot
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
            descriptionText: descriptiveTextColorGlobal, // Specific color for descriptions
            sectionTitle: primaryTextColorGlobal, // Section titles are primary white
            buttonBackground: accentBlueColorGlobal,
            buttonText: primaryTextColorGlobal, // White text on blue button
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
                        .padding(.vertical, 5) // Adjusted padding for badge
                        .background(colors.badgeBackground)
                        .clipShape(Capsule())
                }
            }
            .padding(.top, 20)

            Text(description)
                .font(.system(size: 15))
                .foregroundColor(colors.descriptionText) // Use specific description color
                .lineSpacing(4)

            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 10) { // Increased spacing for checklist items
                    ForEach(items, id: \.self) { item in
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark")
                                .foregroundColor(colors.checkmark)
                                .font(.system(size: 14, weight: .semibold))
                            Text(item)
                                .font(.system(size: 15))
                                .foregroundColor(colors.descriptionText) // Checklist items also use description color
                        }
                    }
                }
                .padding(.top, 8) // Space before checklist
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
        .padding(.bottom, 20) // Space after section content before a potential divider
    }
}

// MARK: - Required Documents View (NEW)
struct RequiredDocumentsView: View {
    let accountNumber: String
    // Sample data for the view
    let lastFiledDate: String = "08/16/2024"
    let renewedByDate: String = "12/31/2027"
    let infoText: String = "*W-8BEN form must be renewed every three years."

    var body: some View {
        ZStack {
            pageBackgroundColorGlobal.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { // Consistent spacing for content blocks
                    AccountHeaderView(
                        accountNumber: accountNumber,
                        textColor: secondaryTextColorGlobal,
                        iconName: "line.horizontal.3"
                    )
                    // No horizontal padding here, as the parent VStack will have it.
                    .padding(.bottom, 10) // Reduced bottom padding slightly, adjust as needed

                    // W-8BEN Form Section
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("W-8BEN Form")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(primaryTextColorGlobal)
                            Spacer()
                            Text("Certified")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(certifiedBadgeTextColor)
                                .padding(.horizontal, 12) // Slightly more horizontal padding for balance
                                .padding(.vertical, 6) // Slightly more vertical padding
                                .background(certifiedBadgeBackgroundColor)
                                .clipShape(Capsule())
                        }

                        Text("Last filed: \(lastFiledDate)")
                            .font(.system(size: 15))
                            .foregroundColor(descriptiveTextColorGlobal)
                        Text("Renewed by: \(renewedByDate)")
                            .font(.system(size: 15))
                            .foregroundColor(descriptiveTextColorGlobal)
                            .padding(.bottom, 8) // Add a bit of space before the info box

                        // Info Box
                        Text(infoText)
                            .font(.system(size: 14))
                            .foregroundColor(primaryTextColorGlobal.opacity(0.9)) // Slightly less bright for info text
                            .padding(12) // Uniform padding inside the box
                            .frame(maxWidth: .infinity, alignment: .leading) // Ensure it takes full width
                            .background(infoBoxBackgroundColor)
                            .cornerRadius(8)
                            .padding(.bottom, 16) // Space after info box before button

                        // Renew Button
                        Button(action: {
                            print("Renew button tapped for W-8BEN, account: \(accountNumber)")
                            // Add renew action logic here
                        }) {
                            Text("Renew")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundColor(primaryTextColorGlobal)
                                .frame(height: 48)
                                .frame(maxWidth: .infinity)
                                .background(accentBlueColorGlobal)
                                .cornerRadius(8)
                        }
                    }
                    Spacer() // Pushes content up if ScrollView is not full
                }
                .padding(.horizontal, 16) // Horizontal padding for all content inside ScrollView
                .padding(.top, 5) // Top padding for the content area inside ScrollView
            }
        }
        .navigationTitle("Account Profile") // Title remains "Account Profile"
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
