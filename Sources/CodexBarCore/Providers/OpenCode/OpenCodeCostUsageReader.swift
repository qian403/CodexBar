import Foundation
import SQLite3

/// Reads OpenCode's local SQLite store (`opencode.db`) and produces both a
/// daily token/cost report (for the heatmap) and a per-request log (for the
/// dashboard's recent activity section). OpenCode records assistant message
/// details in the `message` table as JSON; this reader mirrors the approach
/// used by [cc-switch's `session_usage_opencode.rs`](https://github.com/farion1231/cc-switch)
/// so the data is accurate, filters out incomplete messages, and survives
/// schema additions without code changes.
public enum OpenCodeCostUsageReader {
    /// Resolves the on-disk database path, honoring `XDG_DATA_HOME` and falling
    /// back to `~/.local/share/opencode/opencode.db`.
    public static func databaseURL(environment: [String: String]) -> URL {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let dataHome = if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".local/share", isDirectory: true)
        }
        return dataHome
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("opencode.db", isDirectory: false)
    }

    /// Parsed view of one row from OpenCode's `message` table. Skips rows that
    /// are not assistant messages, have no token data, or have not finished
    /// (`time.completed` missing). The model is derived from `data.modelID`
    /// (or `data.model.id` for older shapes) and the provider is
    /// `data.providerID` when present.
    public struct MessageData {
        public let sessionId: String
        public let createdMs: Int64
        public let modelId: String
        public let providerId: String?
        public let inputTokens: Int
        public let outputTokens: Int
        public let reasoningTokens: Int
        public let cacheReadTokens: Int
        public let cacheWriteTokens: Int
        public let cost: Double

        public init(
            sessionId: String,
            createdMs: Int64,
            modelId: String,
            providerId: String?,
            inputTokens: Int,
            outputTokens: Int,
            reasoningTokens: Int,
            cacheReadTokens: Int,
            cacheWriteTokens: Int,
            cost: Double)
        {
            self.sessionId = sessionId
            self.createdMs = createdMs
            self.modelId = modelId
            self.providerId = providerId
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.reasoningTokens = reasoningTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.cost = cost
        }

        var totalTokens: Int {
            self.inputTokens
                + self.outputTokens
                + self.reasoningTokens
                + self.cacheReadTokens
                + self.cacheWriteTokens
        }

        var isEmpty: Bool {
            self.totalTokens == 0 && self.cost == 0
        }
    }

    /// Reads the OpenCode DB and emits a per-day `CostUsageDailyReport` for the
    /// given window. Output is identical in shape to the Codex/Claude/Bedrock
    /// readers, so the rest of the dashboard pipeline treats OpenCode like any
    /// other extended-history provider.
    ///
    /// Reads go through an on-disk cache (`OpenCodeReadCacheIO`) so the SQLite
    /// scan is skipped when `opencode.db` (and its `-wal`) haven't changed
    /// since the last read.
    public static func loadDailyReport(
        since: Date,
        until: Date,
        now: Date = Date(),
        cacheRoot: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> CostUsageDailyReport
    {
        let cached = self.loadOrScanCache(environment: environment, now: now, cacheRoot: cacheRoot)
        return self.filterDailyReport(cached.dailyReport, since: since, until: until)
    }

    /// Reads the OpenCode DB and emits per-request log entries for the given
    /// window. The window is bounded by `until` only on the upper side; pass
    /// `maxEntries` to cap the result (newest entries first) so the dashboard
    /// doesn't render tens of thousands of rows. Skips a SQLite scan when the
    /// cache is still fresh.
    public static func loadRequestLog(
        since: Date,
        until: Date,
        maxEntries: Int = 500,
        cacheRoot: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> OpenCodeRequestLog
    {
        let cached = self.loadOrScanCache(environment: environment, now: Date(), cacheRoot: cacheRoot)
        return self.filterRequestLog(
            cached.requestLog,
            since: since,
            until: until,
            maxEntries: maxEntries)
    }

    // MARK: - Cache-aware core

    /// Returns a fresh or cached `OpenCodeReadCache`. The cache is keyed on
    /// the resolved DB path plus `max(db mtime, db-wal mtime)` — when both
    /// match the cache on disk, no SQLite scan happens. If the DB file is
    /// missing but the cache is present and keyed to the same path, the
    /// cache is returned as a best-effort fallback (handy for tests and
    /// transient missing-file races).
    private static func loadOrScanCache(
        environment: [String: String],
        now: Date,
        cacheRoot: URL?) -> OpenCodeReadCache
    {
        let url = self.databaseURL(environment: environment)

        if let cached = OpenCodeReadCacheIO.load(cacheRoot: cacheRoot),
           cached.databasePath == url.path,
           let resolvedMtime = self.currentMtime(for: url),
           cached.covers(mtime: resolvedMtime)
        {
            return cached
        }

        // Either no cache, stale cache, or the DB file is gone. If the DB
        // is unreachable, prefer an existing cache over writing an empty
        // one — a missing DB doesn't mean the user's history is gone, it
        // just means we can't refresh right now.
        let dbMtime = self.currentMtime(for: url)
        if dbMtime == nil,
           let cached = OpenCodeReadCacheIO.load(cacheRoot: cacheRoot),
           cached.databasePath == url.path
        {
            return cached
        }

        // Full scan + persist. If the scan returns zero rows AND there's no
        // existing cache, don't write a useless empty file — just return a
        // sentinel so callers can render the empty state without disk churn.
        let messages = self.openAndLoadAllMessages(at: url)
        if messages.isEmpty, OpenCodeReadCacheIO.load(cacheRoot: cacheRoot) == nil {
            return OpenCodeReadCache(
                databasePath: url.path,
                lastModified: 0,
                dailyReport: CostUsageDailyReport(data: [], summary: nil),
                requestLog: OpenCodeRequestLog(entries: [], rangeStart: .distantPast, rangeEnd: .distantFuture))
        }

        let resolvedMtime = dbMtime ?? 0
        let daily = self.aggregateDaily(messages: messages)
        let requestLog = self.buildRequestLog(
            messages: messages,
            cap: OpenCodeReadCacheIO.cachedRequestLogCap,
            rangeStart: .distantPast,
            rangeEnd: .distantFuture)
        let newCache = OpenCodeReadCache(
            databasePath: url.path,
            lastModified: resolvedMtime,
            dailyReport: daily,
            requestLog: requestLog)
        OpenCodeReadCacheIO.save(newCache, cacheRoot: cacheRoot)
        return newCache
    }

    /// `max(opencode.db.mtime, opencode.db-wal.mtime)`. Returns nil if the DB
    /// doesn't exist (caller treats that as "no data").
    private static func currentMtime(for dbURL: URL) -> TimeInterval? {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return nil }
        let dbMtime = self.mtime(of: dbURL) ?? 0
        let walMtime = self.walURL(for: dbURL).flatMap { self.mtime(of: $0) } ?? 0
        return max(dbMtime, walMtime)
    }

    private static func walURL(for dbURL: URL) -> URL? {
        // `opencode.db-wal` lives next to the main file with the suffix
        // swapped. We probe rather than assuming it exists.
        let dir = dbURL.deletingLastPathComponent()
        return dir.appendingPathComponent("\(dbURL.lastPathComponent)-wal")
    }

    private static func mtime(of url: URL) -> TimeInterval? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970
    }

    /// Opens the SQLite DB read-only and returns every completed assistant
    /// message in chronological order. This is the slow path — only invoked
    /// on cache miss.
    private static func openAndLoadAllMessages(at dbURL: URL) -> [MessageData] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        return self.loadMessages(db: db)
    }

    /// Applies the requested date window to a cached full daily report. The
    /// cache stores the unfiltered set so the same scan serves every range
    /// the dashboard might ask for.
    private static func filterDailyReport(
        _ report: CostUsageDailyReport,
        since: Date,
        until: Date) -> CostUsageDailyReport
    {
        let sinceString = Self.dateString(from: since)
        let untilString = Self.dateString(from: until)
        let filtered = report.data.filter { $0.date >= sinceString && $0.date <= untilString }
        guard !filtered.isEmpty else { return CostUsageDailyReport(data: [], summary: nil) }
        // Recompute summary from the filtered entries so callers see totals
        // for the requested window, not the cached totals over all dates.
        let summary = Self.summaryForFilteredEntries(filtered)
        return CostUsageDailyReport(data: filtered, summary: summary)
    }

    private static func filterRequestLog(
        _ log: OpenCodeRequestLog,
        since: Date,
        until: Date,
        maxEntries: Int) -> OpenCodeRequestLog
    {
        let filtered = log.entries.filter { $0.timestamp >= since && $0.timestamp <= until }
        let capped = Array(filtered.prefix(maxEntries))
        return OpenCodeRequestLog(entries: capped, rangeStart: since, rangeEnd: until)
    }

    private static func dateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Aggregates a flat list of messages into a per-day
    /// `CostUsageDailyReport`. Mirrors the old inline aggregation logic.
    private static func aggregateDaily(messages: [MessageData]) -> CostUsageDailyReport {
        let formatter = Self.dayFormatter()
        var byDay: [String: DayAcc] = [:]

        for message in messages {
            let day = formatter.string(from: Date(timeIntervalSince1970: Double(message.createdMs) / 1000))
            var acc = byDay[day] ?? DayAcc()
            acc.input += message.inputTokens
            acc.output += message.outputTokens
            acc.reasoning += message.reasoningTokens
            acc.cacheRead += message.cacheReadTokens
            acc.cacheWrite += message.cacheWriteTokens
            acc.cost += message.cost
            // Each finished assistant message counts as one request — same
            // granularity ccswitch uses for its request log.
            acc.requests += 1
            let modelTotal = message.totalTokens
            var modelAcc = acc.models[message.modelId] ?? ModelAcc()
            modelAcc.tokens += modelTotal
            modelAcc.cost += message.cost
            acc.models[message.modelId] = modelAcc
            acc.modelsUsed.insert(message.modelId)
            byDay[day] = acc
        }

        let entries = byDay
            .map { day, acc -> CostUsageDailyReport.Entry in
                let totalInput = acc.input + acc.reasoning
                let total = acc.input
                    + acc.output
                    + acc.reasoning
                    + acc.cacheRead
                    + acc.cacheWrite
                return CostUsageDailyReport.Entry(
                    date: day,
                    inputTokens: totalInput > 0 ? totalInput : nil,
                    outputTokens: acc.output > 0 ? acc.output : nil,
                    cacheReadTokens: acc.cacheRead > 0 ? acc.cacheRead : nil,
                    cacheCreationTokens: acc.cacheWrite > 0 ? acc.cacheWrite : nil,
                    totalTokens: total > 0 ? total : nil,
                    requestCount: acc.requests,
                    costUSD: acc.cost > 0 ? acc.cost : nil,
                    modelsUsed: Array(acc.modelsUsed).sorted(),
                    modelBreakdowns: acc.models
                        .map { name, value in
                            CostUsageDailyReport.ModelBreakdown(
                                modelName: name,
                                costUSD: value.cost > 0 ? value.cost : nil,
                                totalTokens: value.tokens > 0 ? value.tokens : nil)
                        }
                        .sorted { ($0.totalTokens ?? 0) > ($1.totalTokens ?? 0) })
            }
            .sorted { $0.date < $1.date }

        let summary = Self.summaryForFilteredEntries(entries)
        return CostUsageDailyReport(data: entries, summary: summary)
    }

    /// Builds the cached request log (full data, no range filter, sorted
    /// newest first, capped). The cache stores the unfiltered set so the same
    /// scan serves every range the dashboard might ask for.
    private static func buildRequestLog(
        messages: [MessageData],
        cap: Int,
        rangeStart: Date,
        rangeEnd: Date) -> OpenCodeRequestLog
    {
        let sorted = messages.sorted { $0.createdMs > $1.createdMs }
        let capped = Array(sorted.prefix(cap))
        let entries = capped.map { Self.entry(from: $0) }
        return OpenCodeRequestLog(entries: entries, rangeStart: rangeStart, rangeEnd: rangeEnd)
    }

    /// Recomputes the summary block from already-aggregated daily entries so
    /// it matches the filtered window returned to callers.
    private static func summaryForFilteredEntries(
        _ entries: [CostUsageDailyReport.Entry]) -> CostUsageDailyReport.Summary?
    {
        let totalTokens = entries.reduce(0) { $0 + ($1.totalTokens ?? 0) }
        let totalInput = entries.reduce(0) { $0 + ($1.inputTokens ?? 0) }
        let totalOutput = entries.reduce(0) { $0 + ($1.outputTokens ?? 0) }
        let totalCacheRead = entries.reduce(0) { $0 + ($1.cacheReadTokens ?? 0) }
        let totalCacheWrite = entries.reduce(0) { $0 + ($1.cacheCreationTokens ?? 0) }
        let totalCost = entries.reduce(0.0) { $0 + ($1.costUSD ?? 0) }
        guard totalTokens > 0
            || totalInput > 0
            || totalOutput > 0
            || totalCacheRead > 0
            || totalCacheWrite > 0
            || totalCost > 0
        else { return nil }
        return CostUsageDailyReport.Summary(
            totalInputTokens: totalInput > 0 ? totalInput : nil,
            totalOutputTokens: totalOutput > 0 ? totalOutput : nil,
            cacheReadTokens: totalCacheRead > 0 ? totalCacheRead : nil,
            cacheCreationTokens: totalCacheWrite > 0 ? totalCacheWrite : nil,
            totalTokens: totalTokens > 0 ? totalTokens : nil,
            totalCostUSD: totalCost > 0 ? totalCost : nil)
    }

    // MARK: - Internal

    private struct ModelAcc { var tokens = 0; var cost = 0.0 }
    private struct DayAcc {
        var input = 0
        var output = 0
        var reasoning = 0
        var cacheRead = 0
        var cacheWrite = 0
        var cost = 0.0
        var requests = 0
        var models: [String: ModelAcc] = [:]
        var modelsUsed: Set<String> = []
    }

    /// Runs the message query and applies the per-row JSON filter. Returns
    /// every completed assistant message in DB order (oldest first). The
    /// caller is responsible for any date filtering, sorting, or capping.
    private static func loadMessages(db: OpaquePointer) -> [MessageData] {
        let sql = """
        SELECT id, session_id, time_created, data FROM message \
        ORDER BY time_created ASC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [MessageData] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let sessionCStr = sqlite3_column_text(stmt, 1) else { continue }
            let sessionId = String(cString: sessionCStr)
            let createdMs = sqlite3_column_int64(stmt, 2)
            guard let dataCStr = sqlite3_column_text(stmt, 3) else { continue }
            let dataJSON = String(cString: dataCStr)

            guard let parsed = Self.parseMessage(
                sessionId: sessionId,
                createdMs: createdMs,
                dataJSON: dataJSON)
            else { continue }
            results.append(parsed)
        }
        return results
    }

    /// JSON filter: only assistant messages, only with token data, only fully
    /// completed. Mirrors `parse_message_data` + `query_assistant_messages` in
    /// cc-switch's `session_usage_opencode.rs`.
    public static func parseMessage(
        sessionId: String,
        createdMs: Int64,
        dataJSON: String) -> MessageData?
    {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(
                with: dataJSON.data(using: .utf8) ?? Data(),
                options: [])
        } catch {
            return nil
        }
        guard let object = value as? [String: Any] else { return nil }

        // role must be "assistant"
        if let role = object["role"] as? String, role != "assistant" { return nil }

        // Must have a tokens field
        guard let tokens = object["tokens"] as? [String: Any] else { return nil }

        // Must have time.completed (skip in-progress messages — they only have
        // half the data and would distort the totals)
        if let time = object["time"] as? [String: Any] {
            if time["completed"] == nil { return nil }
        } else {
            return nil
        }

        let input = (tokens["input"] as? NSNumber)?.intValue ?? 0
        let output = (tokens["output"] as? NSNumber)?.intValue ?? 0
        let reasoning = (tokens["reasoning"] as? NSNumber)?.intValue ?? 0
        let cache = tokens["cache"] as? [String: Any]
        let cacheRead = (cache?["read"] as? NSNumber)?.intValue ?? 0
        let cacheWrite = (cache?["write"] as? NSNumber)?.intValue ?? 0
        let cost = (object["cost"] as? NSNumber)?.doubleValue ?? 0.0

        let result = MessageData(
            sessionId: sessionId,
            createdMs: createdMs,
            modelId: Self.modelId(from: object),
            providerId: object["providerID"] as? String,
            inputTokens: input,
            outputTokens: output,
            reasoningTokens: reasoning,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            cost: cost)
        return result.isEmpty ? nil : result
    }

    private static func modelId(from object: [String: Any]) -> String {
        if let id = object["modelID"] as? String, !id.isEmpty { return id }
        if let model = object["model"] as? [String: Any],
           let id = model["id"] as? String,
           !id.isEmpty
        { return id }
        if let legacy = object["model"] as? String, !legacy.isEmpty { return legacy }
        return "unknown"
    }

    private static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func entry(from message: MessageData) -> OpenCodeRequestLogEntry {
        let timestamp = Date(timeIntervalSince1970: Double(message.createdMs) / 1000)
        let id = "opencode:\(message.sessionId):\(timestamp.timeIntervalSince1970):\(message.modelId)"
        return OpenCodeRequestLogEntry(
            id: id,
            sessionId: message.sessionId,
            timestamp: timestamp,
            modelId: message.modelId,
            providerId: message.providerId,
            inputTokens: message.inputTokens,
            outputTokens: message.outputTokens,
            reasoningTokens: message.reasoningTokens,
            cacheReadTokens: message.cacheReadTokens,
            cacheWriteTokens: message.cacheWriteTokens,
            costUSD: message.cost)
    }

    // MARK: - Backwards-compat helper

    /// Kept for the existing test that asserts the static JSON model-name
    /// parser. New code should rely on `parseMessage` (which uses
    /// `modelID`/`model.id`) instead.
    public static func modelName(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = object["id"] as? String,
           !id.isEmpty
        {
            return id
        }
        return trimmed.isEmpty ? "unknown" : trimmed
    }
}
