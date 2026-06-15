import Foundation

/// On-disk cache for `OpenCodeCostUsageReader` so the dashboard can skip the
/// SQLite scan when `opencode.db` (or its `-wal` file) hasn't changed since
/// the last read.
///
/// Serialization is done via `JSONSerialization` against a private JSON shape
/// (see `OpenCodeReadCacheIO.encode` / `decode`) rather than `Codable` to
/// avoid leaking a new public `Encodable` requirement onto
/// `CostUsageDailyReport` and its nested types. The on-disk schema is
/// internal and may evolve as long as the `currentVersion` field is bumped.
public struct OpenCodeReadCache: Sendable {
    static let currentVersion = 1

    /// Schema version. Bumped if the encoded shape changes; older caches are
    /// silently discarded instead of crashing on decode mismatch.
    var version: Int
    /// Resolved `opencode.db` path at the time of the last read. A different
    /// path on the next read means a different database, so the cache is
    /// discarded even if the mtime is unchanged.
    public var databasePath: String
    /// `max(opencode.db.mtime, opencode.db-wal.mtime)` at the time of the last
    /// successful read. Compared against the current mtime to decide whether
    /// a re-scan is needed.
    var lastModified: TimeInterval
    /// Full daily report (no `since` / `until` applied). Callers filter the
    /// entries to their requested range so the cache is range-agnostic.
    public var dailyReport: CostUsageDailyReport
    /// Full request log (no `since` / `until` or `maxEntries` applied), sorted
    /// newest first. Capped at `OpenCodeReadCacheIO.cachedRequestLogCap` to
    /// keep the file size bounded; callers slice further.
    public var requestLog: OpenCodeRequestLog

    init(
        version: Int = OpenCodeReadCache.currentVersion,
        databasePath: String,
        lastModified: TimeInterval,
        dailyReport: CostUsageDailyReport,
        requestLog: OpenCodeRequestLog)
    {
        self.version = version
        self.databasePath = databasePath
        self.lastModified = lastModified
        self.dailyReport = dailyReport
        self.requestLog = requestLog
    }

    /// `true` when the cache's mtime is at least as recent as the current
    /// mtime for `databasePath`. A cache that's older than the file is
    /// treated as a miss.
    func covers(mtime: TimeInterval) -> Bool {
        self.lastModified >= mtime
    }
}

/// File I/O for `OpenCodeReadCache`. Patterned after `PiSessionCostCacheIO`:
/// static `cacheFileURL`, `load`, and `save` methods. All writes are atomic
/// (temp file + rename) so a crash mid-write can't leave a half-encoded
/// cache behind. Uses `JSONSerialization` with a private JSON shape to
/// avoid forcing `Encodable` onto `CostUsageDailyReport`.
public enum OpenCodeReadCacheIO {
    /// Upper bound on how many request entries we serialize to disk. Real
    /// installations will have far fewer — 5,000 is a safety cap to keep the
    /// JSON file under a few MB even on heavy use.
    public static let cachedRequestLogCap = 5000

    public static func cacheFileURL(cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot ?? Self.defaultCacheRoot()
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("opencode-v\(OpenCodeReadCache.currentVersion).json", isDirectory: false)
    }

