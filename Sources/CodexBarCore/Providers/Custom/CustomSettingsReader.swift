import Foundation

/// Reads the base URL + API key for the user-defined "Custom" provider slots,
/// OpenAI-compatible billing endpoints (new-api / one-api / sub2api style).
/// Each slot has its own environment keys, e.g. `CUSTOM_PROVIDER_API_KEY` for
/// the first slot and `CUSTOM_PROVIDER_2_API_KEY` for the second.
public enum CustomSettingsReader {
    public static func apiKeyEnvironmentKey(for provider: UsageProvider) -> String {
        self.environmentKey(for: provider, suffix: "API_KEY")
    }

    public static func baseURLEnvironmentKey(for provider: UsageProvider) -> String {
        self.environmentKey(for: provider, suffix: "BASE_URL")
    }

    public static func apiKey(
        for provider: UsageProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.apiKeyEnvironmentKey(for: provider)])
    }

    public static func baseURL(
        for provider: UsageProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        guard let raw = self.cleaned(environment[self.baseURLEnvironmentKey(for: provider)]) else { return nil }
        return URL(string: raw)
    }

    public static func userIDEnvironmentKey(for provider: UsageProvider) -> String {
        self.environmentKey(for: provider, suffix: "USER_ID")
    }

    public static func userID(
        for provider: UsageProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.userIDEnvironmentKey(for: provider)])
    }

    private static func environmentKey(for provider: UsageProvider, suffix: String) -> String {
        let index = provider.customIndex ?? 1
        return index <= 1 ? "CUSTOM_PROVIDER_\(suffix)" : "CUSTOM_PROVIDER_\(index)_\(suffix)"
    }

    static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
