import SwiftUI

struct MyView: View {
    @EnvironmentObject private var session: SessionStore

    // Keychain details (kept for context, not directly used in UI changes here)
    private let userKey = "rememberedUsernameKey"
    private let pwdAccount = "rememberedPasswordKey"
    private let keychainService = Bundle.main.bundleIdentifier ?? "com.myapp.login"

    // Define colors based on the design
    let pageBackgroundColor = Color(red: 25/255, green: 30/255, blue: 39/255) // #191E27
    let rowBackgroundColor = Color(red: 25/255, green: 30/255, blue: 39/255)    // Same as page for seamless look
    let primaryTextColor = Color.white
    let secondaryTextColor = Color.gray
    let accentButtonColor = Color(hex: "3B82F6") // Blue for the logout button

    var body: some View {
        NavigationView {
            ZStack {
                pageBackgroundColor.ignoresSafeArea() // Apply background to the entire screen

                VStack(spacing: 0) { // Main container for List, Button, and Version Text
                    List {
                        // Section "账户"
                        Section(
                            header: Text("ACCOUNT")
                                .font(.system(size: 16))
                                .foregroundColor(primaryTextColor)
                                .padding(.leading, 16) // Indent header to align with row content
                                .padding(.top, 20)      // Space above the first section
                                .padding(.bottom, 8)    // Space between header and its items
                        ) {
                            NavigationLinkRow(title: "Profile", destination: Text("Account and Setting"), pageBackgroundColor: rowBackgroundColor, textColor: primaryTextColor)
                                // THIS IS THE LINE TO CHANGE:
                                NavigationLinkRow(title: "Deposit/Withdrawal", destination: DepositWithdrawView(), pageBackgroundColor: rowBackgroundColor, textColor: primaryTextColor)
//                                NavigationLinkRow(title: "转户至第一证券", destination: Text("转户至第一证券页面"), pageBackgroundColor: rowBackgroundColor, textColor: primaryTextColor)
                                NavigationLinkRow(title: "Open a New Account", destination: Text("Open new"), pageBackgroundColor: rowBackgroundColor, textColor: primaryTextColor)
                        }
                        .listRowSeparator(.hidden, edges: .top) // Hide separator above the first section's content
                        .listRowSeparatorTint(secondaryTextColor.opacity(0.3)) // Style for separators within section

                        // Section "支援中心"
                        Section(
                            header: Text("SUPPORT")
                                .font(.system(size: 16))
                                .foregroundColor(primaryTextColor)
                                .padding(.leading, 16) // Indent header
                                .padding(.top, 15)      // Space above this section header
                                .padding(.bottom, 8)
                        ) {
                            NavigationLinkRow(title: "Help Center", destination: Text("help"), pageBackgroundColor: rowBackgroundColor, textColor: primaryTextColor)
                            NavigationLinkRow(title: "Contact Us", destination: Text("contact"), pageBackgroundColor: rowBackgroundColor, textColor: primaryTextColor)
                            NavigationLinkRow(title: "Terms & Disclosures", destination: Text("Terms"), pageBackgroundColor: rowBackgroundColor, textColor: primaryTextColor)
                            NavigationLinkRow(title: "App Guide", destination: Text("APP Guide"), pageBackgroundColor: rowBackgroundColor, textColor: primaryTextColor)
                            NavigationLinkRow(title: "What's new in this release", destination: Text("new feature"), pageBackgroundColor: rowBackgroundColor, textColor: primaryTextColor)
                        }
                        .listRowSeparatorTint(secondaryTextColor.opacity(0.3))
                    }
                    .listStyle(PlainListStyle())
                    .background(Color.clear) // Make List background transparent to show ZStack's color
                    .environment(\.defaultMinListRowHeight, 48) // Adjust default row height if needed

                    // Logout Button
                    Button(action: logout) {
                        Text("Log Out")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(primaryTextColor)
                            .frame(height: 48)
                            .frame(maxWidth: .infinity)
                            .background(accentButtonColor)
                            .cornerRadius(8)
                    }
                    .padding(.horizontal, 16) // Side padding for the button
                    .padding(.top, 30)        // Space above the button
                    .padding(.bottom, 15)     // Space between button and version text

                    // Version Number
                    Text("v3.15.1-3003860")
                        .font(.system(size: 12))
                        .foregroundColor(secondaryTextColor)
                        .padding(.bottom, 20) // Padding at the very bottom
                }
            }
            .navigationTitle("Account & Setting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { // Center the navigation bar title
                    Text("Account & Setting")
                        .font(.headline)
                        .foregroundColor(primaryTextColor)
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar) // Ensures light status bar & nav items on dark bar
        }
        .navigationViewStyle(StackNavigationViewStyle()) // Use StackNavigationViewStyle for typical phone layouts
    }

    private func logout() {
        // Go back to login page (original logic)
        session.isLoggedIn = false
        session.username = ""
    }
}

// Reusable struct for NavigationLink rows to ensure consistent styling
struct NavigationLinkRow<Destination: View>: View {
    let title: String
    let destination: Destination
    let pageBackgroundColor: Color // Pass from MyView for consistency
    let textColor: Color           // Pass from MyView

    var body: some View {
        NavigationLink(destination: destination) {
            HStack {
                Text(title)
                    .foregroundColor(textColor)
                    .font(.system(size: 17))
                Spacer()
            }
            .padding(.vertical, 2) // Adjust vertical padding within the row content area
        }
        .listRowBackground(pageBackgroundColor) // Set row background to blend with the page
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)) // Padding for content inside the row
    }
}
