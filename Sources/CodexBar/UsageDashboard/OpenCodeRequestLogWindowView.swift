import AppKit
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
            Text(L("OpenCode requests — %@", self.providerDisplayName))
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
            Text(L(
                "Showing %lld of %lld requests",
                self.filteredEntries.count,
                self.log.entries.count))
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
        for entry in self.log.entries where !seen.contains(entry.modelId) {
            seen.insert(entry.modelId)
            ordered.append(entry.modelId)
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

/// Reads the active provider from the shared `AppOpenWindows` and renders
/// the per-provider log. Re-fetches when the shared value changes.
struct OpenCodeRequestLogWindowHost: View {
    let store: UsageStore

    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        let provider = AppOpenWindows.shared.openCodeRequestLogProvider
        Group {
            if let provider, let log = self.store.openCodeRequestLog(for: provider) {
                OpenCodeRequestLogWindowView(
                    log: log,
                    selectionColor: self.selectionColor(for: provider),
                    providerDisplayName: self.store.metadata(for: provider).displayName,
                    onClose: { self.closeWindow() })
            } else {
                VStack(spacing: 12) {
                    Text(L("No log available for this provider."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button(L("Done")) { self.closeWindow() }
                        .keyboardShortcut(.defaultAction)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: provider) {
            await self.loadLogIfNeeded(for: provider)
        }
    }

    private func selectionColor(for provider: UsageProvider) -> Color {
        ProviderDescriptorRegistry.descriptor(for: provider).branding.color.swiftUIColor
    }

    private func loadLogIfNeeded(for provider: UsageProvider?) async {
        guard let provider, provider == .opencode || provider == .opencodego else { return }
        if self.store.openCodeRequestLog(for: provider) == nil {
            await self.store.loadOpenCodeRequestLog(for: provider, rangeWeeks: 13)
        }
    }

    private func closeWindow() {
        AppOpenWindows.shared.openCodeRequestLogProvider = nil
        self.dismissWindow(id: OpenCodeRequestLogWindow.id)
    }
}

extension Set<String> {
    fileprivate mutating func toggle(_ element: String) {
        if self.contains(element) {
            self.remove(element)
        } else {
            self.insert(element)
        }
    }
}
