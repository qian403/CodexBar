import CodexBarCore
import Foundation
import SwiftUI

struct CustomProviderImplementation: ProviderImplementation {
    let id: UsageProvider

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.customDisplayName(for: self.id)
        _ = settings.customAPIKey(for: self.id)
        _ = settings.customBaseURL(for: self.id)
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        ProviderTokenResolver.customToken(for: self.id, environment: context.environment) != nil &&
            CustomSettingsReader.baseURL(for: self.id, environment: context.environment) != nil
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        let provider = self.id
        let settings = context.settings
        return [
            ProviderSettingsFieldDescriptor(
                id: "\(provider.rawValue)-name",
                title: "Display name",
                subtitle: "Shown in the menu and dashboard.",
                kind: .plain,
                placeholder: provider.customDefaultDisplayName ?? "Custom",
                binding: Binding(
                    get: { settings.customDisplayName(for: provider) },
                    set: { settings.setCustomDisplayName(provider, $0) }),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "\(provider.rawValue)-base-url",
                title: "Base URL",
                subtitle: "OpenAI-compatible endpoint (new-api / one-api / sub2api).",
                kind: .plain,
                placeholder: "https://api.example.com",
                binding: Binding(
                    get: { settings.customBaseURL(for: provider) },
                    set: { settings.setCustomBaseURL(provider, $0) }),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "\(provider.rawValue)-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. Used for /v1/dashboard/billing.",
                kind: .secure,
                placeholder: "sk-…",
                binding: Binding(
                    get: { settings.customAPIKey(for: provider) },
                    set: { settings.setCustomAPIKey(provider, $0) }),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
