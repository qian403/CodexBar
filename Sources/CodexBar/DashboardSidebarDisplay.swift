import Foundation

/// What value the dashboard sidebar shows on the right side of each provider
/// row. Defaults to `.tokens` to match the existing on-disk-snapshot-driven
/// behavior; users who prefer the provider's own session-window percent can
/// switch to `.percent` (matching the legacy fallback that still applies to
/// providers without a daily token snapshot, e.g. Gemini).
enum DashboardSidebarDisplay: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Show the day's token total from the daily token snapshot when present;
    /// fall back to `snapshot.primary.usedPercent` when the provider has no
    /// daily snapshot (current behavior for the bottom of the sidebar).
    case tokens
    /// Always show `snapshot.primary.usedPercent` regardless of whether a
    /// daily token snapshot exists. Useful for cross-provider comparison
    /// against the same scale.
    case percent

    var id: String {
        self.rawValue
    }

    var label: String {
        switch self {
        case .tokens: L("dashboard_sidebar_value_tokens")
        case .percent: L("dashboard_sidebar_value_percent")
        }
    }
}
