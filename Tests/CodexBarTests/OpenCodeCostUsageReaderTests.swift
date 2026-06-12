import CodexBarCore
import Foundation
import SQLite3
import Testing

struct OpenCodeCostUsageReaderTests {
    @Test
    func `parses model id from json column`() {
        #expect(OpenCodeCostUsageReader.modelName(
            from: #"{"id":"gpt-5.5","providerID":"openai","variant":"high"}"#) == "gpt-5.5")
        #expect(OpenCodeCostUsageReader.modelName(from: "claude-opus-4-7") == "claude-opus-4-7")
        #expect(OpenCodeCostUsageReader.modelName(from: "  ") == "unknown")
    }

    @Test
    func `aggregates session rows by day and model`() throws {
        let calendar = Calendar(identifier: .gregorian)
        let dataHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencode-test-\(UUID().uuidString)", isDirectory: true)
        let dbDir = dataHome.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataHome) }
        let dbURL = dbDir.appendingPathComponent("opencode.db")

        func day(_ y: Int, _ m: Int, _ d: Int) throws -> Date {
            var comps = DateComponents()
            comps.year = y
            comps.month = m
            comps.day = d
            comps.hour = 12
            return try #require(calendar.date(from: comps))
        }
        func ms(_ date: Date) -> Int64 {
            Int64(date.timeIntervalSince1970 * 1000)
        }

        let dayA = try day(2026, 6, 10)
        let dayB = try day(2026, 6, 11)

        var db: OpaquePointer?
        try #require(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
        let schema = """
        CREATE TABLE session (time_created INTEGER, model TEXT, cost REAL, \
        tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, \
        tokens_cache_read INTEGER, tokens_cache_write INTEGER);
        """
        try #require(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)

        func insert(_ date: Date, _ model: String, cost: Double, input: Int, output: Int) {
            let sql = "INSERT INTO session VALUES (\(ms(date)), '\(model)', \(cost), " +
                "\(input), \(output), 0, 0, 0);"
            sqlite3_exec(db, sql, nil, nil, nil)
        }
        insert(dayA, #"{"id":"gpt-5.5","providerID":"openai"}"#, cost: 1.0, input: 100, output: 50)
        insert(dayA, #"{"id":"gpt-5.5","providerID":"openai"}"#, cost: 0.5, input: 10, output: 5)
        insert(dayA, #"{"id":"claude-opus-4-7","providerID":"anthropic"}"#, cost: 2.0, input: 200, output: 0)
        insert(dayB, #"{"id":"gpt-5.5","providerID":"openai"}"#, cost: 3.0, input: 300, output: 0)
        sqlite3_close(db)

        let report = try OpenCodeCostUsageReader.loadDailyReport(
            since: day(2026, 6, 1),
            until: day(2026, 6, 30),
            now: day(2026, 6, 30),
            environment: ["XDG_DATA_HOME": dataHome.path])

        #expect(report.data.count == 2)
        #expect(report.summary?.totalTokens == 665)

        let dayAEntry = try #require(report.data.first { $0.date == "2026-06-10" })
        #expect(dayAEntry.totalTokens == 365)
        #expect(abs((dayAEntry.costUSD ?? 0) - 3.5) < 0.0001)
        let breakdowns = try #require(dayAEntry.modelBreakdowns)
        #expect(breakdowns.count == 2)
        let gpt = try #require(breakdowns.first { $0.modelName == "gpt-5.5" })
        #expect(gpt.totalTokens == 165)
        let claude = try #require(breakdowns.first { $0.modelName == "claude-opus-4-7" })
        #expect(claude.totalTokens == 200)

        let dayBEntry = try #require(report.data.first { $0.date == "2026-06-11" })
        #expect(dayBEntry.totalTokens == 300)
    }

    @Test
    func `missing database yields empty report`() {
        let report = OpenCodeCostUsageReader.loadDailyReport(
            since: Date(timeIntervalSince1970: 0),
            until: Date(),
            environment: ["XDG_DATA_HOME": "/nonexistent-\(UUID().uuidString)"])
        #expect(report.data.isEmpty)
    }
}
