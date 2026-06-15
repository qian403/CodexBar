import CodexBarCore
import SwiftUI

/// Per-request log for OpenCode (and OpenCode Go). Renders a compact table
/// mirroring the ccswitch `RequestLogTable`: timestamp, model, input / output
/// / cache read+write, and cost. Pagination defaults to 50 rows so the
/// dashboard stays scannable.
struct OpenCodeRequestLogView: View {
    let log: OpenCodeRequestLog
    let selectionColor: Color
    let pageSize: Int

    @State private var displayedCount: Int

    init(log: OpenCodeRequestLog, selectionColor: Color, pageSize: Int = 50) {
        self.log = log
        self.selectionColor = selectionColor
        self.pageSize = pageSize
        self._displayedCount = State(initialValue: min(pageSize, log.entries.count))
    }

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
                ForEach(self.visibleEntries) { entry in
                    self.row(for: entry)
                    Divider()
                }
                if self.hasMore {
                    Button {
                        self.displayedCount = min(
                            self.displayedCount + self.pageSize,
                            self.log.entries.count)
                    } label: {
                        HStack(spacing: 4) {
                            Text(L("Load more"))
                            Text("(\(self.log.entries.count - self.displayedCount) more)")
                                .foregroundStyle(.secondary)
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

    private var visibleEntries: [OpenCodeRequestLogEntry] {
        Array(self.log.entries.prefix(self.displayedCount))
    }

    private var hasMore: Bool {
        self.displayedCount < self.log.entries.count
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
