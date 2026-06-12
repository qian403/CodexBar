import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CustomUsageError: LocalizedError, Sendable {
    case missingCredentials
    case missingBaseURL
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing Custom provider API key. Set apiKey in ~/.codexbar/config.json or CUSTOM_PROVIDER_API_KEY."
        case .missingBaseURL:
            "Missing Custom provider base URL. Set enterpriseHost in config.json or CUSTOM_PROVIDER_BASE_URL."
        case let .apiError(message):
            "Custom provider API error: \(message)"
        case let .parseFailed(message):
            "Custom provider parse error: \(message)"
        }
    }
}

/// Usage pulled from an OpenAI-compatible billing API (new-api / one-api / sub2api):
/// `/v1/dashboard/billing/subscription` for the quota cap and
/// `/v1/dashboard/billing/usage` for the amount used.
public struct CustomUsageSnapshot: Codable, Sendable, Equatable {
    public let hardLimitUSD: Double?
    public let usedUSD: Double
    public let updatedAt: Date

    public init(hardLimitUSD: Double?, usedUSD: Double, updatedAt: Date) {
        self.hardLimitUSD = hardLimitUSD
        self.usedUSD = usedUSD
        self.updatedAt = updatedAt
    }

    public var remainingUSD: Double? {
        guard let limit = self.hardLimitUSD else { return nil }
        return max(0, limit - self.usedUSD)
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let usedPercent: Double? = {
            guard let limit = self.hardLimitUSD, limit > 0 else { return nil }
            return max(0, min(100, self.usedUSD / limit * 100))
        }()
        return UsageSnapshot(
            primary: usedPercent.map {
                RateWindow(usedPercent: $0, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
            },
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: self.usedUSD,
                limit: self.hardLimitUSD ?? 0,
                currencyCode: "USD",
                period: "Quota",
                updatedAt: self.updatedAt),
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .custom,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "billing-api"))
    }
}

private struct CustomSubscriptionResponse: Decodable {
    let hardLimitUSD: Double?

    private enum CodingKeys: String, CodingKey {
        case hardLimitUSD = "hard_limit_usd"
        case systemHardLimitUSD = "system_hard_limit_usd"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hardLimitUSD =
            try container.decodeIfPresent(Double.self, forKey: .hardLimitUSD)
            ?? container.decodeIfPresent(Double.self, forKey: .systemHardLimitUSD)
    }
}

private struct CustomUsageResponse: Decodable {
    /// `total_usage` is reported in US cents by the OpenAI billing API.
    let totalUsageCents: Double

    private enum CodingKeys: String, CodingKey {
        case totalUsageCents = "total_usage"
    }
}

public struct CustomUsageFetcher: Sendable {
    public init() {}

    public static func fetchUsage(
        apiKey: String,
        baseURL: URL,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: Date = Date(),
        updatedAt: Date = Date()) async throws -> CustomUsageSnapshot
    {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CustomUsageError.missingCredentials
        }

        let subscription = try await self.decode(
            CustomSubscriptionResponse.self,
            url: self.billingURL(baseURL: baseURL, path: "subscription"),
            apiKey: apiKey,
            transport: transport)

        let (start, end) = self.usageDateRange(now: now)
        let usageURL = self.billingURL(
            baseURL: baseURL,
            path: "usage",
            queryItems: [
                URLQueryItem(name: "start_date", value: start),
                URLQueryItem(name: "end_date", value: end),
            ])
        let usage = try await self.decode(
            CustomUsageResponse.self,
            url: usageURL,
            apiKey: apiKey,
            transport: transport)

        return CustomUsageSnapshot(
            hardLimitUSD: subscription.hardLimitUSD,
            usedUSD: usage.totalUsageCents / 100,
            updatedAt: updatedAt)
    }

    public static func _billingURLForTesting(baseURL: URL, path: String) -> URL {
        self.billingURL(baseURL: baseURL, path: path)
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        url: URL,
        apiKey: String,
        transport: any ProviderHTTPTransport) async throws -> T
    {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await transport.response(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw CustomUsageError.apiError("HTTP \(response.statusCode): \(self.responseSummary(response.data))")
        }
        do {
            return try JSONDecoder().decode(T.self, from: response.data)
        } catch {
            throw CustomUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func billingURL(
        baseURL: URL,
        path: String,
        queryItems: [URLQueryItem] = []) -> URL
    {
        let trimmed = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let versioned = trimmed.split(separator: "/").last == "v1"
            ? baseURL
            : baseURL.appendingPathComponent("v1")
        let url = versioned
            .appendingPathComponent("dashboard")
            .appendingPathComponent("billing")
            .appendingPathComponent(path)
        guard !queryItems.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.queryItems = queryItems
        return components.url ?? url
    }

    private static func usageDateRange(now: Date) -> (start: String, end: String) {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        let start = Calendar.current.date(byAdding: .day, value: -365, to: now) ?? now
        let end = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
        return (formatter.string(from: start), formatter.string(from: end))
    }

    private static func responseSummary(_ data: Data) -> String {
        String(bytes: data.prefix(500), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
    }
}
