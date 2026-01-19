# AGENTS.md - Context & Rules for AI Agents

## Project Overview
- **Name**: Finance / Indices
- **Platform**: iOS / macOS
- **Language**: Swift (SwiftUI, Combine, Swift Concurrency)
- **Project File**: `Finance.xcodeproj`
- **Main Scheme**: `Finance`
- **Test Framework**: Swift Testing (new `@Test` macro)

## Build & Test Commands

### Build
Run the build for the iPhone 16 Simulator (or available simulator):
```bash
xcodebuild build -project Finance.xcodeproj -scheme Finance -destination 'platform=iOS Simulator,name=iPhone 16'
```

### Run Tests
Execute the test suite. Note that this project uses the modern Swift Testing framework (`import Testing`).
```bash
xcodebuild test -project Finance.xcodeproj -scheme Finance -destination 'platform=iOS Simulator,name=iPhone 16'
```

### Run Specific Test
To run a specific test case (e.g., `example` in `IndicesTests`):
```bash
xcodebuild test -project Finance.xcodeproj -scheme Finance -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:FinanceTests/IndicesTests/example
```

## Code Style & Conventions

### General
- **Formatting**: 4 spaces indentation.
- **Naming**: 
  - Types: `PascalCase` (e.g., `DataService`, `OptionItem`)
  - Variables/Functions: `camelCase` (e.g., `loadData`, `optionsData`)
- **Imports**: Group system imports (`Foundation`, `SwiftUI`) together.
- **Comments**: 
  - Chinese comments are common and acceptable.
  - Use `// MARK: - Section Name` to organize code sections.

### Architecture
- **Pattern**: MVVM with `ObservableObject` and `@Published` properties.
- **Data Layer**: Singleton pattern is used for services (e.g., `DataService.shared`).
- **Models**: Prefer `struct` with `Codable` and `Identifiable` conformance.

### Concurrency
- **Modern Swift**: Use `async/await` over callbacks where possible.
- **Main Thread**: Use `await MainActor.run { ... }` or `@MainActor` for UI updates.
- **Tasks**: Use `Task` and `Task.detached` for background work.
- **Safety**: Be mindful of Swift 6 concurrency strictness (e.g., Sendable warnings).

### Error Handling
- Use `do-catch` blocks for asynchronous data loading.
- Log errors using `print("ServiceName: Error description: \(error)")`.
- Expose user-facing errors via `@Published var errorMessage: String?`.

## Dependencies
- **System**: Foundation, Combine, SwiftUI.
- **Networking**: `URLSession.shared`.
- **JSON**: `JSONDecoder`.

## Testing
- **Framework**: `import Testing` (Swift Testing).
- **Import**: Use `@testable import Indices` (or appropriate module name).
- **Structure**: 
  ```swift
  import Testing
  @testable import Indices
  
  struct MyTests {
      @Test func myTestCase() async throws {
          #expect(...)
      }
  }
  ```

## File Structure
- `Finance/`: Main source code.
- `FinanceTests/`: Unit tests.
- `FinanceUITests/`: UI tests.
- `Finance/DataService.swift`: Core data manager (Singleton).

## Common Patterns
- **Chunking**: Arrays have a `.chunked(into:)` extension.
- **Config**: Configuration often loaded from `UserDefaults`.
- **File System**: `FileManagerHelper` is used for local file access.
