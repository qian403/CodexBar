import CodexBarCore
import Foundation
import Testing

struct CustomUsageFetcherTests {
    @Test
    func `user self url strips trailing v1 and appends api path`() throws {
        let root = try #require(URL(string: "https://relay.example.com"))
        #expect(CustomUsageFetcher._userSelfURLForTesting(baseURL: root)
            .absoluteString == "https://relay.example.com/api/user/self")

        let versioned = try #require(URL(string: "https://relay.example.com/v1"))
        #expect(CustomUsageFetcher._userSelfURLForTesting(baseURL: versioned)
            .absoluteString == "https://relay.example.com/api/user/self")
    }

    @Test
    func `parses new-api user quota into usd`() throws {
        let json = #"{"success":true,"data":{"quota":1500000,"used_quota":500000,"group":"vip"}}"#
        let data = try #require(json.data(using: .utf8))
        let snapshot = try CustomUsageFetcher._parseForTesting(data, updatedAt: Date())
        #expect(snapshot.remainingUSD == 3)
        #expect(snapshot.usedUSD == 1)
        #expect(snapshot.totalUSD == 4)
        #expect(snapshot.planName == "vip")
    }

    @Test
    func `snapshot maps quota to used percent and spend`() {
        let snapshot = CustomUsageSnapshot(remainingUSD: 75, usedUSD: 25, planName: nil, updatedAt: Date())
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.providerCost?.used == 25)
        #expect(usage.providerCost?.limit == 100)
    }

    @Test
    func `error response surfaces message`() throws {
        let json = #"{"success":false,"message":"unauthorized"}"#
        let data = try #require(json.data(using: .utf8))
        #expect(throws: CustomUsageError.self) {
            try CustomUsageFetcher._parseForTesting(data, updatedAt: Date())
        }
    }
}
