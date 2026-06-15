# Recent requests → modal window with model filter — Design

**Status:** approved
**Date:** 2026-06-15
**Owner:** qian403

## Problem

`OpenCodeRequestLogView` (Recent requests section in the OpenCode dashboard) currently renders all entries **inline** with a "Load more" button that appends 50 rows at a time. When a session has hundreds of requests the section grows past a screen, pushing the rest of the dashboard off-screen and forcing constant scrolling. There is no way to narrow the view by model — users have to read every row to find a particular model's traffic.

Goal: keep the dashboard compact and scannable, but give users a dedicated, resizable surface to inspect the full request list with at least one useful filter (model).

## Non-goals

- Re-pagination of the inline view (the inline view is now a fixed-size preview).
- Per-provider / per-token-account filtering (the Window is per-provider; we already only show one provider's log).
- Cost / token / date range / free-text filters (model is enough for v1; revisit if requested).
- Column-header sorting. Order is fixed: timestamp descending.
- Persisting the chip selection across sessions. Fresh window = fresh "all selected".
- Export from the Window. The dashboard-level "Export as CSV/JSON/usage" already covers the full log.
- Cross-provider aggregation. The Window is for one provider only.

## Constraints / context

- macOS 14+ target, SwiftUI, Swift 6.2 strict concurrency.
- The menu-bar app already has a SwiftUI `WindowGroup` ("Open Dashboard" / `CodexBarApp.openDashboard` path) — we can declare another `Window` scene in the same App file without infrastructure changes.
- The current view is `Sources/CodexBar/UsageDashboard/OpenCodeRequestLogView.swift` (187 lines) with a `@State var displayedCount` pagination, used inside `UsageDashboardView` for both `.opencode` and `.opencodego` providers.
- The log data type is `OpenCodeRequestLog` (an array of `OpenCodeRequestLogEntry` plus aggregate metrics) — already computed upstream of the view by `UsageStore.loadOpenCodeRequestLog(provider:)` and passed in by value.
- Filter chips: the dashboard already uses a chip pattern in `OpenCodeRequestLogView` `metricChip(title:value:)` and in `OpenCodeProviderCard` `ProviderIcon` headers, so the visual language is established.
- The Window needs an identifier that survives across opens for the "focus existing window on re-open" behavior. We use a value-typed `OpenCodeRequestLogRef` (provider + session-stable key) rather than a stringly-typed ID.

## User stories

1. **As a user with 200+ requests in a session**, the dashboard Recent-requests section stays roughly the height of a metric strip plus 10 rows. I never have to scroll past it to reach other dashboard sections.
2. **As a user who only cares about one model** (e.g. checking Opus spend), I click "View all", uncheck every chip except Opus, and the table snaps down to just Opus entries.
3. **As a user who wants to compare two models**, I uncheck all and re-check just those two, and the table shows only those.
4. **As a user**, the Window opens instantly, the table scrolls smoothly, the filter chips respond in <16ms (no jank on toggle).
5. **As a user who already has the Window open**, clicking "View all" again on the dashboard focuses the existing window instead of opening a duplicate.

## Architecture

### Inline view: compact preview

- `OpenCodeRequestLogView` loses its `@State displayedCount` and pagination.
- New constant `OpenCodeRequestLogView.previewCount = 10`.
- Renders: header (title + metric chips), table header, first 10 entries, then a single full-width "View all (N)" button when `entries.count > 10`.
- When `entries.count <= 10`: no button. The list just ends.
- Empty state unchanged (`No OpenCode requests in the selected range.`).
- The view is still a struct passed `log: OpenCodeRequestLog` and `selectionColor: Color`. It also gains a `onViewAll: () -> Void` closure so the parent decides how to open the Window — keeps the view decoupled from `openWindow`.

### Window scene

Add to `CodexBarApp.swift` (or equivalent App body):

```swift
WindowGroup("OpenCode requests", id: "opencode-request-log", for: OpenCodeRequestLogRef.self) { ref in
    OpenCodeRequestLogWindowView(ref: ref)
}
```

- The scene resolves the ref via `UsageStore` (synchronous lookup of `store.openCodeRequestLogs[ref.provider]`; the store already exposes this dictionary). If the lookup returns `nil` (provider disabled, session ended, ref stale), the Window shows an empty placeholder and a "Close" affordance rather than crashing.
- Re-opening with the same `OpenCodeRequestLogRef` focuses the existing window (SwiftUI built-in behavior for value-typed `WindowGroup` IDs).

### `OpenCodeRequestLogRef`

New type in `Sources/CodexBar/UsageDashboard/OpenCodeRequestLogRef.swift`:

```swift
struct OpenCodeRequestLogRef: Codable, Hashable, Sendable {
    let provider: UsageProvider   // .opencode or .opencodego
    let sessionKey: String        // stable per dashboard render; UID
}
```

- `UsageProvider` is the existing core enum (`Sources/CodexBarCore/Providers/Providers.swift`) — `String, CaseIterable, Sendable, Codable`. Use `.opencode` or `.opencodego`. Already used as the key for `UsageStore.openCodeRequestLogs: [UsageProvider: OpenCodeRequestLog]`.
- `sessionKey`: an ephemeral UUID generated when `UsageDashboardView` renders the inline view. Stable for that dashboard render. Re-renders produce a new key — this is fine because the inline "View all" button is recreated per render, and a new key simply opens a new window if the user really wants one.
- `Codable + Hashable` are required by SwiftUI's value-typed `WindowGroup` API.

### Window view: `OpenCodeRequestLogWindowView`

New file `Sources/CodexBar/UsageDashboard/OpenCodeRequestLogWindowView.swift`:

- Inputs: `ref: OpenCodeRequestLogRef`. Pulls `OpenCodeRequestLog?` from the shared `UsageStore` (synchronous lookup of `store.openCodeRequestLogs[ref.provider]`; the store already exposes this dictionary).
- State:
  - `@State private var selectedModels: Set<String>` — initialized to all unique model IDs in the log on first appear. Empty log → empty set, no crash.
  - `@State private var sortDescending: Bool = true` — fixed at true for v1 (timestamp desc); the field is reserved for future sort options but unused for now. Actually, remove it: we agreed no sort, so just sort once.
- Layout:
  - Top: title bar with `Text("OpenCode requests — \(provider.displayName)")` and (right-aligned) total entry count + filtered count.
  - Filter bar: `RequestLogFilterChips` showing one chip per unique model ID. Default all selected. "Select all" / "Deselect all" inline links on the right.
  - Table: same row layout as inline view, but takes the full window width. Single `ScrollView` with `LazyVStack` (avoids flattening the whole dataset into the view tree).
  - Bottom: status row `Showing \(filtered.count) of \(entries.count) requests` + a `Done` button that calls `@Environment(\.dismissWindow)`.
- Empty-filter state: when `selectedModels` is non-empty but the filter removes everything, show `Text(L("No requests match the selected models."))` in the table area; status row reads `Showing 0 of N requests`.
- Window dimensions: `.defaultSize(width: 720, height: 480)`, `.windowResizability(.contentMinSize)`.
- The chip filter applies **on the sorted full list**, not the inline preview. The two views are intentionally independent — the inline preview never filters.

### `RequestLogFilterChips`

New file `Sources/CodexBar/UsageDashboard/RequestLogFilterChips.swift`:

- Inputs: `models: [String]`, `selected: Set<String>`, `onToggle: (String) -> Void`, `onSelectAll: () -> Void`, `onDeselectAll: () -> Void`.
- Layout: `ScrollView(.horizontal, showsIndicators: false)` containing a `HStack` of toggle chips. Each chip is a `Button` with `.buttonStyle(.bordered)` whose tint changes based on selection. Display name goes through `UsageFormatter.modelDisplayName` (same as the table) so the chips match.
- "Select all" / "Deselect all" are small `Button(.borderless)` trailing the chip row.
- Chips wrap onto multiple lines if there are many models (use a `FlowLayout` from upstream if present, otherwise a simple `HStack` that truncates with horizontal scroll). For v1 we use horizontal scroll — model lists are typically < 10.

### Wiring the "View all" button

In `UsageDashboardView` (the parent of the inline `OpenCodeRequestLogView`):

```swift
@Environment(\.openWindow) private var openWindow
@State private var openCodeRequestLogRef = OpenCodeRequestLogRef(...)

OpenCodeRequestLogView(
    log: log,
    selectionColor: ...,
    onViewAll: {
        openWindow(id: "opencode-request-log", value: openCodeRequestLogRef)
    }
)
```

- The ref's `sessionKey` is `UUID().uuidString` on appear, kept in `@State`. Re-renders produce a new key; this is acceptable because the Window focusing behavior is best-effort, not strict.

## Data flow

```
UsageStore.loadOpenCodeRequestLog(provider:)
  → OpenCodeRequestLog (entries + aggregates)
  → passed to OpenCodeRequestLogView (inline preview, first 10)
  → on "View all": openWindow(value: OpenCodeRequestLogRef)
    → OpenCodeRequestLogWindowView resolves the log via UsageStore lookup
    → builds selectedModels set from unique model IDs
    → renders filter chips + ScrollView table
    → on chip toggle: selectedModels.insert/remove
    → table recomputes filteredEntries (Array.filter, sorted by timestamp desc)
```

No new persistence. No background refresh in the Window — if the user wants fresh data they re-open the dashboard, which re-triggers `loadOpenCodeRequestLog`.

## Errors / edge cases

| Case | Behavior |
| --- | --- |
| Empty log | Inline shows empty state. Button hidden. Window would never be opened. |
| `entries.count <= 10` | Inline shows all entries, no "View all" button. |
| User opens Window, then disables the provider in Preferences | Window stays open with whatever log it resolved; the lookup is one-shot. Status row still shows counts. Closing is the user's call. |
| Log ref points to a provider that no longer exists in `UsageStore` | Window shows `Text(L("No log available for this provider."))` and a Close button. No crash. |
| All chips deselected | Filter result is empty. Show "No requests match the selected models." in the table area, status row "Showing 0 of N". |
| Single model in log | Single chip. Behavior identical. |
| Model IDs are very long | Truncate with `lineLimit(1)` in the chip label, same as the table. |
| User opens Window multiple times with different `sessionKey` values | Multiple windows open. Acceptable — the user explicitly asked. |
| User re-clicks "View all" with same `sessionKey` | SwiftUI focuses the existing window. |

## i18n

New strings (en + zh-Hant, per AGENTS.md localization policy):

| English | 繁體中文 |
| --- | --- |
| `View all` | `查看全部` |
| `View all (%lld)` | `查看全部（%lld）` |
| `OpenCode requests` | `OpenCode 請求` |
| `OpenCode requests — %@` | `OpenCode 請求 — %@` |
| `Select all` | `全選` |
| `Deselect all` | `全不選` |
| `No requests match the selected models.` | `沒有符合選定模型的請求。` |
| `Showing %lld of %lld requests` | `顯示 %lld / %lld 筆請求` |
| `Done` | `完成` |
| `No log available for this provider.` | `此提供者沒有可用的紀錄。` |

Add to `Sources/CodexBar/Resources/en.lproj/Localizable.strings` and `Sources/CodexBar/Resources/zh-Hant.lproj/Localizable.strings`. Other locales fall back to en.

## Testing

Unit tests (XCTest under `Tests/CodexBarTests`):

- `OpenCodeRequestLogRefTests`:
  - Codable round-trip.
  - Hashable equality.
  - `OpenCodeProviderKind` value preserved through Codable.
- `OpenCodeRequestLogWindowFilterTests` (pure-function style, no SwiftUI):
  - Given `entries` of mixed models, toggling a chip in `selectedModels` returns the expected filtered subset.
  - Empty selection → empty result.
  - All selected → result equals full sorted-by-timestamp-desc list.

Snapshot test (if the existing test suite uses `swift-snapshot-testing` for SwiftUI views):

- `OpenCodeRequestLogWindowViewSnapshotTests`:
  - Mixed-model log → all chips selected, full list visible.
  - One model deselected → table reflects filter, status row updates.

Manual QA:

- Build, launch, open the dashboard, click "View all" → Window opens with all chips selected, 123 rows visible (or whatever count).
- Deselect all but Opus → table collapses to Opus-only, status row updates.
- Close window, re-click "View all" → new window opens (new `sessionKey`).
- Same `sessionKey` simulated by not re-rendering: re-clicking focuses the existing window.

Run `make test` and `make check` (format + lint) before handoff.

## Files to add / change

Add:

- `Sources/CodexBar/UsageDashboard/OpenCodeRequestLogWindowView.swift`
- `Sources/CodexBar/UsageDashboard/RequestLogFilterChips.swift`
- `Sources/CodexBar/UsageDashboard/OpenCodeRequestLogRef.swift`
- `Tests/CodexBarTests/OpenCodeRequestLogRefTests.swift`
- `Tests/CodexBarTests/OpenCodeRequestLogWindowFilterTests.swift`
- `docs/superpowers/plans/2026-06-15-recent-requests-window.md` (implementation plan, written by `writing-plans` skill)

Change:

- `Sources/CodexBar/UsageDashboard/OpenCodeRequestLogView.swift` — remove pagination, add `previewCount`, add `onViewAll` closure, swap "Load more" for "View all".
- `Sources/CodexBar/UsageDashboard/UsageDashboardView.swift` — wire `openWindow` to the new "View all" closure for the OpenCode and OpenCode Go cases.
- `Sources/CodexBar/CodexBarApp.swift` (or equivalent) — add the `WindowGroup` scene declaration.
- `Sources/CodexBar/Resources/en.lproj/Localizable.strings` — add new keys.
- `Sources/CodexBar/Resources/zh-Hant.lproj/Localizable.strings` — add new keys.

## Migration / compatibility

- `OpenCodeRequestLogView.init` gains a new optional `onViewAll` closure; existing call sites that don't pass it default to `nil` and render the "View all" button as disabled. The `UsageDashboardView` call site is updated to pass the closure.
- The `@State displayedCount` removal is internal to the view; no public API.
- `WindowGroup` is purely additive.
- No new dependencies.

## Out of scope (deferred)

- Date range filter.
- Cost / token / output token range filter.
- Free-text search across model + provider.
- Column-header click-to-sort.
- Per-row context menu (copy as JSON, open in Finder, etc.).
- Sticky chip selection across sessions.
- Persisting Window size / position.
- Multi-provider aggregation Window.
- Live refresh in the Window (today the dashboard re-fetches on appearance; the Window shows a snapshot).

## Open items (verify during build)

- Confirm `CodexBarApp.swift` is the right place to add the new `WindowGroup` (vs. a separate `Scenes` file). If the App file is too large, create `CodexBarApp+Scenes.swift` and extend the App body there.
- Confirm `UsageStore.openCodeRequestLogs` is reachable from the Window scene (likely needs the same DI pattern used by `CodexBarApp`; if not exposed publicly, add a thin `func log(for: UsageProvider) -> OpenCodeRequestLog?` accessor to `UsageStore`).
- Confirm `.windowResizability(.contentMinSize)` is available on macOS 14+ (it is, since 13.0).
- Confirm `swift-snapshot-testing` is in the test target; if not, skip the snapshot test and rely on manual QA + unit tests.
