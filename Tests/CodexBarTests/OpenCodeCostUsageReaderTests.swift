import CodexBarCore
import Foundation
import SQLite3
import Testing

struct OpenCodeCostUsageReaderTests {
    // MARK: - Static helpers

    @Test
    func `parses model id from legacy json column`() {
        // The legacy `session.model` column stores the model as a JSON blob;
        // `modelName(from:)` extracts the model id for backwards-compat callers
        // (the new message-table reader does its own JSON parsing internally).
        #expect(OpenCodeCostUsageReader.modelName(
            from: #"{"id":"gpt-5.5","providerID":"openai","variant":"high"}"#) == "gpt-5.5")
        #expect(OpenCodeCostUsageReader.modelName(from: "claude-opus-4-7") == "claude-opus-4-7")
        #expect(OpenCodeCostUsageReader.modelName(from: "  ") == "unknown")
    }

    // MARK: - JSON filter (mirrors ccswitch's parse_message_data)

    @Test
    func `parseMessage extracts full token shape`() {
        let json = #"""
        {
            "role": "assistant",
            "cost": 0.0023113,
            "tokens": {
                "total": 56554,
                "input": 3272,
                "output": 383,
                "reasoning": 419,
                "cache": { "write": 0, "read": 52480 }
            },
            "modelID": "deepseek-v4-pro",
            "providerID": "deepseek",
            "time": { "created": 1779755333700, "completed": 1779755350639 }
        }
        """#
        let parsed = OpenCodeCostUsageReader.parseMessage(
            sessionId: "s1",
            createdMs: 1_779_755_333_700,
            dataJSON: json)
        #expect(parsed?.inputTokens == 3272)
        #expect(parsed?.outputTokens == 383)
        #expect(parsed?.reasoningTokens == 419)
        #expect(parsed?.cacheReadTokens == 52480)
        #expect(parsed?.cacheWriteTokens == 0)
        #expect(parsed?.cost == 0.0023113)
        #expect(parsed?.modelId == "deepseek-v4-pro")
        #expect(parsed?.providerId == "deepseek")
    }

    @Test
    func `parseMessage tolerates missing cache object`() {
        let json = #"""
        {
            "role": "assistant",
            "cost": 0.0,
            "tokens": { "input": 1000, "output": 200 },
            "modelID": "mimo-v2.5-pro",
            "time": { "created": 1, "completed": 2 }
        }
        """#
        let parsed = OpenCodeCostUsageReader.parseMessage(
            sessionId: "s1", createdMs: 1, dataJSON: json)
        #expect(parsed?.inputTokens == 1000)
        #expect(parsed?.outputTokens == 200)
        #expect(parsed?.reasoningTokens == 0)
        #expect(parsed?.cacheReadTokens == 0)
        #expect(parsed?.cacheWriteTokens == 0)
    }

    @Test
    func `parseMessage drops zero-token zero-cost rows`() {
        let json = #"""
        {
            "role": "assistant",
            "tokens": { "input": 0, "output": 0, "reasoning": 0, "cache": { "read": 0, "write": 0 } },
            "modelID": "test",
            "time": { "created": 1, "completed": 2 }
        }
        """#
        let parsed = OpenCodeCostUsageReader.parseMessage(
            sessionId: "s1", createdMs: 1, dataJSON: json)
        #expect(parsed == nil)
    }

    @Test
    func `parseMessage rejects non-assistant roles`() {
        let json = #"""
        {
            "role": "user",
            "tokens": { "input": 100, "output": 0 },
            "modelID": "m",
            "time": { "created": 1, "completed": 2 }
        }
        """#
        let parsed = OpenCodeCostUsageReader.parseMessage(
            sessionId: "s1", createdMs: 1, dataJSON: json)
        #expect(parsed == nil)
    }

    @Test
    func `parseMessage rejects in-progress messages without completed time`() {
        let json = #"""
        {
            "role": "assistant",
            "tokens": { "input": 500, "output": 0 },
            "modelID": "m",
            "time": { "created": 3 }
        }
        """#
        let parsed = OpenCodeCostUsageReader.parseMessage(
            sessionId: "s1", createdMs: 3, dataJSON: json)
        #expect(parsed == nil)
    }

    @Test
    func `parseMessage rejects rows without tokens field`() {
        let json = #"""
        {
            "role": "assistant",
            "modelID": "m",
            "time": { "created": 1, "completed": 2 }
        }
        """#
        let parsed = OpenCodeCostUsageReader.parseMessage(
            sessionId: "s1", createdMs: 1, dataJSON: json)
        #expect(parsed == nil)
    }

    @Test
    func `parseMessage rejects malformed JSON`() {
        let parsed = OpenCodeCostUsageReader.parseMessage(
            sessionId: "s1", createdMs: 1, dataJSON: "not json")
        #expect(parsed == nil)
    }

    @Test
    func `parseMessage falls back to legacy model object when modelID missing`() {
        let json = #"""
        {
            "role": "assistant",
            "tokens": { "input": 100, "output": 10 },
            "model": { "id": "legacy-model" },
            "time": { "created": 1, "completed": 2 }
        }
        """#
        let parsed = OpenCodeCostUsageReader.parseMessage(
            sessionId: "s1", createdMs: 1, dataJSON: json)
        #expect(parsed?.modelId == "legacy-model")
    }

    // MARK: - Daily report aggregation

    @Test
    func `aggregates message rows by day and model`() throws {
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
        CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
        """
        try #require(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)

        func insert(_ date: Date, _ data: String) {
            let escaped = data
                .replacingOccurrences(of: "'", with: "''")
            let sql = "INSERT INTO message VALUES ('\(UUID().uuidString)', 'sess-1', \(ms(date)), '\(escaped)');"
            sqlite3_exec(db, sql, nil, nil, nil)
        }
        insert(dayA, #"""
        {
            "role": "assistant", "cost": 0.001,
            "tokens": { "input": 100, "output": 50, "reasoning": 0, "cache": { "read": 0, "write": 0 } },
            "modelID": "gpt-5.5", "providerID": "openai",
            "time": { "created": 1, "completed": 2 }
        }
        """#)
        insert(dayA, #"""
        {
            "role": "assistant", "cost": 0.0005,
            "tokens": { "input": 10, "output": 5, "reasoning": 0, "cache": { "read": 0, "write": 0 } },
            "modelID": "gpt-5.5", "providerID": "openai",
            "time": { "created": 3, "completed": 4 }
        }
        """#)
        insert(dayA, #"""
        {
            "role": "assistant", "cost": 0.002,
            "tokens": { "input": 200, "output": 0, "reasoning": 0, "cache": { "read": 0, "write": 0 } },
            "modelID": "claude-opus-4-7", "providerID": "anthropic",
            "time": { "created": 5, "completed": 6 }
        }
        """#)
        insert(dayB, #"""
        {
            "role": "assistant", "cost": 0.003,
            "tokens": { "input": 300, "output": 0, "reasoning": 0, "cache": { "read": 0, "write": 0 } },
            "modelID": "gpt-5.5", "providerID": "openai",
            "time": { "created": 7, "completed": 8 }
        }
        """#)
        // in-progress (no completed) — should be skipped
        insert(dayA, #"""
        {
            "role": "assistant", "cost": 99.0,
            "tokens": { "input": 9999, "output": 0, "reasoning": 0, "cache": { "read": 0, "write": 0 } },
            "modelID": "gpt-5.5", "providerID": "openai",
            "time": { "created": 100 }
        }
        """#)
        // non-assistant — should be skipped
        insert(dayA, #"""
        {
            "role": "user", "cost": 0.0,
            "tokens": { "input": 50, "output": 0, "reasoning": 0, "cache": { "read": 0, "write": 0 } },
            "modelID": "gpt-5.5", "providerID": "openai",
            "time": { "created": 200, "completed": 201 }
        }
        """#)
        sqlite3_close(db)

        let report = try OpenCodeCostUsageReader.loadDailyReport(
            since: day(2026, 6, 1),
            until: day(2026, 6, 30),
            now: day(2026, 6, 30),
            environment: ["XDG_DATA_HOME": dataHome.path])

        #expect(report.data.count == 2)
        #expect(report.summary?.totalTokens == 665)
        #expect(abs((report.summary?.totalCostUSD ?? 0) - 0.0065) < 0.0001)

        let dayAEntry = try #require(report.data.first { $0.date == "2026-06-10" })
        #expect(dayAEntry.totalTokens == 365)
        #expect(dayAEntry.requestCount == 3) // 3 finished assistant messages on dayA
        #expect(abs((dayAEntry.costUSD ?? 0) - 0.0035) < 0.0001)
        let breakdowns = try #require(dayAEntry.modelBreakdowns)
        #expect(breakdowns.count == 2)
        let gpt = try #require(breakdowns.first { $0.modelName == "gpt-5.5" })
        #expect(gpt.totalTokens == 165)
        let claude = try #require(breakdowns.first { $0.modelName == "claude-opus-4-7" })
        #expect(claude.totalTokens == 200)

        let dayBEntry = try #require(report.data.first { $0.date == "2026-06-11" })
        #expect(dayBEntry.totalTokens == 300)
        #expect(dayBEntry.requestCount == 1)
    }

    @Test
    func `missing database yields empty report`() {
        let report = OpenCodeCostUsageReader.loadDailyReport(
            since: Date(timeIntervalSince1970: 0),
            until: Date(),
            environment: ["XDG_DATA_HOME": "/nonexistent-\(UUID().uuidString)"])
        #expect(report.data.isEmpty)
    }

    // MARK: - Request log

    @Test
    func `loadRequestLog returns newest first and caps entries`() throws {
        let calendar = Calendar(identifier: .gregorian)
        let dataHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencode-test-\(UUID().uuidString)", isDirectory: true)
        let dbDir = dataHome.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataHome) }
        let dbURL = dbDir.appendingPathComponent("opencode.db")

        func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) throws -> Date {
            var comps = DateComponents()
            comps.year = y
            comps.month = m
            comps.day = d
            comps.hour = hour
            return try #require(calendar.date(from: comps))
        }
        func ms(_ date: Date) -> Int64 {
            Int64(date.timeIntervalSince1970 * 1000)
        }

        var db: OpaquePointer?
        try #require(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
        try #require(sqlite3_exec(
            db,
            "CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT);",
            nil,
            nil,
            nil) == SQLITE_OK)
        for hour in 0..<5 {
            let date = try day(2026, 6, 10, hour: hour)
            let json = #"""
            {
                "role": "assistant", "cost": 0.001,
                "tokens": { "input": 100, "output": 50, "reasoning": 0, "cache": { "read": 0, "write": 0 } },
                "modelID": "m", "providerID": "p",
                "time": { "created": 1, "completed": 2 }
            }
            """#
            let escaped = json.replacingOccurrences(of: "'", with: "''")
            let sql = "INSERT INTO message VALUES ('m\(hour)', 'sess', \(ms(date)), '\(escaped)');"
            sqlite3_exec(db, sql, nil, nil, nil)
        }
        sqlite3_close(db)

        let log = try OpenCodeCostUsageReader.loadRequestLog(
            since: day(2026, 6, 1),
            until: day(2026, 6, 30),
            maxEntries: 3,
            environment: ["XDG_DATA_HOME": dataHome.path])
        #expect(log.entries.count == 3)
        // Newest first — hour 4 first, then 3, then 2.
        #expect(log.entries[0].timestamp > log.entries[1].timestamp)
        #expect(log.entries[1].timestamp > log.entries[2].timestamp)
        #expect(log.totalRequests == 3) // capped, not the underlying 5
    }

    @Test
    func `loadRequestLog aggregates totals correctly`() throws {
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

        var db: OpaquePointer?
        try #require(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
        try #require(sqlite3_exec(
            db,
            "CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT);",
            nil,
            nil,
            nil) == SQLITE_OK)
        // Two messages, with cache mix.
        let json1 = #"""
        {
            "role": "assistant", "cost": 0.01,
            "tokens": { "input": 100, "output": 50, "reasoning": 0, "cache": { "read": 500, "write": 0 } },
            "modelID": "m", "providerID": "p",
            "time": { "created": 1, "completed": 2 }
        }
        """#
        let json2 = #"""
        {
            "role": "assistant", "cost": 0.02,
            "tokens": { "input": 200, "output": 100, "reasoning": 50, "cache": { "read": 800, "write": 0 } },
            "modelID": "m", "providerID": "p",
            "time": { "created": 3, "completed": 4 }
        }
        """#
        for (i, json) in [json1, json2].enumerated() {
            let escaped = json.replacingOccurrences(of: "'", with: "''")
            let sql = try "INSERT INTO message VALUES ('m\(i)', 'sess', \(ms(day(2026, 6, 10))), '\(escaped)');"
            sqlite3_exec(db, sql, nil, nil, nil)
        }
        sqlite3_close(db)

        let log = try OpenCodeCostUsageReader.loadRequestLog(
            since: day(2026, 6, 1),
            until: day(2026, 6, 30),
            environment: ["XDG_DATA_HOME": dataHome.path])
        #expect(log.totalRequests == 2)
        #expect(log.totalInputTokens == 300)
        #expect(log.totalOutputTokens == 150)
        #expect(log.totalCacheReadTokens == 1300)
        #expect(log.totalCostUSD == 0.03)
        // cacheHitRate = 1300 / (1300 + 300) ≈ 0.8125
        #expect(abs(log.cacheHitRate - 1300.0 / 1600.0) < 0.0001)
    }
}
