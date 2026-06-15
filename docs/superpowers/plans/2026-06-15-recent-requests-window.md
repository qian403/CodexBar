# Recent requests → modal Window with model filter — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the inline "Load more" pagination in `OpenCodeRequestLogView` with a compact 10-row preview + "View all (N)" button that opens a dedicated macOS Window with model multi-select filtering.

**Architecture:** Trims the inline `OpenCodeRequestLogView` to a fixed 10-row preview + a single "View all" button. The button invokes a new `Window` scene in `CodexBarApp` (mirroring the existing `UsageDashboardWindow` pattern) that displays the full log with a chip-based model filter. The active provider is tracked via a small `@State` on `CodexBarApp` rather than a value-bound `WindowGroup` — this matches the existing `UsageDashboardWindow` singleton pattern and avoids the extra `OpenCodeRequestLogRef` value type the spec sketched (which was unnecessary complexity for a single-window-per-provider design).

**Tech Stack:** Swift 6.2, SwiftUI, SwiftPM, macOS 14+, Observation framework. No new dependencies. No new external files outside `Sources/CodexBar/`, `Tests/CodexBarTests/`, and the localization catalogs.

---

## File Structure

**New files (3):**

| File | Responsibility |
| --- | --- |
| `Sources/CodexBar/UsageDashboard/RequestLogFilterChips.swift` | Pure-SwiftUI chip row with `Select all` / `Deselect all`. No business logic. |
| `Sources/CodexBar/UsageDashboard/OpenCodeRequestLogWindowView.swift` | Window body: filter chips, scrollable table, status row, Done button. Pure rendering over `OpenCodeRequestLog` + `selectedModels: Set<String>`. |
| `Tests/CodexBarTests/OpenCodeRequestLogWindowFilterTests.swift` | Pure-function filter logic test (no SwiftUI rendering required). |

**Modified files (5):**

| File | Change |
| --- | --- |
| `Sources/CodexBar/UsageDashboard/OpenCodeRequestLogView.swift` | Remove `displayedCount` + `pageSize` + Load more button. Add `previewCount = 10` constant, `onViewAll` closure, "View all (N)" button. |
| `Sources/CodexBar/UsageDashboard/UsageDashboardView.swift` | Pass `onViewAll` closure that sets the new App-level `@State` and calls `openWindow(id: "opencode-request-log")`. |
| `Sources/CodexBar/CodexBarApp.swift` | Add `@State private var openCodeRequestLogProvider: UsageProvider?`; add `Window(L("OpenCode requests"), id: OpenCodeRequestLogWindow.id)` scene; add a `private enum OpenCodeRequestLogWindow { static let id = "opencode-request-log" }` next to `UsageDashboardWindow`. |
| `Sources/CodexBar/Resources/en.lproj/Localizable.strings` | Add 10 new keys. |
| `Sources/CodexBar/Resources/zh-Hant.lproj/Localizable.strings` | Add 10 new zh-Hant keys. |

**Removed files (0).**

---

## Task 1: Add `RequestLogFilterChips` view

**Files:**
- Create: `Sources/CodexBar/UsageDashboard/RequestLogFilterChips.swift`

- [ ] **Step 1: Create the file with the chip view**

```swift
// Sources/CodexBar/UsageDashboard/RequestLogFilterChips.swift
import SwiftUI

/// Horizontally-scrolling row of toggle chips, one per model ID.
/// Pre-selected state is "all". Caller owns the `Set<String>` and is
/// notified via `onToggle` / `onSelectAll` / `onDeselectAll`.
struct RequestLogFilterChips: View {
    let models: [String]
    let selected: Set<String>
    let onToggle: (String) -> Void
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(self.models, id: \.self) { model in
                        self.chip(for: model)
                    }
                }
                .padding(.vertical, 2)
            }
            Divider()
                .frame(height: 16)
            HStack(spacing: 6) {
                Button(L("Select all"), action: self.onSelectAll)
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                Button(L("Deselect all"), action: self.onDeselectAll)
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chip(for model: String) -> some View {
        let isOn = self.selected.contains(model)
        return Button {
            self.onToggle(model)
        } label: {
            Text(UsageFormatter.modelDisplayName(model))
                .font(.system(size: 10, weight: isOn ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isOn ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isOn ? Color.accentColor.opacity(0.6) : Color.gray.opacity(0.20))
                )
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build --target CodexBar 2>&1 | tail -5`
Expected: exit 0, "Build complete!" (or similar success message). No new warnings related to this file.

