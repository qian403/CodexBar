import Foundation

/// Builds descriptors for each user-configurable "Custom" provider slot. Slots use
/// the OpenAI-compatible billing endpoints (new-api / one-api / sub2api) with a
/// per-slot base URL + API key.
public enum CustomProviderDescriptors {
    public static func descriptor(for provider: UsageProvider) -> ProviderDescriptor {
        let apiKeyEnvironmentKey = CustomSettingsReader.apiKeyEnvironmentKey(for: provider)
        let credentials = ProviderCredentialAdapter.apiKey(
            environmentKey: apiKeyEnvironmentKey,
            additionalProjections: [
                .enterpriseHost(CustomSettingsReader.baseURLEnvironmentKey(for: provider)),
                .region(CustomSettingsReader.userIDEnvironmentKey(for: provider)),
            ],
            resolve: { environment in
                CustomSettingsReader.apiKey(for: provider, environment: environment)
            },
            usesRegion: true)
        return ProviderDescriptor(
            id: provider,
            credentials: credentials,
            config: ProviderConfigCapabilities(supportsEnterpriseHost: true),
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
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: nil,
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: provider),
                iconResourceName: "ProviderIcon-custom",
                color: ProviderColor(red: 124 / 255, green: 132 / 255, blue: 148 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x4B5563),
                    ProviderColor(hex: 0x7C8494),
                    ProviderColor(hex: 0xD1D5DB),
                ]),
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
                // Provider-specific by design: the first Custom slot retains legacy Sub2API aliases.
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
        ProviderTokenResolver.token(for: self.provider, environment: context.env) != nil &&
            CustomSettingsReader.baseURL(for: self.provider, environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = ProviderTokenResolver.token(for: self.provider, environment: context.env) else {
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
