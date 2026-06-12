import CodexBarCore
import Foundation

extension SettingsStore {
    var customAPIKey: String {
        get {
            self.configSnapshot.providerConfig(for: .custom)?.sanitizedAPIKey ?? ""
        }
        set {
            self.updateProviderConfig(provider: .custom) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .custom, field: "apiKey", value: newValue)
        }
    }

    var customBaseURL: String {
        get {
            self.configSnapshot.providerConfig(for: .custom)?.sanitizedEnterpriseHost ?? ""
        }
        set {
            self.updateProviderConfig(provider: .custom) { entry in
                entry.enterpriseHost = self.normalizedConfigValue(newValue)
            }
        }
    }
}
