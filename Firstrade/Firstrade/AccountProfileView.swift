import SwiftUI

// Assuming Color(hex:) is defined (or needs to be), to use the hex code colors in the rest of MyView

//extension Color { // if not defined elsewhere
//    init(hex: String) { ... }
//}

// Colors are defined this way in the original MyView code.
// Using consistent colors and naming conventions is important, but I am re-defining them here in AccountProfileView.
//  To ensure the design from the image is matched, I will use new file private named colors specific to AccountProfileView.

// File private color definitions for AccountProfileView to match the screenshot
fileprivate let apPageBackgroundColor = Color(red: 25/255, green: 30/255, blue: 39/255) // Dark blue (Same as MyView's pageBackgroundColor and rowBackgroundColor) - #191E27
fileprivate let apPrimaryTextColor = Color.white  // White text (Same as MyView's primaryTextColor)
fileprivate let apSecondaryTextColor = Color(white: 0.65) // Lighter gray than .gray, to match the "Margin, Options..." text in the screenshot. This is what looks like the most proper visual match.
fileprivate let apSeparatorColor = Color(white: 0.3)  // Light gray, for separator lines.

struct AccountProfileView: View {
//    let accountNumber: String = "90185542" // Replace with actual data if available

    var body: some View {
        ZStack {
            apPageBackgroundColor.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Account Number Display
                HStack(spacing: 8) {  // Spacing between text and icon
//                    Text(accountNumber)
//                        .font(.system(size: 15)) // From screenshot observations
//                        .foregroundColor(apSecondaryTextColor)
//                    Image(systemName: "line.horizontal.3") // Menu/ more icon next to the account number (or the "=" from OCR).
//                        .font(.system(size: 15))  // Match icon to the text size
//                        .foregroundColor(apSecondaryTextColor)
                }
                .padding(.leading, 16) // Align the the section's rows content
                .padding(.top, 20)
                .padding(.bottom, 25)

                // Trading Privileges Row
                NavigationLink(destination: Text("Trading Privileges Details View (Placeholder)")) { // Set destination view later
                    AccountDetailRow(
                        title: "Trading Privileges",
                        details: "Margin, Options, Extended Hour Trading"
                    )
                }
                Rectangle() // Horizontal line
                    .frame(height: 0.5)
                    .foregroundColor(apSeparatorColor)
                    .padding(.leading, 16) // Indent line

                // Required Documents Row
                NavigationLink(destination: Text("Required Documents Details View (Placeholder)")) {  // Destination view later
                    AccountDetailRow(
                        title: "Required Documents",
                        details: "W-8BEN"
                    )
                }
                Rectangle() // Horizontal line
                    .frame(height: 0.5)
                    .foregroundColor(apSeparatorColor)
                    .padding(.leading, 16) // Indent line

                Spacer() // Push content to the top
            }
        }
        .navigationTitle("Account Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Account Profile")
                    .font(.headline)
                    .foregroundColor(apPrimaryTextColor)
            }
        }
        // The .toolbarColorScheme(.dark, for: .navigationBar) from MyView should correctly set the back button color in navigation bar .
    }
}

struct AccountDetailRow: View {
    let title: String
    let details: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) { // Spacing between title and details
                Text(title)
                    .font(.system(size: 17)) // From screenshot (section title size)
                    .foregroundColor(apPrimaryTextColor)
                Text(details)
                    .font(.system(size: 14)) // From screenshot (smaller detail size)
                    .foregroundColor(apSecondaryTextColor)
                    .lineLimit(1) // Ensure details are on one line.
            }
            Spacer()
            Image(systemName: "chevron.right") // Standard disclosure indicator
                .font(.system(size: 14, weight: .semibold)) // Standard size.
                .foregroundColor(Color(white: 0.55)) // Chevron color
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(apPageBackgroundColor) // Ensure the background is set .
    }
}