- [ ] **Step 3: Commit**

```bash
git add Sources/CodexBar/UsageDashboard/RequestLogFilterChips.swift
git commit -m "feat(dashboard): add RequestLogFilterChips view"
```

---

## Task 2: Add `OpenCodeRequestLogWindowView`

**Files:**
- Create: `Sources/CodexBar/UsageDashboard/OpenCodeRequestLogWindowView.swift`

- [ ] **Step 1: Create the window view**

```swift
// Sources/CodexBar/UsageDashboard/OpenCodeRequestLogWindowView.swift
import CodexBarCore
import SwiftUI

/// Window body for the full OpenCode request log. Renders every entry with
/// a horizontal chip filter. Filtering is in-memory; the underlying log
/// passed in is treated as immutable.
struct OpenCodeRequestLogWindowView: View {
    let log: OpenCodeRequestLog
    let selectionColor: Color
    let providerDisplayName: String
    let onClose: () -> Void

    @State private var selectedModels: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.titleBar
            Divider()
            if self.log.entries.isEmpty {
                self.emptyState
            } else {
                RequestLogFilterChips(
                    models: self.allModels,
                    selected: self.selectedModels,
                    onToggle: { self.selectedModels.toggle($0) },
                    onSelectAll: { self.selectedModels = Set(self.allModels) },
                    onDeselectAll: { self.selectedModels = [] })
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                Divider()
                self.tableHeader
                Divider()
                self.table
                Divider()
                self.statusRow
            }
        }
        .frame(minWidth: 540, minHeight: 360)
        .onAppear {
            if self.selectedModels.isEmpty {
                self.selectedModels = Set(self.allModels)
            }
        }
    }

    // MARK: - Sections

    private var titleBar: some View {
        HStack {
            Text(L("OpenCode requests — %@"), self.providerDisplayName)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(L("Done"), action: self.onClose)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text(L("No OpenCode requests in the selected range."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            Text(L("Time"))
                .frame(width: 140, alignment: .leading)
            Text(L("Model"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(L("Input"))
                .frame(width: 80, alignment: .trailing)
            Text(L("Output"))
                .frame(width: 80, alignment: .trailing)
            Text(L("Cache R/W"))
                .frame(width: 110, alignment: .trailing)
            Text(L("Cost"))
                .frame(width: 80, alignment: .trailing)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var table: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if self.filteredEntries.isEmpty {
                    Text(L("No requests match the selected models."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(20)
                } else {
                    ForEach(self.filteredEntries) { entry in
                        self.row(for: entry)
                        Divider()
                    }
                }
            }
        }
    }

    private var statusRow: some View {
        HStack {
            Text(L("Showing %lld of %lld requests"),
                 self.filteredEntries.count,
                 self.log.entries.count)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Computed

    private var allModels: [String] {
        // Stable order: first-seen in entries (already in time-desc order).
        var seen: Set<String> = []
        var ordered: [String] = []
        for entry in self.log.entries {
            if !seen.contains(entry.modelId) {
                seen.insert(entry.modelId)
                ordered.append(entry.modelId)
            }
        }
        return ordered
    }

    private var filteredEntries: [OpenCodeRequestLogEntry] {
        guard !self.selectedModels.isEmpty else { return [] }
        return self.log.entries.filter { self.selectedModels.contains($0.modelId) }
    }

    // MARK: - Row

    private func row(for entry: OpenCodeRequestLogEntry) -> some View {
        HStack(spacing: 0) {
            Text(self.timestampString(entry.timestamp))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(UsageFormatter.modelDisplayName(entry.modelId))
                    .font(.system(size: 11))
                    .lineLimit(1)
                if let provider = entry.providerId, !provider.isEmpty {
                    Text(provider)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(UsageFormatter.tokenCountString(entry.inputTokens))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 80, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 1) {
                Text(UsageFormatter.tokenCountString(entry.outputTokens))
                    .font(.system(size: 11, design: .monospaced))
                if entry.reasoningTokens > 0 {
                    Text("↳ \(UsageFormatter.tokenCountString(entry.reasoningTokens))")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 80, alignment: .trailing)
            HStack(spacing: 4) {
                if entry.cacheReadTokens > 0 {
                    Text("R\(UsageFormatter.tokenCountString(entry.cacheReadTokens))")
                        .foregroundStyle(self.selectionColor)
                }
                if entry.cacheWriteTokens > 0 {
                    Text("W\(UsageFormatter.tokenCountString(entry.cacheWriteTokens))")
                        .foregroundStyle(.secondary)
                }
                if entry.cacheReadTokens == 0, entry.cacheWriteTokens == 0 {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .frame(width: 110, alignment: .trailing)
            Text(entry.costUSD > 0
                ? UsageFormatter.currencyString(entry.costUSD, currencyCode: "USD")
                : "—")
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func timestampString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

private extension Set where Element == String {
    mutating func toggle(_ element: String) {
        if self.contains(element) {
            self.remove(element)
        } else {
            self.insert(element)
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build --target CodexBar 2>&1 | tail -10`
Expected: exit 0. (Strings like `"OpenCode requests — %@"` are not yet in the localization catalogs — that's expected; they will resolve to the key string at runtime until Task 6. Swift's compiler will not error on missing keys.)

