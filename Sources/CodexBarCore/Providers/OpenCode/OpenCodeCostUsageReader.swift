import Foundation
import SQLite3

/// Reads OpenCode's local SQLite store (`opencode.db`) and produces a daily
/// token/cost report shaped like the Codex/Claude scanners, so OpenCode usage
/// flows into the same heatmap and statistics. OpenCode records per-session
/// aggregates in the `session` table (`model`, `cost`, `tokens_*`), which is
/// accurate enough for day-level reporting.
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

    public static func loadDailyReport(
        since: Date,
        until: Date,
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment) -> CostUsageDailyReport
    {
        let empty = CostUsageDailyReport(data: [], summary: nil)
        let url = self.databaseURL(environment: environment)
        guard FileManager.default.fileExists(atPath: url.path) else { return empty }

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return empty
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT time_created, model, cost, tokens_input, tokens_output, tokens_reasoning, \
        tokens_cache_read, tokens_cache_write FROM session WHERE time_created >= ? AND time_created <= ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return empty }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(since.timeIntervalSince1970 * 1000))
        sqlite3_bind_int64(stmt, 2, Int64(until.timeIntervalSince1970 * 1000))

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"

        struct ModelAcc { var tokens = 0; var cost = 0.0 }
        struct DayAcc {
            var tokens = 0
            var cost = 0.0
            var input = 0
            var output = 0
            var cacheRead = 0
            var cacheWrite = 0
            var models: [String: ModelAcc] = [:]
        }
        var byDay: [String: DayAcc] = [:]

        while sqlite3_step(stmt) == SQLITE_ROW {
            let createdMs = sqlite3_column_int64(stmt, 0)
            let modelRaw = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let cost = sqlite3_column_double(stmt, 2)
            let input = Int(sqlite3_column_int64(stmt, 3))
            let output = Int(sqlite3_column_int64(stmt, 4))
            let reasoning = Int(sqlite3_column_int64(stmt, 5))
            let cacheRead = Int(sqlite3_column_int64(stmt, 6))
            let cacheWrite = Int(sqlite3_column_int64(stmt, 7))
            let tokens = input + output + reasoning + cacheRead + cacheWrite
            guard tokens > 0 || cost > 0 else { continue }

            let day = formatter.string(from: Date(timeIntervalSince1970: Double(createdMs) / 1000))
            let model = self.modelName(from: modelRaw)

            var acc = byDay[day] ?? DayAcc()
            acc.tokens += tokens
            acc.cost += cost
            acc.input += input + reasoning
            acc.output += output
            acc.cacheRead += cacheRead
            acc.cacheWrite += cacheWrite
            var modelAcc = acc.models[model] ?? ModelAcc()
            modelAcc.tokens += tokens
            modelAcc.cost += cost
            acc.models[model] = modelAcc
            byDay[day] = acc
        }

        guard !byDay.isEmpty else { return empty }

        let requestsByDay = self.requestCounts(db: db, since: since, until: until)

        let entries = byDay
            .map { day, acc in
                CostUsageDailyReport.Entry(
                    date: day,
                    inputTokens: acc.input > 0 ? acc.input : nil,
                    outputTokens: acc.output > 0 ? acc.output : nil,
                    cacheReadTokens: acc.cacheRead > 0 ? acc.cacheRead : nil,
                    cacheCreationTokens: acc.cacheWrite > 0 ? acc.cacheWrite : nil,
                    totalTokens: acc.tokens,
                    requestCount: requestsByDay[day],
                    costUSD: acc.cost,
                    modelsUsed: Array(acc.models.keys).sorted(),
                    modelBreakdowns: acc.models
                        .map { name, value in
                            CostUsageDailyReport.ModelBreakdown(
                                modelName: name,
                                costUSD: value.cost,
                                totalTokens: value.tokens)
                        }
                        .sorted { ($0.totalTokens ?? 0) > ($1.totalTokens ?? 0) })
            }
            .sorted { $0.date < $1.date }

        let totalTokens = entries.reduce(0) { $0 + ($1.totalTokens ?? 0) }
        let totalCost = entries.reduce(0.0) { $0 + ($1.costUSD ?? 0) }
        let summary = CostUsageDailyReport.Summary(
            totalInputTokens: nil,
            totalOutputTokens: nil,
            totalTokens: totalTokens,
            totalCostUSD: totalCost)
        return CostUsageDailyReport(data: entries, summary: summary)
    }

    /// Counts model requests per day. OpenCode records one `step-finish` part per model
    /// round-trip, so counting those parts in the window yields the request count.
    private static func requestCounts(db: OpaquePointer, since: Date, until: Date) -> [String: Int] {
        let sql = """
        SELECT time_created FROM part WHERE time_created >= ? AND time_created <= ? \
        AND data LIKE '%"type":"step-finish"%'
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(since.timeIntervalSince1970 * 1000))
        sqlite3_bind_int64(stmt, 2, Int64(until.timeIntervalSince1970 * 1000))

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"

        var counts: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let createdMs = sqlite3_column_int64(stmt, 0)
            let day = formatter.string(from: Date(timeIntervalSince1970: Double(createdMs) / 1000))
            counts[day, default: 0] += 1
        }
        return counts
    }

    /// OpenCode stores `model` as a JSON object (`{"id":"gpt-5.5","providerID":"openai"}`).
    /// Extract the model id for display/grouping, falling back to the raw value.
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
