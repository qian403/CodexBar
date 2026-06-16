import CodexBarCore
import Foundation
import Observation

/// Tiny shared `@Observable` that lets views ask the App to open a
/// provider-specific Window. The Window body reads the value on appear
/// and re-fetches whenever the value changes.
@MainActor
@Observable
final class AppOpenWindows {
    static let shared = AppOpenWindows()

    var openCodeRequestLogProvider: UsageProvider?
}