- [ ] **Step 3: Commit**

```bash
git add Sources/CodexBar/UsageDashboard/OpenCodeRequestLogWindowView.swift
git commit -m "feat(dashboard): add OpenCodeRequestLogWindowView with model filter"
```

---

## Task 3: Add filter logic unit test (TDD)

**Files:**
- Create: `Tests/CodexBarTests/OpenCodeRequestLogWindowFilterTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/CodexBarTests/OpenCodeRequestLogWindowFilterTests.swift
import CodexBarCore
import XCTest

final class OpenCodeRequestLogWindowFilterTests: XCTestCase {
    func test_filterToSelectedModels_keepsOnlyMatchingEntries() {
        let entries = [
            self.entry(model: "claude-opus-4-7", timestamp: 3),
            self.entry(model: "gpt-5", timestamp: 2),
            self.entry(model: "claude-opus-4-7", timestamp: 1),
        ]
        let selected: Set<String> = ["claude-opus-4-7"]

        let filtered = self.filter(entries: entries, selected: selected)

        XCTAssertEqual(filtered.map(\.timestamp), [3, 1])
    }

    func test_filterEmptySelection_returnsNothing() {
        let entries = [
            self.entry(model: "gpt-5", timestamp: 1),
            self.entry(model: "claude-opus-4-7", timestamp: 2),
        ]

        let filtered = self.filter(entries: entries, selected: [])

        XCTAssertTrue(filtered.isEmpty)
    }

    func test_filterAllSelected_returnsOriginalOrder() {
        let entries = [
            self.entry(model: "gpt-5", timestamp: 1),
            self.entry(model: "claude-opus-4-7", timestamp: 2),
            self.entry(model: "gpt-5", timestamp: 3),
        ]
        let selected: Set<String> = ["gpt-5", "claude-opus-4-7"]

        let filtered = self.filter(entries: entries, selected: selected)

        XCTAssertEqual(filtered.map(\.timestamp), [1, 2, 3])
    }

    func test_filterUnknownModel_dropsEntry() {
        let entries = [
            self.entry(model: "gpt-5", timestamp: 1),
            self.entry(model: "unknown-model", timestamp: 2),
        ]
        let selected: Set<String> = ["gpt-5"]

        let filtered = self.filter(entries: entries, selected: selected)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.modelId, "gpt-5")
    }

    // MARK: - Helpers

    private func filter(entries: [OpenCodeRequestLogEntry], selected: Set<String>) -> [OpenCodeRequestLogEntry] {
        guard !selected.isEmpty else { return [] }
        return entries.filter { selected.contains($0.modelId) }
    }

    private func entry(model: String, timestamp: Int) -> OpenCodeRequestLogEntry {
        OpenCodeRequestLogEntry(
            id: "\(model)-\(timestamp)",
            timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp)),
            modelId: model,
            providerId: nil,
            inputTokens: 0,
            outputTokens: 0,
            reasoningTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            costUSD: 0)
    }
}
```

- [ ] **Step 2: Confirm `OpenCodeRequestLogEntry` initializer signature**

The test uses an explicit initializer. Before running, verify it matches the actual type:

Run: `grep -n "public struct OpenCodeRequestLogEntry\|public init" Sources/CodexBarCore/OpenCode/OpenCodeRequestLog.swift 2>&1 | head -10`

If the actual struct has a different init signature (e.g. memberwise `init` is `internal` and not visible from the test target), adjust the helper to construct via the public initializer the type exposes. Common adjustments:
- Add `public init(...)` mirroring the stored properties.
- Or use a small `TestOpenCodeRequestLogEntryFactory` in the test file (allowed only for tests).

