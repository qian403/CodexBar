import Foundation

/// Builds descriptors for each user-configurable "Custom" provider slot. Slots use
/// the OpenAI-compatible billing endpoints (new-api / one-api / sub2api) with a
/// per-slot base URL + API key.
public enum CustomProviderDescriptors {
    public static func descriptor(for provider: UsageProvider) -> ProviderDescriptor {
        ProviderDescriptor(
            id: provider,
            metadata: ProviderMetadata(
                id: provider,
                displayName: provider.customDefaultDisplayName ?? "Custom",
                sessionLabel: "Quota",
                weeklyLabel: "Used",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show \(provider.customDefaultDisplayName ?? "Custom") usage",
                cliName: provider.rawValue,
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: nil,
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .custom,
                iconResourceName: "ProviderIcon-custom",
                color: ProviderColor(red: 124 / 255, green: 132 / 255, blue: 148 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Custom provider spend is shown in the usage limits." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                    [CustomAPIFetchStrategy(provider: provider)]
                })),
            cli: ProviderCLIConfig(
                name: provider.rawValue,
                aliases: provider == .custom ? ["new-api", "newapi", "one-api", "oneapi", "sub2api"] : [],
                versionDetector: nil))
    }
}

struct CustomAPIFetchStrategy: ProviderFetchStrategy {
    let provider: UsageProvider
    let kind: ProviderFetchKind = .apiToken

    var id: String {
        "\(self.provider.rawValue).api"
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        ProviderTokenResolver.customToken(for: self.provider, environment: context.env) != nil &&
            CustomSettingsReader.baseURL(for: self.provider, environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = ProviderTokenResolver.customToken(for: self.provider, environment: context.env) else {
            throw CustomUsageError.missingCredentials
        }
        guard let baseURL = CustomSettingsReader.baseURL(for: self.provider, environment: context.env) else {
            throw CustomUsageError.missingBaseURL
        }
        let userID = CustomSettingsReader.userID(for: self.provider, environment: context.env)
        let usage = try await CustomUsageFetcher.fetchUsage(
            accessToken: apiKey,
            baseURL: baseURL,
            userID: userID)
        return self.makeResult(usage: usage.toUsageSnapshot(for: self.provider), sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
