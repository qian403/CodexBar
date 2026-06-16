import XCTest
@testable import CodexBarCore

final class OpenCodeRequestLogWindowFilterTests: XCTestCase {
    func test_filterToSelectedModels_keepsOnlyMatchingEntries() {
        let entries = [
            self.entry(model: "claude-opus-4-7", timestamp: 3),
            self.entry(model: "gpt-5", timestamp: 2),
            self.entry(model: "claude-opus-4-7", timestamp: 1),
        ]
        let selected: Set<String> = ["claude-opus-4-7"]

        let filtered = self.filter(entries: entries, selected: selected)

        XCTAssertEqual(filtered.map(\.timestamp), [
            self.date(3),
            self.date(1),
        ])
    }

    func test_filterEmptySelection_returnsNothing() {
        let entries = [
            self.entry(model: "gpt-5", timestamp: 1),
            self.entry(model: "claude-opus-4-7", timestamp: 2),
        ]

        let filtered = self.filter(entries: entries, selected: [])

        XCTAssertTrue(filtered.isEmpty)
    }

    func test_filterAllSelected_returnsOriginalOrder() {
        let entries = [
            self.entry(model: "gpt-5", timestamp: 1),
            self.entry(model: "claude-opus-4-7", timestamp: 2),
            self.entry(model: "gpt-5", timestamp: 3),
        ]
        let selected: Set<String> = ["gpt-5", "claude-opus-4-7"]

        let filtered = self.filter(entries: entries, selected: selected)

        XCTAssertEqual(filtered.map(\.timestamp), [
            self.date(1),
            self.date(2),
            self.date(3),
        ])
    }

    func test_filterUnknownModel_dropsEntry() {
        let entries = [
            self.entry(model: "gpt-5", timestamp: 1),
            self.entry(model: "unknown-model", timestamp: 2),
        ]
        let selected: Set<String> = ["gpt-5"]

        let filtered = self.filter(entries: entries, selected: selected)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.modelId, "gpt-5")
    }

    // MARK: - Helpers

    private func filter(entries: [OpenCodeRequestLogEntry], selected: Set<String>) -> [OpenCodeRequestLogEntry] {
        guard !selected.isEmpty else { return [] }
        return entries.filter { selected.contains($0.modelId) }
    }

    private func entry(model: String, timestamp: Int) -> OpenCodeRequestLogEntry {
        OpenCodeRequestLogEntry(
            id: "\(model)-\(timestamp)",
            sessionId: "session-\(timestamp)",
            timestamp: self.date(timestamp),
            modelId: model,
            providerId: nil,
            inputTokens: 0,
            outputTokens: 0,
            reasoningTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            costUSD: 0)
    }

    private func date(_ timestamp: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp))
    }
}