    private static func defaultCacheRoot() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("CodexBar", isDirectory: true)
    }

    /// Returns the cached entry if it exists, decodes cleanly, and matches
    /// the current schema version. Returns `nil` for missing file, decode
    /// failure, or version mismatch — the caller falls through to a fresh
    /// scan.
    public static func load(cacheRoot: URL? = nil) -> OpenCodeReadCache? {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dictionary = object as? [String: Any]
        else {
            return nil
        }
        return Self.decode(from: dictionary)
    }

    /// Writes the cache atomically. Creates intermediate directories as
    /// needed. Errors are swallowed because the cache is a performance
    /// optimization, not a source of truth — a write failure just means the
    /// next read does a full scan.
    public static func save(_ cache: OpenCodeReadCache, cacheRoot: URL? = nil) {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let dictionary = Self.encode(cache)
        guard JSONSerialization.isValidJSONObject(dictionary),
              let data = try? JSONSerialization.data(
                  withJSONObject: dictionary,
                  options: [.prettyPrinted, .sortedKeys])
        else { return }

        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).json", isDirectory: false)
        do {
            try data.write(to: tmp, options: [.atomic])
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    // MARK: - Private JSON shape

    private enum Key {
        static let version = "v"
        static let databasePath = "db"
        static let lastModified = "mtime"
        static let daily = "daily"
        static let requestLog = "reqlog"
        static let entries = "entries"
        static let rangeStart = "rs"
        static let rangeEnd = "re"
    }

    private enum EntryKey {
        static let id = "id"
        static let sessionId = "sid"
        static let timestamp = "ts"
        static let modelId = "mid"
        static let providerId = "pid"
        static let inputTokens = "in"
        static let outputTokens = "out"
        static let reasoningTokens = "rsn"
        static let cacheReadTokens = "cr"
        static let cacheWriteTokens = "cw"
        static let costUSD = "cost"
    }

    private static func encode(_ cache: OpenCodeReadCache) -> [String: Any] {
        [
            Key.version: cache.version,
            Key.databasePath: cache.databasePath,
            Key.lastModified: cache.lastModified,
            Key.daily: self.encodeDailyReport(cache.dailyReport),
            Key.requestLog: self.encodeRequestLog(cache.requestLog),
        ]
    }

    private static func decode(from dict: [String: Any]) -> OpenCodeReadCache? {
        guard let version = dict[Key.version] as? Int,
              version == OpenCodeReadCache.currentVersion,
              let databasePath = dict[Key.databasePath] as? String,
              let lastModified = dict[Key.lastModified] as? Double
        else { return nil }
        let dailyReport = (dict[Key.daily] as? [String: Any])
            .flatMap(Self.decodeDailyReport) ?? CostUsageDailyReport(data: [], summary: nil)
        let requestLog = (dict[Key.requestLog] as? [String: Any])
            .flatMap(Self.decodeRequestLog) ?? OpenCodeRequestLog(
                entries: [],
                rangeStart: .distantPast,
                rangeEnd: .distantFuture)
        return OpenCodeReadCache(
            version: version,
            databasePath: databasePath,
            lastModified: lastModified,
            dailyReport: dailyReport,
            requestLog: requestLog)
    }

    private static func encodeDailyReport(_ report: CostUsageDailyReport) -> [String: Any] {
        // Mirrors `CostUsageDailyReport.init(from:)`'s modern decoded shape so
        // the on-disk JSON is a plain `{ type: "daily", data: [...], summary: {...} }`
        // object that `CostUsageDailyReport`'s own decoder understands
        // directly. The `type` discriminator is required to pick the modern
        // path over the legacy `daily`/`totals` shape; without it the
        // decoder throws because the `data` key isn't recognized.
        var dict: [String: Any] = [
            "type": "daily",
            "data": report.data.map(Self.encodeDailyEntry),
        ]
        if let summary = report.summary {
            dict["summary"] = Self.encodeDailySummary(summary)
        }
        return dict
    }

    private static func decodeDailyReport(from dict: [String: Any]) -> CostUsageDailyReport? {
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict, options: [])
        else { return nil }
        return try? JSONDecoder().decode(CostUsageDailyReport.self, from: data)
    }

    private static func encodeDailyEntry(_ entry: CostUsageDailyReport.Entry) -> [String: Any] {
        var dict: [String: Any] = ["date": entry.date]
        if let input = entry.inputTokens { dict["inputTokens"] = input }
        if let output = entry.outputTokens { dict["outputTokens"] = output }
        if let cacheRead = entry.cacheReadTokens { dict["cacheReadTokens"] = cacheRead }
        if let cacheWrite = entry.cacheCreationTokens { dict["cacheCreationTokens"] = cacheWrite }
        if let total = entry.totalTokens { dict["totalTokens"] = total }
        if let requests = entry.requestCount { dict["requestCount"] = requests }
        if let cost = entry.costUSD { dict["costUSD"] = cost }
        if let models = entry.modelsUsed { dict["modelsUsed"] = models }
        if let breakdowns = entry.modelBreakdowns {
            dict["modelBreakdowns"] = breakdowns.map(Self.encodeModelBreakdown)
        }
        return dict
    }

    private static func encodeModelBreakdown(
        _ breakdown: CostUsageDailyReport.ModelBreakdown) -> [String: Any]
    {
        var dict: [String: Any] = ["modelName": breakdown.modelName]
        if let cost = breakdown.costUSD { dict["costUSD"] = cost }
        if let total = breakdown.totalTokens { dict["totalTokens"] = total }
        if let requests = breakdown.requestCount { dict["requestCount"] = requests }
        if let standard = breakdown.standardCostUSD { dict["standardCostUSD"] = standard }
        if let priority = breakdown.priorityCostUSD { dict["priorityCostUSD"] = priority }
        if let standard = breakdown.standardTokens { dict["standardTokens"] = standard }
        if let priority = breakdown.priorityTokens { dict["priorityTokens"] = priority }
        return dict
    }

    private static func encodeDailySummary(
        _ summary: CostUsageDailyReport.Summary) -> [String: Any]
    {
        var dict: [String: Any] = [:]
        if let input = summary.totalInputTokens { dict["totalInputTokens"] = input }
        if let output = summary.totalOutputTokens { dict["totalOutputTokens"] = output }
        if let cacheRead = summary.cacheReadTokens { dict["cacheReadTokens"] = cacheRead }
        if let cacheWrite = summary.cacheCreationTokens { dict["cacheCreationTokens"] = cacheWrite }
        if let total = summary.totalTokens { dict["totalTokens"] = total }
        if let cost = summary.totalCostUSD { dict["totalCostUSD"] = cost }
        return dict
    }

    private static func encodeRequestLog(_ log: OpenCodeRequestLog) -> [String: Any] {
        [
            Key.rangeStart: log.rangeStart.timeIntervalSince1970,
            Key.rangeEnd: log.rangeEnd.timeIntervalSince1970,
            Key.entries: log.entries.map(self.encodeEntry),
        ]
    }

    private static func decodeRequestLog(from dict: [String: Any]) -> OpenCodeRequestLog? {
        guard let entriesRaw = dict[Key.entries] as? [[String: Any]] else { return nil }
        let entries = entriesRaw.compactMap(Self.decodeEntry)
        let rangeStart = (dict[Key.rangeStart] as? Double).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
        let rangeEnd = (dict[Key.rangeEnd] as? Double).map { Date(timeIntervalSince1970: $0) } ?? .distantFuture
        return OpenCodeRequestLog(
            entries: entries,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd)
    }

    private static func encodeEntry(_ entry: OpenCodeRequestLogEntry) -> [String: Any] {
        var dict: [String: Any] = [
            EntryKey.id: entry.id,
            EntryKey.sessionId: entry.sessionId,
            EntryKey.timestamp: entry.timestamp.timeIntervalSince1970,
            EntryKey.modelId: entry.modelId,
            EntryKey.inputTokens: entry.inputTokens,
            EntryKey.outputTokens: entry.outputTokens,
            EntryKey.reasoningTokens: entry.reasoningTokens,
            EntryKey.cacheReadTokens: entry.cacheReadTokens,
            EntryKey.cacheWriteTokens: entry.cacheWriteTokens,
            EntryKey.costUSD: entry.costUSD,
        ]
        if let provider = entry.providerId { dict[EntryKey.providerId] = provider }
        return dict
    }

    private static func decodeEntry(from dict: [String: Any]) -> OpenCodeRequestLogEntry? {
        guard let id = dict[EntryKey.id] as? String,
              let sessionId = dict[EntryKey.sessionId] as? String,
              let timestampSeconds = dict[EntryKey.timestamp] as? Double,
              let modelId = dict[EntryKey.modelId] as? String,
              let inputTokens = dict[EntryKey.inputTokens] as? Int,
              let outputTokens = dict[EntryKey.outputTokens] as? Int,
              let reasoningTokens = dict[EntryKey.reasoningTokens] as? Int,
              let cacheReadTokens = dict[EntryKey.cacheReadTokens] as? Int,
              let cacheWriteTokens = dict[EntryKey.cacheWriteTokens] as? Int,
              let costUSD = dict[EntryKey.costUSD] as? Double
        else { return nil }
        return OpenCodeRequestLogEntry(
            id: id,
            sessionId: sessionId,
            timestamp: Date(timeIntervalSince1970: timestampSeconds),
            modelId: modelId,
            providerId: dict[EntryKey.providerId] as? String,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            costUSD: costUSD)
    }
}
