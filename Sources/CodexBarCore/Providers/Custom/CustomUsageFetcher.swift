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
            "Missing Custom provider access token. Set apiKey in config.json or CUSTOM_PROVIDER_API_KEY."
        case .missingBaseURL:
            "Missing Custom provider base URL. Set enterpriseHost in config.json or CUSTOM_PROVIDER_BASE_URL."
        case let .apiError(message):
            "Custom provider API error: \(message)"
        case let .parseFailed(message):
            "Custom provider parse error: \(message)"
        }
    }
}

/// Usage pulled from a new-api / one-api / sub2api relay's `/api/user/self`
/// endpoint (the same source cc-switch reads). `quota` is the remaining balance
/// and `used_quota` the amount spent, both in new-api "quota units" where
/// 500,000 units = US$1.
public struct CustomUsageSnapshot: Codable, Sendable, Equatable {
    /// new-api stores balances in integer "quota" units; 500,000 == US$1.
    public static let unitsPerUSD: Double = 500_000

    public let remainingUSD: Double
    public let usedUSD: Double
    public let planName: String?
    public let updatedAt: Date

    public var totalUSD: Double {
        self.remainingUSD + self.usedUSD
    }

    public init(remainingUSD: Double, usedUSD: Double, planName: String?, updatedAt: Date) {
        self.remainingUSD = remainingUSD
        self.usedUSD = usedUSD
        self.planName = planName
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot(for provider: UsageProvider = .custom) -> UsageSnapshot {
        let total = self.totalUSD
        let usedPercent: Double? = total > 0 ? max(0, min(100, self.usedUSD / total * 100)) : nil
        return UsageSnapshot(
            primary: usedPercent.map {
                RateWindow(usedPercent: $0, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
            },
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: self.usedUSD,
                limit: total,
                currencyCode: "USD",
                period: "Balance",
                updatedAt: self.updatedAt),
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: provider,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: self.planName))
    }
}

private struct NewAPIUserSelfResponse: Decodable {
    struct UserData: Decodable {
        let quota: Double?
        let usedQuota: Double?
        let group: String?

        private enum CodingKeys: String, CodingKey {
            case quota
            case usedQuota = "used_quota"
            case group
        }
    }

    let success: Bool?
    let message: String?
    let data: UserData?
}

public struct CustomUsageFetcher: Sendable {
    public init() {}

    public static func fetchUsage(
        accessToken: String,
        baseURL: URL,
        userID: String?,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        updatedAt: Date = Date()) async throws -> CustomUsageSnapshot
    {
        guard !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CustomUsageError.missingCredentials
        }

        var request = URLRequest(url: self.userSelfURL(baseURL: baseURL))
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let userID, !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue(userID, forHTTPHeaderField: "New-Api-User")
        }

        let response = try await transport.response(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw CustomUsageError.apiError("HTTP \(response.statusCode): \(self.responseSummary(response.data))")
        }
        return try self.parse(data: response.data, updatedAt: updatedAt)
    }

    public static func _userSelfURLForTesting(baseURL: URL) -> URL {
        self.userSelfURL(baseURL: baseURL)
    }

    public static func _parseForTesting(_ data: Data, updatedAt: Date) throws -> CustomUsageSnapshot {
        try self.parse(data: data, updatedAt: updatedAt)
    }

    private static func parse(data: Data, updatedAt: Date) throws -> CustomUsageSnapshot {
        do {
            let decoded = try JSONDecoder().decode(NewAPIUserSelfResponse.self, from: data)
            guard let user = decoded.data else {
                throw CustomUsageError.apiError(decoded.message ?? "No user data returned.")
            }
            let units = CustomUsageSnapshot.unitsPerUSD
            return CustomUsageSnapshot(
                remainingUSD: (user.quota ?? 0) / units,
                usedUSD: (user.usedQuota ?? 0) / units,
                planName: user.group?.isEmpty == false ? user.group : nil,
                updatedAt: updatedAt)
        } catch let error as CustomUsageError {
            throw error
        } catch {
            throw CustomUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func userSelfURL(baseURL: URL) -> URL {
        // Strip a trailing /v1 the user may have copied from an inference base URL.
        var root = baseURL
        if root.lastPathComponent == "v1" {
            root = root.deletingLastPathComponent()
        }
        return root.appendingPathComponent("api").appendingPathComponent("user").appendingPathComponent("self")
    }

    private static func responseSummary(_ data: Data) -> String {
        String(bytes: data.prefix(500), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
    }
}
