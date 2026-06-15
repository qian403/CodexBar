import CodexBarCore
import SwiftUI

/// Horizontally-scrolling row of toggle chips, one per model ID.
/// Pre-selected state is "all". Caller owns the `Set<String>` and is
/// notified via `onToggle` / `onSelectAll` / `onDeselectAll`.
struct RequestLogFilterChips: View {
    let models: [String]
    let selected: Set<String>
    let onToggle: (String) -> Void
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(self.models, id: \.self) { model in
                        self.chip(for: model)
                    }
                }
                .padding(.vertical, 2)
            }
            Divider()
                .frame(height: 16)
            HStack(spacing: 6) {
                Button(L("Select all"), action: self.onSelectAll)
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                Button(L("Deselect all"), action: self.onDeselectAll)
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chip(for model: String) -> some View {
        let isOn = self.selected.contains(model)
        return Button {
            self.onToggle(model)
        } label: {
            Text(UsageFormatter.modelDisplayName(model))
                .font(.system(size: 10, weight: isOn ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isOn ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isOn ? Color.accentColor.opacity(0.6) : Color.gray.opacity(0.20))
                )
        }
        .buttonStyle(.plain)
    }
}
