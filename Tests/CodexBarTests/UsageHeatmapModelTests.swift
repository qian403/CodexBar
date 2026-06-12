import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct UsageHeatmapModelTests {
    private func calendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func reference(_ cal: Calendar) -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 6
        comps.day = 12
        comps.hour = 12
        return cal.date(from: comps)!
    }

    private func entry(
        offsetDays: Int,
        tokens: Int,
        cost: Double,
        requests: Int = 0,
        cal: Calendar,
        ref: Date) -> CostUsageDailyReport.Entry
    {
        let date = cal.date(byAdding: .day, value: -offsetDays, to: ref)!
        let key = UsageHeatmapData.dayKey(for: date, calendar: cal)
        return CostUsageDailyReport.Entry(
            date: key,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            requestCount: requests,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
    }

    @Test
    func `stat windows sum the correct days`() {
        let cal = self.calendar()
        let ref = self.reference(cal)
        let daily = [
            self.entry(offsetDays: 0, tokens: 100, cost: 1, cal: cal, ref: ref),
            self.entry(offsetDays: 1, tokens: 200, cost: 2, cal: cal, ref: ref),
            self.entry(offsetDays: 5, tokens: 400, cost: 4, cal: cal, ref: ref),
            self.entry(offsetDays: 20, tokens: 800, cost: 8, cal: cal, ref: ref),
            self.entry(offsetDays: 200, tokens: 1600, cost: 16, cal: cal, ref: ref),
        ]
        let data = UsageHeatmapData.make(daily: daily, reference: ref, calendar: cal)

        #expect(data.stats(within: .today, calendar: cal).tokens == 100)
        #expect(data.stats(within: .threeDays, calendar: cal).tokens == 300)
        #expect(data.stats(within: .sevenDays, calendar: cal).tokens == 700)
        #expect(data.stats(within: .thisMonth, calendar: cal).tokens == 700)
        #expect(data.stats(within: .allTime, calendar: cal).tokens == 3100)
        #expect(data.stats(within: .allTime, calendar: cal).costUSD == 31)
        #expect(data.activeDayCount == 5)
    }

    @Test
    func `entries without usage are dropped`() {
        let cal = self.calendar()
        let ref = self.reference(cal)
        let daily = [
            self.entry(offsetDays: 0, tokens: 0, cost: 0, cal: cal, ref: ref),
            self.entry(offsetDays: 1, tokens: 50, cost: 0, cal: cal, ref: ref),
        ]
        let data = UsageHeatmapData.make(daily: daily, reference: ref, calendar: cal)
        #expect(data.activeDayCount == 1)
        #expect(data.maxTokens == 50)
    }

    @Test
    func `intensity buckets scale against the max`() throws {
        let cal = self.calendar()
        let ref = self.reference(cal)
        let daily = [
            self.entry(offsetDays: 0, tokens: 100, cost: 1, cal: cal, ref: ref),
            self.entry(offsetDays: 20, tokens: 800, cost: 8, cal: cal, ref: ref),
            self.entry(offsetDays: 200, tokens: 1600, cost: 16, cal: cal, ref: ref),
        ]
        let data = UsageHeatmapData.make(daily: daily, reference: ref, calendar: cal)

        let low = try data.daysByKey[UsageHeatmapData.dayKey(
            for: #require(cal.date(byAdding: .day, value: 0, to: ref)), calendar: cal)]
        let mid = try data.daysByKey[UsageHeatmapData.dayKey(
            for: #require(cal.date(byAdding: .day, value: -20, to: ref)), calendar: cal)]
        let high = try data.daysByKey[UsageHeatmapData.dayKey(
            for: #require(cal.date(byAdding: .day, value: -200, to: ref)), calendar: cal)]

        #expect(data.level(for: low, metric: .tokens) == 1)
        #expect(data.level(for: mid, metric: .tokens) == 3)
        #expect(data.level(for: high, metric: .tokens) == 4)
        #expect(data.level(for: nil, metric: .tokens) == 0)
    }

    @Test
    func `grid spans 53 weeks without future days`() {
        let cal = self.calendar()
        let ref = self.reference(cal)
        let daily = [self.entry(offsetDays: 0, tokens: 100, cost: 1, cal: cal, ref: ref)]
        let data = UsageHeatmapData.make(daily: daily, reference: ref, calendar: cal)

        #expect(data.columns.count == UsageHeatmapData.weekColumns)

        let todayKey = UsageHeatmapData.dayKey(for: ref, calendar: cal)
        let allCells = data.columns.flatMap(\.self)
        #expect(allCells.contains { $0.day?.dayKey == todayKey })

        let hasFutureDrawn = allCells.compactMap(\.date).contains { $0 > data.referenceDay }
        #expect(!hasFutureDrawn)
    }
}
