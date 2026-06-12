import Foundation

/// Reads the base URL + API key for the user-defined "Custom" provider, an
/// OpenAI-compatible billing endpoint (new-api / one-api / sub2api style).
public enum CustomSettingsReader {
    public static let apiKeyEnvironmentKey = "CUSTOM_PROVIDER_API_KEY"
    public static let baseURLEnvironmentKey = "CUSTOM_PROVIDER_BASE_URL"

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.apiKeyEnvironmentKey])
    }

    public static func baseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        guard let raw = self.cleaned(environment[self.baseURLEnvironmentKey]) else { return nil }
        return URL(string: raw)
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
