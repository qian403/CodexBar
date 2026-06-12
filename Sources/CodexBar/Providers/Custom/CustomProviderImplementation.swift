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
                subtitle: "Relay site root (new-api / one-api / sub2api). Reads /api/user/self.",
                kind: .plain,
                placeholder: "https://relay.example.com",
                binding: Binding(
                    get: { settings.customBaseURL(for: provider) },
                    set: { settings.setCustomBaseURL(provider, $0) }),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "\(provider.rawValue)-access-token",
                title: "Access token",
                subtitle: "Account access token from the relay site (not the sk- API key).",
                kind: .secure,
                placeholder: "access token…",
                binding: Binding(
                    get: { settings.customAPIKey(for: provider) },
                    set: { settings.setCustomAPIKey(provider, $0) }),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "\(provider.rawValue)-user-id",
                title: "User ID",
                subtitle: "Numeric account id, sent as the New-Api-User header.",
                kind: .plain,
                placeholder: "123",
                binding: Binding(
                    get: { settings.customUserID(for: provider) },
                    set: { settings.setCustomUserID(provider, $0) }),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
