import Foundation

/// One request (assistant message) recorded in OpenCode's `message` table.
/// Per-message granularity — different from `CostUsageDailyReport.Entry` which
/// is per-day, and from `OpenCodeCostUsageReader` which currently reads the
/// pre-aggregated `session` table.
public struct OpenCodeRequestLogEntry: Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let sessionId: String
    public let timestamp: Date
    public let modelId: String
    public let providerId: String?
    public let inputTokens: Int
    public let outputTokens: Int
    public let reasoningTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let costUSD: Double

    public var totalTokens: Int {
        self.inputTokens
            + self.outputTokens
            + self.reasoningTokens
            + self.cacheReadTokens
            + self.cacheWriteTokens
    }

    public init(
        id: String,
        sessionId: String,
        timestamp: Date,
        modelId: String,
        providerId: String?,
        inputTokens: Int,
        outputTokens: Int,
        reasoningTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        costUSD: Double)
    {
        self.id = id
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.modelId = modelId
        self.providerId = providerId
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.costUSD = costUSD
    }
}

/// Aggregated view of `OpenCodeRequestLogEntry` over a date range. Mirrors the
/// per-day shape of `CostUsageDailyReport` so the dashboard can render either
/// interchangeably while still letting the call site pass the per-message list
/// through.
public struct OpenCodeRequestLog: Sendable, Equatable {
    public let entries: [OpenCodeRequestLogEntry]
    public let rangeStart: Date
    public let rangeEnd: Date

    public init(entries: [OpenCodeRequestLogEntry], rangeStart: Date, rangeEnd: Date) {
        self.entries = entries
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
    }

    public var isEmpty: Bool {
        self.entries.isEmpty
    }

    public var totalRequests: Int {
        self.entries.count
    }

    public var totalTokens: Int {
        self.entries.reduce(0) { $0 + $1.totalTokens }
    }

    public var totalCostUSD: Double {
        self.entries.reduce(0.0) { $0 + $1.costUSD }
    }

    public var totalInputTokens: Int {
        self.entries.reduce(0) { $0 + $1.inputTokens }
    }

    public var totalOutputTokens: Int {
        self.entries.reduce(0) { $0 + $1.outputTokens }
    }

    public var totalCacheReadTokens: Int {
        self.entries.reduce(0) { $0 + $1.cacheReadTokens }
    }

    public var totalCacheCreationTokens: Int {
        self.entries.reduce(0) { $0 + $1.cacheWriteTokens }
    }

    /// Total input tokens including cache reads — used for "fresh input" math
    /// the same way `ccswitch` surfaces it.
    public var freshInputTokens: Int {
        self.totalInputTokens
    }

    /// Cache hit rate: cacheRead / (cacheRead + input). Returns 0 when neither
    /// side has data.
    public var cacheHitRate: Double {
        let denominator = Double(self.totalCacheReadTokens + self.totalInputTokens)
        guard denominator > 0 else { return 0 }
        return Double(self.totalCacheReadTokens) / denominator
    }
}
