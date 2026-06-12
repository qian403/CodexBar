import SwiftUI

/// GitHub-style calendar heatmap drawn with `Canvas` for cheap redraws over ~370
/// cells. Reports hover (for the floating tooltip) and tap (to pin a day) back to
/// the parent via closures, keeping this view stateless.
struct TokenHeatmapView: View {
    let data: UsageHeatmapData
    let metric: HeatmapMetric
    let baseColor: Color
    let selectedDayKey: String?
    let onHover: (HeatmapCell?, CGPoint?) -> Void
    let onSelect: (HeatmapCell) -> Void

    static let cellSize: CGFloat = 11
    static let cellSpacing: CGFloat = 3
    private var step: CGFloat {
        Self.cellSize + Self.cellSpacing
    }

    var gridWidth: CGFloat {
        CGFloat(self.data.columns.count) * self.step - Self.cellSpacing
    }

    var gridHeight: CGFloat {
        7 * self.step - Self.cellSpacing
    }

    var body: some View {
        Canvas { context, _ in
            for column in self.data.columns {
                for cell in column {
                    guard cell.isDrawable else { continue }
                    let rect = self.cellRect(column: cell.column, row: cell.row)
                    let level = self.data.level(for: cell.day, metric: self.metric)
                    let path = Path(roundedRect: rect, cornerRadius: 2)
                    context.fill(path, with: .color(self.fill(for: level)))
                    if let selectedDayKey, cell.day?.dayKey == selectedDayKey {
                        context.stroke(
                            Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: 3),
                            with: .color(Color.primary.opacity(0.85)),
                            lineWidth: 1.5)
                    }
                }
            }
        }
        .frame(width: self.gridWidth, height: self.gridHeight)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case let .active(location):
                if let cell = self.cell(at: location), cell.day != nil {
                    self.onHover(cell, location)
                } else {
                    self.onHover(nil, nil)
                }
            case .ended:
                self.onHover(nil, nil)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    if let cell = self.cell(at: value.location), cell.day != nil {
                        self.onSelect(cell)
                    }
                })
        .accessibilityLabel(L("Usage heatmap"))
        .accessibilityValue(
            String(format: L("%d active days in the last year"), self.data.activeDayCount))
    }

    func fill(for level: Int) -> Color {
        switch level {
        case 0: Color.primary.opacity(0.07)
        case 1: self.baseColor.opacity(0.3)
        case 2: self.baseColor.opacity(0.5)
        case 3: self.baseColor.opacity(0.75)
        default: self.baseColor
        }
    }

    private func cellRect(column: Int, row: Int) -> CGRect {
        CGRect(
            x: CGFloat(column) * self.step,
            y: CGFloat(row) * self.step,
            width: Self.cellSize,
            height: Self.cellSize)
    }

    private func cell(at point: CGPoint) -> HeatmapCell? {
        guard point.x >= 0, point.y >= 0 else { return nil }
        let column = Int(point.x / self.step)
        let row = Int(point.y / self.step)
        guard column >= 0, column < self.data.columns.count, row >= 0, row < 7 else { return nil }
        let withinX = point.x - CGFloat(column) * self.step
        let withinY = point.y - CGFloat(row) * self.step
        guard withinX <= Self.cellSize, withinY <= Self.cellSize else { return nil }
        let cell = self.data.columns[column][row]
        return cell.isDrawable ? cell : nil
    }
}
