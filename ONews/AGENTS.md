# ONews - Agent Instructions

This document provides context and guidelines for AI agents working on the ONews codebase.

## 1. Project Overview
- **Type**: Native iOS Application
- **Language**: Swift
- **UI Framework**: SwiftUI (primary) with minimal UIKit bridges (`UIViewRepresentable`)
- **Architecture**: MVVM (Model-View-ViewModel) + Managers
- **State Management**: Heavy reliance on `ObservableObject`, `@Published`, and `@EnvironmentObject`
- **Concurrency**: Modern Swift Concurrency (`Task`, `async/await`, `@MainActor`) mixed with some Combine

## 2. Build & Test Commands

### Build
Standard `xcodebuild` usage.
```bash
# Build the main scheme
xcodebuild -scheme ONews -destination 'platform=iOS Simulator,name=iPhone 16' build
```

### Test
The project uses the modern **Swift Testing** framework for Unit Tests and **XCTest** for UI Tests.

```bash
# Run all tests
xcodebuild test -scheme ONews -destination 'platform=iOS Simulator,name=iPhone 16'

# Note: Running a specific test case in the command line for Swift Testing 
# is currently complex via xcodebuild. Prefer running the full suite.
```

## 3. Code Style & Conventions

### Architecture Pattern
- **ViewModels**: Must be marked `@MainActor` if they update UI.
- **Managers**: Encapsulate logic in "Manager" classes (e.g., `AuthManager`, `ResourceManager`, `AppBadgeManager`).
- **Dependency Injection**: 
  - Use `.environmentObject` for shared state (Auth, Resources).
  - Use constructor injection for specific ViewModels in subviews.
- **Entry Point**: Custom `AppDelegate` logic is bridged via `@UIApplicationDelegateAdaptor` to handle app lifecycle and manager initialization.

### Naming & formatting
- **Classes/Structs**: Use descriptive suffixes: `NewsViewModel`, `ArticleListView`, `AuthManager`.
- **Variables**: `camelCase`.
- **Comments**: 
  - **CRITICAL**: Significant logic changes or key decision points are often commented in **Chinese** using brackets, e.g., `// 【修改】...` or `// 【核心修复】...`.
  - Maintain this style for important architectural notes.

### UI Guidelines
- **SwiftUI First**: Prefer SwiftUI views. Only use `UIViewRepresentable` if absolutely necessary (e.g., complex ScrollView behaviors or specific UIKit-only APIs).
- **Localization**: All user-facing strings must go through `Localization.swift` or `Localized` struct. Do not hardcode strings in Views.
- **Color**: Use semantic colors defined in `MainView.swift` extension (e.g., `Color.viewBackground`, `Color.cardBackground`).

### Data & Logic
- **No CoreData/SwiftData**: The app manually manages JSON persistence in the `Documents` directory.
- **Bilingual Support**: Logic often handles dual English/Chinese names (splitting strings by `|`). Respect existing logic for `sourceName` vs `sourceNameEN`.
- **Networking**: Uses native `URLSession`. No Alamofire.
- **Image Loading**: Custom download/caching logic in `ResourceManager`. No Kingfisher/SDWebImage.

## 4. Error Handling
- Prefer `async throws` over Result types or completion handlers.
- Handle errors gracefully in UI (alerts/toasts) rather than crashing.
- Specific errors (like Keychain issues) have custom Enum types.

## 5. Development Workflow
- **Linting**: No active linter. Follow surrounding code style strictly.
- **Files**: 
  - `ONews/`: Main source code.
  - `ONewsTests/`: Unit tests (Swift Testing).
  - `ONewsUITests/`: UI tests (XCTest).

## 6. Common Patterns to Follow
- **Task Detachment**: For heavy I/O (like JSON parsing), use `Task.detached` to avoid blocking the main thread, then switch back to `@MainActor` for updates.
- **Safe Arrays**: Be careful with array indexing; the code often checks indices manually.
- **Global Settings**: User preferences (like "Global English Mode") are stored in `UserDefaults` / `@AppStorage`.
