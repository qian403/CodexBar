import CodexBarCore
import Foundation

extension SettingsStore {
    /// User-chosen display name for a custom slot (stored in `workspaceID`).
    func customDisplayName(for provider: UsageProvider) -> String {
        self.configSnapshot.providerConfig(for: provider)?.sanitizedWorkspaceID ?? ""
    }

    func setCustomDisplayName(_ provider: UsageProvider, _ newValue: String) {
        self.updateProviderConfig(provider: provider) { entry in
            entry.workspaceID = self.normalizedConfigValue(newValue)
        }
    }

    /// The name shown in menus, falling back to "Custom"/"Custom N" when unset.
    func resolvedCustomDisplayName(for provider: UsageProvider) -> String {
        let name = self.customDisplayName(for: provider)
        return name.isEmpty ? (provider.customDefaultDisplayName ?? "Custom") : name
    }

    func customAPIKey(for provider: UsageProvider) -> String {
        self.configSnapshot.providerConfig(for: provider)?.sanitizedAPIKey ?? ""
    }

    func setCustomAPIKey(_ provider: UsageProvider, _ newValue: String) {
        self.updateProviderConfig(provider: provider) { entry in
            entry.apiKey = self.normalizedConfigValue(newValue)
        }
        self.logSecretUpdate(provider: provider, field: "apiKey", value: newValue)
    }

    func customBaseURL(for provider: UsageProvider) -> String {
        self.configSnapshot.providerConfig(for: provider)?.sanitizedEnterpriseHost ?? ""
    }

    func setCustomBaseURL(_ provider: UsageProvider, _ newValue: String) {
        self.updateProviderConfig(provider: provider) { entry in
            entry.enterpriseHost = self.normalizedConfigValue(newValue)
        }
    }

    /// new-api `New-Api-User` header value (numeric user id), stored in `region`.
    func customUserID(for provider: UsageProvider) -> String {
        self.configSnapshot.providerConfig(for: provider)?.region ?? ""
    }

    func setCustomUserID(_ provider: UsageProvider, _ newValue: String) {
        self.updateProviderConfig(provider: provider) { entry in
            entry.region = self.normalizedConfigValue(newValue)
        }
    }

    /// Whether a custom slot has been configured (named or given a base URL).
    func isCustomSlotConfigured(_ provider: UsageProvider) -> Bool {
        !self.customDisplayName(for: provider).isEmpty || !self.customBaseURL(for: provider).isEmpty
    }
}
