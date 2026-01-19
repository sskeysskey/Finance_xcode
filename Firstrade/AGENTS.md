# Firstrade Codebase Guide

## 1. Build & Test Commands

This is a standard Xcode project using `xcodebuild`.

### Environment
- **Platform**: iOS
- **Language**: Swift 6
- **UI Framework**: SwiftUI
- **Project File**: `Firstrade.xcodeproj`
- **Schemes**: `Firstrade`, `FirstradeTests`, `FirstradeUITests`

### Build
To build the app for the simulator:
```bash
xcodebuild -scheme Firstrade -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build
```
*(Replace `iPhone 16 Pro` with an available simulator if needed)*

### Test
Run all unit tests:
```bash
xcodebuild test -scheme Firstrade -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

Run a **single test case** (Swift Testing or XCTest):
```bash
# Format: -only-testing:TargetName/ClassName/MethodName
xcodebuild test -scheme Firstrade \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:FirstradeTests/ExampleTests/testExample
```

### Linting
- No strict linter configuration (e.g., SwiftLint) was found.
- Follow the **Code Style Guidelines** below strictly to maintain consistency.

---

## 2. Code Style Guidelines

### Architecture & Patterns
- **Pattern**: MVVM (Model-View-ViewModel).
  - **View**: SwiftUI structs.
  - **ViewModel**: `ObservableObject` classes handling logic & state.
  - **Model**: Simple `struct` data types (Codable, Identifiable).
- **State Management**:
  - Global: `SessionStore` injected via `.environmentObject`.
  - Local: `@State`, `@Binding`, `@StateObject` (for VM ownership).
  - **Do not** use Singleton for view state; use dependency injection.
- **Data Persistence**:
  - `SQLite` (via `sqlite3` C API) for structured data.
  - `Keychain` for sensitive credentials (passwords).
  - `UserDefaults` for simple preferences (remember username).
- **Concurrency**:
  - Uses `async/await`.
  - `DispatchQueue.main` for UI updates inside callbacks.

### Formatting & Syntax
- **Indentation**: **4 spaces**.
- **Braces**: OTBS (One True Brace Style) - open brace on the same line.
- **Imports**: Alphabetical order is not strictly enforced, but group system frameworks (`SwiftUI`, `Combine`) before others.
- **Spacing**:
  - One blank line between methods.
  - Space after colons (`var name: String`).
  - No trailing whitespace.

### Naming Conventions
- **Types** (Classes, Structs, Enums, Protocols): `PascalCase`
  - e.g., `MarketsView`, `AssetsViewModel`, `TransactionRecord`
- **Variables & Functions**: `camelCase`
  - e.g., `isLoggedIn`, `fetchData()`, `userAccount`
- **View Files**: Suffix with `View` (e.g., `LoginView.swift`, `PortfolioView.swift`).
- **Constants**: `camelCase` (e.g., `maxRetries`), often defined within the relevant scope.

### SwiftUI Specifics
- **View Decomposition**: Break complex views into smaller `struct` subviews within the same file (using `fileprivate` or `private` if not shared) or in separate files if reusable.
  - Use `// MARK: - Subviews` to separate them.
- **Modifiers**: format multiline modifiers with one modifier per line, indented.
  ```swift
  Text("Hello")
      .font(.title)
      .foregroundColor(.blue)
      .padding()
  ```
- **Preview**: Include `#Preview` or `PreviewProvider` for all views. Inject dummy environment objects if needed.

### Error Handling
- **Early Exit**: Prefer `guard let ... else { return }` over deep nesting.
- **User Feedback**: Use `@State` strings (e.g., `alertMessage`) bound to `.alert()` modifiers to show errors to the user.
- **Safe Decoding**: Use `try?` for JSON decoding if the failure is handled gracefully by returning `nil`.
- **Database**: Check `sqlite3` return codes (e.g., `SQLITE_OK`, `SQLITE_ROW`).

### Testing
- **Frameworks**:
  - **Unit Tests**: Uses standard `XCTest` and the new **Swift Testing** framework (`@Test`).
  - **UI Tests**: `XCTest` (`XCUIApplication`).
- **Location**: `FirstradeTests/` directory.
- **Naming**: Test classes end in `Tests` (e.g., `LoginTests.swift`).

### Miscellaneous
- **Auth**: FaceID integration uses `LocalAuthentication`.
- **Networking**: Typically handled in ViewModels or dedicated service classes.
- **Dependencies**: Minimal external dependencies; prefer native frameworks.

---

## 3. Workflow for Agents
1. **Explore first**: When modifying a View, read the corresponding ViewModel.
2. **Atomic Changes**: Modify one logical component at a time.
3. **Verify**: Run `lsp_diagnostics` on modified files.
4. **Test**: Run the relevant test suite before finishing.
