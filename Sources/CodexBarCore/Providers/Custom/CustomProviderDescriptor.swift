import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum CustomProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .custom,
            metadata: ProviderMetadata(
                id: .custom,
                displayName: "Custom",
                sessionLabel: "Quota",
                weeklyLabel: "Used",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Custom provider usage",
                cliName: "custom",
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
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [CustomAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "custom",
                aliases: ["new-api", "newapi", "one-api", "oneapi", "sub2api"],
                versionDetector: nil))
    }
}

struct CustomAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "custom.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        ProviderTokenResolver.customToken(environment: context.env) != nil &&
            CustomSettingsReader.baseURL(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = ProviderTokenResolver.customToken(environment: context.env) else {
            throw CustomUsageError.missingCredentials
        }
        guard let baseURL = CustomSettingsReader.baseURL(environment: context.env) else {
            throw CustomUsageError.missingBaseURL
        }
        let usage = try await CustomUsageFetcher.fetchUsage(apiKey: apiKey, baseURL: baseURL)
        return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
