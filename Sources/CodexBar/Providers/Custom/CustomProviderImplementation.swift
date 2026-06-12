import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct CustomProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .custom

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.customAPIKey
        _ = settings.customBaseURL
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        ProviderTokenResolver.customToken(environment: context.environment) != nil &&
            CustomSettingsReader.baseURL(environment: context.environment) != nil
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "custom-base-url",
                title: "Base URL",
                subtitle: "OpenAI-compatible endpoint (new-api / one-api / sub2api).",
                kind: .plain,
                placeholder: "https://api.example.com",
                binding: context.stringBinding(\.customBaseURL),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "custom-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. Used for /v1/dashboard/billing.",
                kind: .secure,
                placeholder: "sk-…",
                binding: context.stringBinding(\.customAPIKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