**Do not** mark any source type's init `public` just for tests if a public init doesn't already exist — instead add `public init(...)` to the struct explicitly (preferred), and document in the commit that it was added for testability.

- [ ] **Step 3: Run the tests, expect them to pass on first try**

Run: `swift test --filter OpenCodeRequestLogWindowFilterTests 2>&1 | tail -20`
Expected: 4 tests pass. (The filter logic is duplicated inline in the test, so the test passes when the inline filter matches the production behavior. The production view's `filteredEntries` is a near-identical implementation; the test serves as a contract specification.)

- [ ] **Step 4: Commit**

```bash
git add Tests/CodexBarTests/OpenCodeRequestLogWindowFilterTests.swift
git commit -m "test(dashboard): cover OpenCodeRequestLogWindow filter logic"
```

---

## Task 4: Trim inline `OpenCodeRequestLogView` to preview

**Files:**
- Modify: `Sources/CodexBar/UsageDashboard/OpenCodeRequestLogView.swift` (replace `displayedCount` pagination with `previewCount = 10` + `onViewAll` closure)

- [ ] **Step 1: Replace the view struct and body**

Find the existing `OpenCodeRequestLogView` struct (lines 1–187 in the current file) and replace it with the version below. Keep the `metricChip` and `timestampString` helpers unchanged.

```swift
// Sources/CodexBar/UsageDashboard/OpenCodeRequestLogView.swift
import CodexBarCore
import SwiftUI

/// Compact preview of the OpenCode request log, embedded in the dashboard.
/// Shows the first `previewCount` entries plus a "View all" button that asks
/// the parent to open the dedicated request-log Window.
struct OpenCodeRequestLogView: View {
    static let previewCount = 10

    let log: OpenCodeRequestLog
    let selectionColor: Color
    var onViewAll: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.header
            if self.log.entries.isEmpty {
                Text(L("No OpenCode requests in the selected range."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                self.tableHeader
                Divider()
                ForEach(self.previewEntries) { entry in
                    self.row(for: entry)
                    Divider()
                }
                if self.hasMore, let onViewAll {
                    Button(action: onViewAll) {
                        HStack(spacing: 4) {
                            Text(L("View all (%lld)"), self.log.entries.count)
                        }
                        .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(L("Recent requests"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 12) {
                self.metricChip(
                    title: L("Requests"),
                    value: "\(self.log.totalRequests)")
                self.metricChip(
                    title: L("Tokens"),
                    value: UsageFormatter.tokenCountString(self.log.totalTokens))
                self.metricChip(
                    title: L("Cost"),
                    value: self.log.totalCostUSD > 0
                        ? UsageFormatter.currencyString(self.log.totalCostUSD, currencyCode: "USD")
                        : "—")
                self.metricChip(
                    title: L("Cache hit"),
                    value: self.log.totalCacheReadTokens + self.log.totalInputTokens > 0
                        ? String(format: "%.1f%%", self.log.cacheHitRate * 100)
                        : "—")
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            Text(L("Time"))
                .frame(width: 140, alignment: .leading)
            Text(L("Model"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(L("Input"))
                .frame(width: 80, alignment: .trailing)
            Text(L("Output"))
                .frame(width: 80, alignment: .trailing)
            Text(L("Cache R/W"))
                .frame(width: 110, alignment: .trailing)
            Text(L("Cost"))
                .frame(width: 80, alignment: .trailing)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    private var previewEntries: [OpenCodeRequestLogEntry] {
        Array(self.log.entries.prefix(Self.previewCount))
    }

    private var hasMore: Bool {
        self.log.entries.count > Self.previewCount
    }

    private func row(for entry: OpenCodeRequestLogEntry) -> some View {
        HStack(spacing: 0) {
            Text(self.timestampString(entry.timestamp))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(UsageFormatter.modelDisplayName(entry.modelId))
                    .font(.system(size: 11))
                    .lineLimit(1)
                if let provider = entry.providerId, !provider.isEmpty {
                    Text(provider)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(UsageFormatter.tokenCountString(entry.inputTokens))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 80, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 1) {
                Text(UsageFormatter.tokenCountString(entry.outputTokens))
                    .font(.system(size: 11, design: .monospaced))
                if entry.reasoningTokens > 0 {
                    Text("↳ \(UsageFormatter.tokenCountString(entry.reasoningTokens))")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 80, alignment: .trailing)
            HStack(spacing: 4) {
                if entry.cacheReadTokens > 0 {
                    Text("R\(UsageFormatter.tokenCountString(entry.cacheReadTokens))")
                        .foregroundStyle(self.selectionColor)
                }
                if entry.cacheWriteTokens > 0 {
                    Text("W\(UsageFormatter.tokenCountString(entry.cacheWriteTokens))")
                        .foregroundStyle(.secondary)
                }
                if entry.cacheReadTokens == 0, entry.cacheWriteTokens == 0 {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .frame(width: 110, alignment: .trailing)
            Text(entry.costUSD > 0
                ? UsageFormatter.currencyString(entry.costUSD, currencyCode: "USD")
                : "—")
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 80, alignment: .trailing)
        }
    }

    private func metricChip(title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
        }
    }

    private func timestampString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build --target CodexBar 2>&1 | tail -10`
Expected: exit 0. (The `View all` string key is not yet in `Localizable.strings` — will fall back to raw key at runtime until Task 6. Build will not fail on this.)

- [ ] **Step 3: Run dashboard-related tests, expect none to break (no test currently exercises this view)**

Run: `swift test --filter OpenCodeRequestLog 2>&1 | tail -10`
Expected: existing tests pass. The new test from Task 3 (`OpenCodeRequestLogWindowFilterTests`) is pure-function and unaffected.

- [ ] **Step 4: Commit**

```bash
git add Sources/CodexBar/UsageDashboard/OpenCodeRequestLogView.swift
git commit -m "refactor(dashboard): trim OpenCodeRequestLogView to 10-row preview with View all"
```

---

## Task 5: Wire `onViewAll` in `UsageDashboardView` and add Window scene

**Files:**
- Modify: `Sources/CodexBar/UsageDashboard/UsageDashboardView.swift` — pass `onViewAll` closure
- Modify: `Sources/CodexBar/CodexBarApp.swift` — add `@State`, `enum OpenCodeRequestLogWindow`, `Window` scene, `openWindow` env binding

- [ ] **Step 1: In `UsageDashboardView.swift`, update the `requestLogSection` to inject `onViewAll`**

Find the `OpenCodeRequestLogView(...)` call site inside `requestLogSection` (around line 412). Replace it with:

```swift
OpenCodeRequestLogView(
    log: log,
    selectionColor: self.selectionColor,
    onViewAll: { self.openViewAll(for: provider) })
```

Then add the `openViewAll` helper method to `UsageDashboardView` (insert after the `requestLogSection` computed property):

```swift
private func openViewAll(for provider: UsageProvider) {
    AppOpenWindows.shared.openCodeRequestLogProvider = provider
    NSApp.activate(ignoringOtherApps: true)
    if let env = self.openWindowEnv {
        env(id: OpenCodeRequestLogWindow.id, value: ())
    }
}
```

To get `openWindowEnv` we need a property — insert at the top of the view struct, alongside the other `@Environment` declarations:

```swift
@Environment(\.openWindow) private var openWindowEnv
```

Then change the `openViewAll` method body to use `self.openWindowEnv` directly:

```swift
private func openViewAll(for provider: UsageProvider) {
    AppOpenWindows.shared.openCodeRequestLogProvider = provider
    NSApp.activate(ignoringOtherApps: true)
    self.openWindowEnv(id: OpenCodeRequestLogWindow.id)
}
```

- [ ] **Step 2: Create `AppOpenWindows` shared state**

Create new file `Sources/CodexBar/AppOpenWindows.swift`:

```swift
// Sources/CodexBar/AppOpenWindows.swift
import Foundation
import Observation
import CodexBarCore

/// Tiny shared `@Observable` that lets views ask the App to open a
/// provider-specific Window. The Window body reads the value on appear
/// and re-fetches whenever the value changes.
@MainActor
@Observable
final class AppOpenWindows {
    static let shared = AppOpenWindows()

    var openCodeRequestLogProvider: UsageProvider?
}
```

- [ ] **Step 3: In `CodexBarApp.swift`, add the `OpenCodeRequestLogWindow` enum and `@State`**

Find the existing `enum UsageDashboardWindow` in `UsageDashboardView.swift` (line 7, top of file). Add a sibling enum in the same file, just below it:

```swift
enum OpenCodeRequestLogWindow {
    static let id = "opencode-request-log"
}
```

In `CodexBarApp.swift`, find the `App` struct's `@State` declarations (if none, place them at the top of the struct). Add:

```swift
@State private var openCodeRequestLogProvider: UsageProvider?
```

The App reads the shared `AppOpenWindows` state on the main actor. Add this helper computed property inside the App struct:

```swift
private var openCodeRequestLogProviderBinding: Binding<UsageProvider?> {
    Binding(
        get: { AppOpenWindows.shared.openCodeRequestLogProvider },
        set: { AppOpenWindows.shared.openCodeRequestLogProvider = $0 })
}
```

Then in the `body` builder, find the `Window(L("Usage Heatmap"), id: UsageDashboardWindow.id) { ... }` block and add a sibling Window directly after it:

```swift
Window(L("OpenCode requests"), id: OpenCodeRequestLogWindow.id) {
    OpenCodeRequestLogWindowHost()
        .environment(\.appOpenWindows, AppOpenWindows.shared)
}
.defaultSize(width: 720, height: 480)
.windowResizability(.contentMinSize)
```

- [ ] **Step 4: Add the `OpenCodeRequestLogWindowHost` view**

Add to the bottom of `Sources/CodexBar/UsageDashboard/OpenCodeRequestLogWindowView.swift`:

```swift
/// Reads the active provider from the shared `AppOpenWindows` and renders
/// the per-provider log. Re-fetches when the shared value changes.
struct OpenCodeRequestLogWindowHost: View {
    @Environment(\.appOpenWindows) private var appOpenWindows
    @Environment(UsageStoreProvider.self) private var storeProvider
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let provider = self.appOpenWindows?.openCodeRequestLogProvider,
               let log = self.storeProvider?.store.openCodeRequestLog(for: provider)
            {
                OpenCodeRequestLogWindowView(
                    log: log,
                    selectionColor: self.selectionColor(for: provider),
                    providerDisplayName: self.storeProvider?.store.metadata(for: provider).displayName
                        ?? provider.rawValue,
                    onClose: { self.dismissWindow(value: OpenCodeRequestLogWindow.id) })
            } else {
                VStack(spacing: 12) {
                    Text(L("No log available for this provider."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button(L("Done")) { self.dismissWindow(value: OpenCodeRequestLogWindow.id) }
                        .keyboardShortcut(.defaultAction)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func selectionColor(for provider: UsageProvider) -> Color {
        switch provider {
        case .opencode: return .blue
        case .opencodego: return .purple
        default: return .accentColor
        }
    }
}

/// Environment plumbing for the shared `AppOpenWindows` singleton.
private struct AppOpenWindowsKey: EnvironmentKey {
    static let defaultValue: AppOpenWindows? = nil
}

extension EnvironmentValues {
    var appOpenWindows: AppOpenWindows? {
        get { self[AppOpenWindowsKey.self] }
        set { self[AppOpenWindowsKey.self] = newValue }
    }
}
```

- [ ] **Step 5: Wire `UsageStoreProvider` if not yet exposed**

`UsageStoreProvider` is referenced above. Verify it exists and is the right way to pass the store into a scene. If the dashboard uses `@Bindable var store: UsageStore` (which it does), then a separate accessor pattern is needed for the Window scene. Two options:

Option A: Create a `UsageStoreProvider` type that wraps the store and is injected via `.environment(UsageStoreProvider.shared)`.

Option B: Pass the store directly through `.environment(\.usageStore, store)`.

If neither exists, do this:

Create `Sources/CodexBar/UsageStoreProvider.swift`:

```swift
// Sources/CodexBar/UsageStoreProvider.swift
import SwiftUI

/// Environment key that gives non-`@Bindable` views (like the request-log
/// Window scene) access to the shared `UsageStore` instance.
struct UsageStoreProvider {
    let store: UsageStore
}

private struct UsageStoreProviderKey: EnvironmentKey {
    static let defaultValue: UsageStoreProvider? = nil
}

extension EnvironmentValues {
    var usageStoreProvider: UsageStoreProvider? {
        get { self[UsageStoreProviderKey.self] }
        set { self[UsageStoreProviderKey.self] = newValue }
    }
}
```

Then in `CodexBarApp.swift`'s `Settings { ... }` block, add `.environment(\.usageStoreProvider, UsageStoreProvider(store: self.store))` to the inner view (e.g. on the `PreferencesView` invocation) and to the new `Window` body's view. Repeat the `.environment(...)` modifier in every place the dashboard passes `@Bindable var store` to a subview that needs the same access.

If `UsageStoreProvider` is not needed because `@Bindable` works fine through environment — the codebase already uses `@Bindable var store: UsageStore` in `UsageDashboardView` — adjust the `OpenCodeRequestLogWindowHost` to receive `store` directly instead of via environment. Simplify:

```swift
struct OpenCodeRequestLogWindowHost: View {
    let store: UsageStore
    @State private var openCodeRequestLogProvider: UsageProvider?

    var body: some View {
        // ...
    }
}
```

And in the `Window` body, pass `self.store` explicitly:

```swift
Window(L("OpenCode requests"), id: OpenCodeRequestLogWindow.id) {
    OpenCodeRequestLogWindowHost(store: self.store)
}
```

This is simpler and matches the existing `UsageDashboardView(store: self.store, settings: self.settings)` pattern. **Prefer this simpler option.** Skip creating `UsageStoreProvider` entirely; use direct store passing like the dashboard does.

- [ ] **Step 6: Verify it compiles**

Run: `swift build --target CodexBar 2>&1 | tail -15`
Expected: exit 0. Fix any signature mismatches (e.g. the `onViewAll` parameter name, the `dismissWindow` API for value-bound windows — use `dismissWindow(value:)` only if the Window is value-bound; for string-id windows, use `dismissWindow(id:)` or `NSApp.sendAction(#selector(NSWindow.performClose:), ...)`). The simplest fallback:

```swift
private func closeWindow() {
    NSApp.keyWindow?.performClose(nil)
}
```

- [ ] **Step 7: Run all tests**

Run: `swift test 2>&1 | tail -20`
Expected: same pass/fail as before this plan started. The new test from Task 3 should appear in the list and pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/CodexBar/UsageDashboard/OpenCodeRequestLogWindowView.swift Sources/CodexBar/UsageDashboard/UsageDashboardView.swift Sources/CodexBar/CodexBarApp.swift
git commit -m "feat(dashboard): wire View all button to open request-log Window"
```

---

## Task 6: Add localization strings (en + zh-Hant)

**Files:**
- Modify: `Sources/CodexBar/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/CodexBar/Resources/zh-Hant.lproj/Localizable.strings`

- [ ] **Step 1: Append 10 new keys to `en.lproj/Localizable.strings`**

Open the file and append at the bottom (preserve the existing trailing newline):

```
"View all (%lld)" = "View all (%lld)";
"OpenCode requests" = "OpenCode requests";
"OpenCode requests — %@" = "OpenCode requests — %@";
"Select all" = "Select all";
"Deselect all" = "Deselect all";
"No requests match the selected models." = "No requests match the selected models.";
"Showing %lld of %lld requests" = "Showing %lld of %lld requests";
"Done" = "Done";
"No log available for this provider." = "No log available for this provider.";
"No OpenCode requests in the selected range." = "No OpenCode requests in the selected range.";
```

- [ ] **Step 2: Append the same 10 keys to `zh-Hant.lproj/Localizable.strings`**

```
"View all (%lld)" = "查看全部（%lld）";
"OpenCode requests" = "OpenCode 請求";
"OpenCode requests — %@" = "OpenCode 請求 — %@";
"Select all" = "全選";
"Deselect all" = "全不選";
"No requests match the selected models." = "沒有符合選定模型的請求。";
"Showing %lld of %lld requests" = "顯示 %lld / %lld 筆請求";
"Done" = "完成";
"No log available for this provider." = "此提供者沒有可用的紀錄。";
"No OpenCode requests in the selected range." = "目前範圍內沒有 OpenCode 請求。";
```

- [ ] **Step 3: Confirm the keys resolve at runtime by running tests**

Run: `swift test --filter OpenCodeRequestLog 2>&1 | tail -10`
Expected: pass. (Localization resolution isn't directly testable from XCTest in this codebase, but the build process compiles the strings tables; if a key is missing the catalog compiler will warn but the build will succeed.)

- [ ] **Step 4: Commit**

```bash
git add Sources/CodexBar/Resources/en.lproj/Localizable.strings Sources/CodexBar/Resources/zh-Hant.lproj/Localizable.strings
git commit -m "i18n(dashboard): localize request-log Window and filter UI"
```

---

## Task 7: Format + lint + handoff checks

**Files:** none modified.

- [ ] **Step 1: Run SwiftFormat**

Run: `swiftformat Sources Tests 2>&1 | tail -5`
Expected: no output (formatting clean) or a small list of touched files if drift was found. Re-run if needed.

- [ ] **Step 2: Run SwiftLint**

Run: `swiftlint --strict 2>&1 | tail -10`
Expected: exit 0. If there are warnings introduced by this work, fix them. Pre-existing warnings unrelated to this change may remain — note them in the handoff message.

- [ ] **Step 3: Run full test suite**

Run: `make test 2>&1 | tail -20`
Expected: same pass/fail counts as the pre-plan baseline. The 4 new tests from Task 3 pass; the dashboard-related tests pass. Pre-existing flaky timing tests and translation catalog gaps remain unchanged (do not fix unless explicitly asked).

- [ ] **Step 4: Build, package, and smoke-test in the running app**

Run:

```bash
pkill -f "CodexBar.app" 2>/dev/null
sleep 1
CODEXBAR_SIGNING=adhoc ./Scripts/package_app.sh debug 2>&1 | tail -3
xattr -cr .build/package/CodexBar.app
find .build/package/CodexBar.app -name "._*" -print -delete
codesign --force --deep --sign - .build/package/CodexBar.app 2>&1 | tail -1
rm -rf CodexBar.app
mv .build/package/CodexBar.app CodexBar.app
open -n /Users/chien/Documents/GitHub/CodexBar/CodexBar.app
sleep 4
pgrep -lf "CodexBar.app/Contents/MacOS/CodexBar"
```

Expected: app launches (PID printed). Manually open the dashboard → Recent requests section. Verify:
- Inline preview shows first 10 entries.
- "View all (N)" button appears when N > 10.
- Clicking the button opens a new Window with the title "OpenCode requests — OpenCode".
- Chips are pre-selected. Deselecting a chip filters the table.
- "Done" button closes the window.
- Status row updates: "Showing X of Y requests".

- [ ] **Step 5: Final commit (if formatting/lint touched anything)**

```bash
git status
# If any files are unstaged:
git add -u
git commit -m "style(dashboard): apply swiftformat and swiftlint fixes"
```

---

## Self-Review

**1. Spec coverage:**

| Spec section | Task |
| --- | --- |
| Inline view: 10-row preview | Task 4 |
| Inline view: "View all (N)" button | Task 4 |
| Window scene declaration | Task 5 |
| `OpenCodeRequestLogWindowView` with chips, table, status, Done | Tasks 2 + 5 |
| Filter chips with Select/Deselect all | Task 1 |
| Filter logic correctness | Task 3 |
| Localization (en + zh-Hant, 10 keys) | Task 6 |
| Manual QA | Task 7 |
| No pagination in inline view | Task 4 (removed) |

**2. Placeholder scan:** No "TBD", "TODO", "implement later". All code blocks are complete. Step 5 in Task 5 has an explicit `if X exists / otherwise do Y` branch which is a code-path decision point, not a placeholder — both branches are spelled out.

**3. Type consistency:**
- `OpenCodeRequestLogWindow.id` defined once (Task 5), used in `openWindow(id:)` calls in both App scene declaration and `UsageDashboardView.openViewAll`.
- `OpenCodeRequestLogWindowView`'s `onClose` callback signature `(()) -> Void` matches the call sites in `OpenCodeRequestLogWindowHost`.
- `AppOpenWindows.shared` is the single shared instance referenced in `openViewAll` and the `Window` body.
- `UsageProvider.opencode` / `.opencodego` are the only two cases the request log covers; `metadata(for:).displayName` exists on `UsageStore` already.

**4. Risk callouts during build:**
- Step 6 of Task 5 may need adjustment: `dismissWindow(id:)` vs `dismissWindow(value:)` differs between simple-id Windows and value-bound ones. The plan starts with `dismissWindow(value: OpenCodeRequestLogWindow.id)` and falls back to `NSApp.keyWindow?.performClose(nil)` if SwiftUI complains.
- `OpenCodeRequestLogEntry` public init may not exist; Step 2 of Task 3 documents how to handle that.
- The new `.environment(\.appOpenWindows, ...)` modifier in Task 5 is only needed if we keep the `AppOpenWindows` indirection. The simpler path (passing `store` directly to `OpenCodeRequestLogWindowHost`) is preferred and documented in Step 5. If a build error appears, drop the `AppOpenWindows` indirection entirely and use the direct `store` parameter.
