import CodexBarCore
import Foundation
import Testing

struct CustomUsageFetcherTests {
    @Test
    func `billing url normalizes base and appends path`() throws {
        let base = try #require(URL(string: "https://api.example.com"))
        #expect(CustomUsageFetcher._billingURLForTesting(baseURL: base, path: "subscription")
            .absoluteString == "https://api.example.com/v1/dashboard/billing/subscription")

        let versioned = try #require(URL(string: "https://api.example.com/v1"))
        #expect(CustomUsageFetcher._billingURLForTesting(baseURL: versioned, path: "usage")
            .absoluteString == "https://api.example.com/v1/dashboard/billing/usage")
    }

    @Test
    func `snapshot maps quota to used percent and spend`() {
        let snapshot = CustomUsageSnapshot(hardLimitUSD: 100, usedUSD: 25, updatedAt: Date())
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.providerCost?.used == 25)
        #expect(usage.providerCost?.limit == 100)
        #expect(snapshot.remainingUSD == 75)
    }

    @Test
    func `snapshot without limit omits percent`() {
        let snapshot = CustomUsageSnapshot(hardLimitUSD: nil, usedUSD: 10, updatedAt: Date())
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.providerCost?.used == 10)
        #expect(snapshot.remainingUSD == nil)
    }
}
