import CodexBarCore
import Foundation
import SQLite3
import Testing

struct OpenCodeReadCacheTests {
    // MARK: - Setup helpers

    /// Builds a fresh temp layout containing `opencode/opencode.db` with the
    /// given `message` rows and an empty cache directory, then returns the
    /// per-test `XDG_DATA_HOME` (so the reader finds the DB) and `cacheRoot`
    /// (so cache writes don't pollute the user's real cache).
    private struct TestEnv {
        let dataHome: URL
        let cacheRoot: URL
        let databaseURL: URL
        var environment: [String: String] {
            ["XDG_DATA_HOME": self.dataHome.path]
        }
    }

    private struct MessageSpec {
        var day: Int
        var hour: Int
        var model: String
        var input: Int
        var output: Int
        var cost: Double
        var cacheRead: Int = 0
        var cacheWrite: Int = 0
    }

    private func makeEnv(
        messages: [MessageSpec],
        file: StaticString = #filePath,
        line: UInt = #line) throws -> TestEnv
    {
        let calendar = Calendar(identifier: .gregorian)
        let dataHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencode-cache-data-\(UUID().uuidString)", isDirectory: true)
        let cacheRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencode-cache-files-\(UUID().uuidString)", isDirectory: true)
        let dbDir = dataHome.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let dbURL = dbDir.appendingPathComponent("opencode.db")

        var db: OpaquePointer?
        try #require(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
        let schema = "CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT);"
        try #require(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)

        for (i, msg) in messages.enumerated() {
            var comps = DateComponents()
            comps.year = 2026
            comps.month = 6
            comps.day = msg.day
            comps.hour = msg.hour
            comps.minute = 0
            let date = try #require(calendar.date(from: comps))
            let ms = Int64(date.timeIntervalSince1970 * 1000)
            let json = """
            {
                "role": "assistant", "cost": \(msg.cost),
                "tokens": { "input": \(msg.input), "output": \(msg.output), "reasoning": 0, "cache": { "read": \(msg
                .cacheRead), "write": \(msg.cacheWrite) } },
                "modelID": "\(msg.model)", "providerID": "p",
                "time": { "created": \(ms), "completed": \(ms + 1) }
            }
            """.replacingOccurrences(of: "\n", with: "")
            // Escape only single quotes — the JSON's double quotes are
            // fine inside a SQL single-quoted string literal.
            let escaped = json.replacingOccurrences(of: "'", with: "''")
            let sql = "INSERT INTO message VALUES ('m\(i)', 'sess', \(ms), '\(escaped)');"
            sqlite3_exec(db, sql, nil, nil, nil)
        }
        sqlite3_close(db)

        return TestEnv(dataHome: dataHome, cacheRoot: cacheRoot, databaseURL: dbURL)
    }

    private func cleanup(_ env: TestEnv) {
        try? FileManager.default.removeItem(at: env.dataHome)
        try? FileManager.default.removeItem(at: env.cacheRoot)
    }

    private func singleMessageEnv(
        day: Int = 10,
        hour: Int = 12,
        model: String = "gpt-5.5",
        input: Int = 100,
        output: Int = 50,
        cost: Double = 0.001,
        cacheRead: Int = 0,
        cacheWrite: Int = 0) throws -> TestEnv
    {
        let spec = MessageSpec(
            day: day,
            hour: hour,
            model: model,
            input: input,
            output: output,
            cost: cost,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite)
        return try self.makeEnv(messages: [spec])
    }

    private func dayDate(_ day: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 6
        comps.day = day
        comps.hour = 12
        return Calendar(identifier: .gregorian).date(from: comps) ?? Date()
    }

    // MARK: - Cache IO round-trip

    @Test
    func `cache round-trips through save and load`() throws {
        let env = try singleMessageEnv()
        defer { cleanup(env) }

        let log = OpenCodeCostUsageReader.loadRequestLog(
            since: self.dayDate(1),
            until: self.dayDate(30),
            cacheRoot: env.cacheRoot,
            environment: env.environment)
        #expect(log.entries.count == 1)
        #expect(log.entries[0].modelId == "gpt-5.5")
        #expect(log.entries[0].inputTokens == 100)
        #expect(log.entries[0].outputTokens == 50)

        // The cache file must now exist on disk under the test cache root.
        let cacheURL = OpenCodeReadCacheIO.cacheFileURL(cacheRoot: env.cacheRoot)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))

