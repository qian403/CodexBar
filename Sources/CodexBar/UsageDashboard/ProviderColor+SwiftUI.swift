import CodexBarCore
import SwiftUI

extension ProviderColor {
    /// SwiftUI `Color` matching the descriptor's brand color, in sRGB.
    /// Used by every dashboard/Window surface that paints a per-provider chip
    /// (selection accent, heatmap base, model bars, etc.) so the chip stays
    /// visually consistent across surfaces.
    var swiftUIColor: Color {
        Color(.sRGB, red: self.red, green: self.green, blue: self.blue, opacity: 1)
    }
}