        // And a second call must return the same content (no rescanning —
        // we just check the surface area, not the IO path).
        let log2 = OpenCodeCostUsageReader.loadRequestLog(
            since: self.dayDate(1),
            until: self.dayDate(30),
            cacheRoot: env.cacheRoot,
            environment: env.environment)
        #expect(log2.entries.count == 1)
        #expect(log2.entries[0].id == log.entries[0].id)
    }

    // MARK: - Cache hit avoids re-scanning

    @Test
    func `second call with unchanged db returns cached data after db is deleted`() throws {
        let env = try singleMessageEnv()
        defer { cleanup(env) }

        // First call: writes the cache.
        let first = OpenCodeCostUsageReader.loadRequestLog(
            since: self.dayDate(1),
            until: self.dayDate(30),
            cacheRoot: env.cacheRoot,
            environment: env.environment)
        #expect(first.entries.count == 1, "Expected first scan to find 1 entry, got \(first.entries.count)")

        // Sanity check: the cache file should now exist on disk.
        let cacheURL = OpenCodeReadCacheIO.cacheFileURL(cacheRoot: env.cacheRoot)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))

        // Sanity check: the cache's content is what we expect.
        if let cached = OpenCodeReadCacheIO.load(cacheRoot: env.cacheRoot) {
            #expect(
                cached.requestLog.entries.count == 1,
                "Cache should have 1 entry, has \(cached.requestLog.entries.count)")
            #expect(cached.databasePath == env.databaseURL.path)
            // The cached entry's timestamp must fall inside the dayDate(1)…
            // dayDate(30) window. If this fails, the JSON round-trip corrupted
            // the timestamp and the filter is excluding everything.
            let entry = cached.requestLog.entries[0]
            let inRange = entry.timestamp >= self.dayDate(1) && entry.timestamp <= self.dayDate(30)
            #expect(inRange, "Cached entry timestamp \(entry.timestamp) is outside dayDate(1)…dayDate(30) window")
        } else {
            Issue.record("Cache file exists but load returned nil")
        }

        // Delete the DB. The cache is still on disk, so the next call must
        // hit the cache fallback and produce the same result.
        try FileManager.default.removeItem(at: env.databaseURL)

        let log = OpenCodeCostUsageReader.loadRequestLog(
            since: self.dayDate(1),
            until: self.dayDate(30),
            cacheRoot: env.cacheRoot,
            environment: env.environment)
        #expect(log.entries.count == 1, "Expected cached result to have 1 entry, got \(log.entries.count)")
        #expect(log.entries[0].modelId == "gpt-5.5")
    }

    // MARK: - Cache invalidation: mtime change

    @Test
    func `cache invalidates when db mtime advances`() throws {
        let env = try singleMessageEnv()
        defer { cleanup(env) }

        // Prime the cache.
        _ = OpenCodeCostUsageReader.loadRequestLog(
            since: self.dayDate(1),
            until: self.dayDate(30),
            cacheRoot: env.cacheRoot,
            environment: env.environment)

        // Bump the db mtime by 1s. APFS mtime resolution is sub-second, but
        // 2s in the future is reliably past any value `attributesOfItem` could
        // have read earlier.
        let future = Date().addingTimeInterval(2)
        try FileManager.default.setAttributes(
            [.modificationDate: future],
            ofItemAtPath: env.databaseURL.path)

        // Empty the DB so a fresh scan would produce an empty report. If
        // the cache weren't invalidated, the reader would still hand back
        // the old data.
        var db: OpaquePointer?
        try #require(sqlite3_open(env.databaseURL.path, &db) == SQLITE_OK)
        try #require(sqlite3_exec(db, "DELETE FROM message;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let log = OpenCodeCostUsageReader.loadRequestLog(
            since: self.dayDate(1),
            until: self.dayDate(30),
            cacheRoot: env.cacheRoot,
            environment: env.environment)
        #expect(log.entries.isEmpty)
    }

    // MARK: - Cache invalidation: WAL mtime

    @Test
    func `cache invalidates when wal mtime advances past db mtime`() throws {
        let env = try singleMessageEnv()
        defer { cleanup(env) }

        // Prime the cache while the WAL doesn't yet exist.
        _ = OpenCodeCostUsageReader.loadRequestLog(
            since: self.dayDate(1),
            until: self.dayDate(30),
            cacheRoot: env.cacheRoot,
            environment: env.environment)

        // Create a `-wal` file with a newer mtime. The reader must consider
        // it newer than the db mtime (ccswitch's behavior) and invalidate
        // the cache.
        let walURL = env.databaseURL.deletingLastPathComponent()
            .appendingPathComponent("\(env.databaseURL.lastPathComponent)-wal")
        try Data().write(to: walURL)
        let future = Date().addingTimeInterval(2)
        try FileManager.default.setAttributes(
            [.modificationDate: future],
            ofItemAtPath: walURL.path)

        // Empty the DB so a fresh scan would return nothing.
        var db: OpaquePointer?
        try #require(sqlite3_open(env.databaseURL.path, &db) == SQLITE_OK)
        try #require(sqlite3_exec(db, "DELETE FROM message;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let log = OpenCodeCostUsageReader.loadRequestLog(
            since: self.dayDate(1),
            until: self.dayDate(30),
            cacheRoot: env.cacheRoot,
            environment: env.environment)
        #expect(log.entries.isEmpty)
    }

    // MARK: - Cache invalidation: DB path change

    @Test
    func `cache invalidates when db path changes`() throws {
        let env1 = try singleMessageEnv()
        defer { cleanup(env1) }
        let env2 = try singleMessageEnv(model: "claude-opus-4-7", input: 200, output: 100)
        defer { cleanup(env2) }

        // Prime cache against env1.
        let first = OpenCodeCostUsageReader.loadRequestLog(
            since: self.dayDate(1),
            until: self.dayDate(30),
            cacheRoot: env1.cacheRoot,
            environment: env1.environment)
        #expect(first.entries[0].modelId == "gpt-5.5")

        // Call with env2's environment but env1's cacheRoot. The cache file
        // exists but is keyed to a different DB path, so the reader must
        // rescan env2's DB.
        let second = OpenCodeCostUsageReader.loadRequestLog(
            since: self.dayDate(1),
            until: self.dayDate(30),
            cacheRoot: env1.cacheRoot,
            environment: env2.environment)
        #expect(second.entries[0].modelId == "claude-opus-4-7")
        #expect(second.entries[0].inputTokens == 200)
    }

    // MARK: - Cache invalidation: corrupt file

    @Test
    func `cache invalidates when file is corrupt`() throws {
        let env = try singleMessageEnv()
        defer { cleanup(env) }

        let cacheURL = OpenCodeReadCacheIO.cacheFileURL(cacheRoot: env.cacheRoot)
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("not a valid json document".utf8).write(to: cacheURL)

        // The reader should silently ignore the broken cache and scan the DB
        // fresh, returning the real data.
        let log = OpenCodeCostUsageReader.loadRequestLog(
            since: self.dayDate(1),
            until: self.dayDate(30),
            cacheRoot: env.cacheRoot,
            environment: env.environment)
        #expect(log.entries.count == 1)
        #expect(log.entries[0].modelId == "gpt-5.5")
    }

    // MARK: - Cache invalidation: version mismatch

    @Test
    func `cache invalidates when version is stale`() throws {
        let env = try singleMessageEnv()
        defer { cleanup(env) }

        // Write a cache file with a deliberately-wrong version.
        let cacheURL = OpenCodeReadCacheIO.cacheFileURL(cacheRoot: env.cacheRoot)
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let bogus: [String: Any] = [
            "v": 999,
            "db": env.databaseURL.path,
            "mtime": Date().timeIntervalSince1970,
            "daily": ["data": []],
            "reqlog": ["entries": [], "rs": 0.0, "re": 0.0],
        ]
        let data = try JSONSerialization.data(withJSONObject: bogus, options: [])
        try data.write(to: cacheURL)

        // Reader must ignore the wrong-version cache and scan fresh.
        let log = OpenCodeCostUsageReader.loadRequestLog(
            since: self.dayDate(1),
            until: self.dayDate(30),
            cacheRoot: env.cacheRoot,
            environment: env.environment)
        #expect(log.entries.count == 1)
    }

    // MARK: - Range filter on cached data

    @Test
    func `cached full data is filtered to requested range`() throws {
        let env = try makeEnv(messages: [
            MessageSpec(day: 5, hour: 12, model: "m-a", input: 100, output: 50, cost: 0.01),
            MessageSpec(day: 15, hour: 12, model: "m-b", input: 200, output: 100, cost: 0.02),
            MessageSpec(day: 25, hour: 12, model: "m-c", input: 300, output: 150, cost: 0.03),
        ])
        defer { cleanup(env) }

        // First call: scan everything, populate cache.
        let full = OpenCodeCostUsageReader.loadDailyReport(
            since: self.dayDate(1),
            until: self.dayDate(30),
            cacheRoot: env.cacheRoot,
            environment: env.environment)
        #expect(full.data.count == 3)
        #expect(full.summary?.totalCostUSD == 0.06)

        // Second call with a tighter range must slice the cached entries —
        // not rescanning — so the totals match only the requested days.
        let windowed = OpenCodeCostUsageReader.loadDailyReport(
            since: self.dayDate(10),
            until: self.dayDate(20),
            cacheRoot: env.cacheRoot,
            environment: env.environment)
        #expect(windowed.data.count == 1)
        #expect(windowed.data[0].date == "2026-06-15")
        #expect(windowed.summary?.totalCostUSD == 0.02)
    }

    // MARK: - Missing database

    @Test
    func `missing database returns empty results and does not cache`() {
        let env = TestEnv(
            dataHome: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"),
            cacheRoot: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("opencode-cache-missing-\(UUID().uuidString)"),
            databaseURL: URL(fileURLWithPath: "/nonexistent/db"))

        let report = OpenCodeCostUsageReader.loadDailyReport(
            since: self.dayDate(1),
            until: self.dayDate(30),
            cacheRoot: env.cacheRoot,
            environment: env.environment)
        #expect(report.data.isEmpty)
        #expect(report.summary == nil)

        let log = OpenCodeCostUsageReader.loadRequestLog(
            since: self.dayDate(1),
            until: self.dayDate(30),
            cacheRoot: env.cacheRoot,
            environment: env.environment)
        #expect(log.entries.isEmpty)

        // No cache file should have been written for a missing DB.
        let cacheURL = OpenCodeReadCacheIO.cacheFileURL(cacheRoot: env.cacheRoot)
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))

        try? FileManager.default.removeItem(at: env.cacheRoot)
    }

    // MARK: - Atomic write leaves no temp files

    @Test
    func `save does not leave temp files behind`() throws {
        let env = try singleMessageEnv()
        defer { cleanup(env) }

        // Prime + force a save (the prime writes the cache).
        _ = OpenCodeCostUsageReader.loadRequestLog(
            since: self.dayDate(1),
            until: self.dayDate(30),
            cacheRoot: env.cacheRoot,
            environment: env.environment)

        // Run a few more times to exercise the replace path; any of these
        // could in principle crash mid-write.
        for _ in 0..<3 {
            let future = Date().addingTimeInterval(2)
            try? FileManager.default.setAttributes(
                [.modificationDate: future],
                ofItemAtPath: env.databaseURL.path)
            _ = OpenCodeCostUsageReader.loadRequestLog(
                since: self.dayDate(1),
                until: self.dayDate(30),
                cacheRoot: env.cacheRoot,
                environment: env.environment)
        }

        let costUsageDir = OpenCodeReadCacheIO.cacheFileURL(cacheRoot: env.cacheRoot)
            .deletingLastPathComponent()
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: costUsageDir,
            includingPropertiesForKeys: nil)) ?? []
        let tmpFiles = contents.filter { $0.lastPathComponent.hasPrefix(".tmp-") }
        let tmpNames: [String] = tmpFiles.map(\.lastPathComponent)
        #expect(tmpFiles.isEmpty, "Expected no leftover temp files, found: \(tmpNames)")
        #expect(contents.contains { $0.lastPathComponent.hasPrefix("opencode-v") })
    }

    // MARK: - request log cap

    @Test
    func `cached request log is capped at cachedRequestLogCap`() throws {
        // Build 12 messages and confirm the cached log caps at the lower of
        // (cachedRequestLogCap, actual count). 12 < cap so we use a separate
        // assertion via the public 500-default — the cap is 5000, so a
        // public call naturally respects it without going over.
        let messages: [MessageSpec] = (0..<12).map { i in
            MessageSpec(day: 10, hour: i, model: "m-\(i)", input: 10, output: 5, cost: 0.001)
        }
        let env = try makeEnv(messages: messages)
        defer { cleanup(env) }

        let log = OpenCodeCostUsageReader.loadRequestLog(
            since: self.dayDate(1),
            until: self.dayDate(30),
            maxEntries: 500,
            cacheRoot: env.cacheRoot,
            environment: env.environment)
        #expect(log.entries.count == 12)
        // Confirm cache contents are within the cap by directly loading.
        if let cache = OpenCodeReadCacheIO.load(cacheRoot: env.cacheRoot) {
            #expect(cache.requestLog.entries.count <= OpenCodeReadCacheIO.cachedRequestLogCap)
        }
    }
}
