import Charts
import CodexBarCore
import Foundation
import SwiftUI

/// Interactive cost / token trend chart for the usage dashboard.
///
/// Wraps SwiftUI Charts with `onContinuousHover` + `chartOverlay` so the user
/// gets an inline tooltip (date · value · request count · top model breakdown)
/// plus a vertical guide line and a highlighted point at the hovered day. The
/// hovered day also syncs to the parent dashboard's `selectedDayKey`, which
/// drives the day breakdown section below the chart — making the chart itself
/// the primary way to drill into a specific day.
struct TrendChart: View {
    let points: [TrendPoint]
    let usesCost: Bool
    let costString: (Double) -> String
    let selectionColor: Color
    @Binding var selectedDayKey: String?
    let lookupDay: (Date) -> HeatmapDay?

    /// Maximum number of model rows in the hover tooltip. Three keeps the
    /// card compact and matches the typical "what did I run today" question.
    private let breakdownLimit = 3

    @State private var hoverPoint: TrendPoint?
    @State private var hoverLocation: CGPoint?

    var body: some View {
        Chart {
            ForEach(self.points) { point in
                AreaMark(
                    x: .value("Date", point.date, unit: .day),
                    y: .value("Value", point.value))
                    .foregroundStyle(self.selectionColor.opacity(0.15))
                LineMark(
                    x: .value("Date", point.date, unit: .day),
                    y: .value("Value", point.value))
                    .foregroundStyle(self.selectionColor)
                    .interpolationMethod(.monotone)
            }
            if let point = self.hoverPoint {
                RuleMark(x: .value("Date", point.date, unit: .day))
                    .foregroundStyle(self.selectionColor.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(
                    x: .value("Date", point.date, unit: .day),
                    y: .value("Value", point.value))
                    .foregroundStyle(self.selectionColor)
                    .symbolSize(60)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(self.axisLabel(number))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisGridLine().foregroundStyle(Color.clear)
                AxisValueLabel(format: .dateTime.month(.abbreviated))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 110)
        .chartOverlay { proxy in
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            self.handleHover(phase: phase, proxy: proxy, geo: geo)
                        }
                    if let point = self.hoverPoint,
                       let location = self.hoverLocation,
                       let day = self.lookupDay(point.date)
                    {
                        HoverTooltip(
                            day: day,
                            usesCost: self.usesCost,
                            costString: self.costString,
                            breakdownLimit: self.breakdownLimit)
                            .fixedSize()
                            .offset(x: self.tooltipOffsetX(
                                hoverX: location.x,
                                proxy: proxy,
                                geo: geo))
                            .offset(y: -8)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private func axisLabel(_ value: Double) -> String {
        if self.usesCost {
            return self.costString(value)
        }
        return UsageFormatter.tokenCountString(Int(value))
    }

    /// Map a hover position to the nearest data point + sync the dashboard's
    /// selected-day state. We snap to the nearest point (rather than the raw
    /// x coordinate) so the tooltip stays anchored to a real data row instead
    /// of jittering between days.
    private func handleHover(
        phase: HoverPhase,
        proxy: ChartProxy,
        geo: GeometryProxy)
    {
        switch phase {
        case let .active(location):
            guard let plotFrame = proxy.plotFrame.map({ geo[$0] }) else {
                self.clearHover()
                return
            }
            let localX = location.x - plotFrame.origin.x
            guard localX >= 0, localX <= plotFrame.width else {
                self.clearHover()
                return
            }
            guard let rawDate: Date = proxy.value(atX: localX) else {
                self.clearHover()
                return
            }
            let nearest = self.nearestPoint(to: rawDate)
            self.hoverPoint = nearest
            self.hoverLocation = location
            self.selectedDayKey = self.lookupDay(nearest.date)?.dayKey
        case .ended:
            self.clearHover()
        }
    }

    private func clearHover() {
        self.hoverPoint = nil
        self.hoverLocation = nil
    }

    private func nearestPoint(to date: Date) -> TrendPoint {
        guard !self.points.isEmpty else {
            return TrendPoint(date: date, value: 0)
        }
        return self.points.min(by: { lhs, rhs in
            abs(lhs.date.timeIntervalSince(date)) < abs(rhs.date.timeIntervalSince(date))
        }) ?? self.points[0]
    }

    /// Pin the tooltip near the hovered point but keep it inside the chart
    /// bounds. We prefer to anchor on the right side of the point when the
    /// point sits in the right half of the chart so the card doesn't run off
    /// the trailing edge.
    private func tooltipOffsetX(
        hoverX: CGFloat,
        proxy: ChartProxy,
        geo: GeometryProxy) -> CGFloat
    {
        guard let plotFrame = proxy.plotFrame.map({ geo[$0] }) else { return 0 }
        let tooltipWidth: CGFloat = 180
        let preferLeft = hoverX > plotFrame.midX
        let raw = preferLeft
            ? hoverX - tooltipWidth - 6
            : hoverX + 6
        let minX: CGFloat = 4
        let maxX = max(minX, plotFrame.width - tooltipWidth - 4)
        return min(max(raw, minX), maxX)
    }
}

/// Floating card rendered above the trend chart on hover. Self-contained so
/// the trend chart's `chartOverlay` doesn't need to know about layout.
private struct HoverTooltip: View {
    let day: HeatmapDay
    let usesCost: Bool
    let costString: (Double) -> String
    let breakdownLimit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.formattedDate)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(self.primaryValue)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                if self.usesCost {
                    Text(L("tokens"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        + Text(" · ")
                        + Text(self.tokenText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Text(self.requestText)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            if !self.topBreakdowns.isEmpty {
                Divider().padding(.vertical, 2)
                ForEach(Array(self.topBreakdowns.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(self.color(for: item.model))
                            .frame(width: 5, height: 5)
                        Text(UsageFormatter.modelDisplayName(item.model))
                            .font(.system(size: 10))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(self.costString(item.cost))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: 180, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96)))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.12)))
        .shadow(color: Color.black.opacity(0.18), radius: 4, y: 2)
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.locale = codexBarLocalizedLocale()
        formatter.setLocalizedDateFormatFromTemplate("yyyyMMMd")
        return formatter.string(from: self.day.date)
    }

    private var primaryValue: String {
        if self.usesCost {
            return self.costString(self.day.costUSD)
        }
        return UsageFormatter.tokenCountString(self.day.tokens)
    }

    private var tokenText: String {
        UsageFormatter.tokenCountString(self.day.tokens) + " " + L("tokens")
    }

    private var requestText: String {
        let count = self.day.requests
        let format = count == 1 ? L("1 request") : L("%d requests")
        return String(format: format, count)
    }

    private struct BreakdownItem {
        let model: String
        let cost: Double
    }

    private var topBreakdowns: [BreakdownItem] {
        let items = (self.day.entry.modelBreakdowns ?? [])
            .compactMap { breakdown -> BreakdownItem? in
                guard let cost = breakdown.costUSD, cost > 0 else { return nil }
                return BreakdownItem(model: breakdown.modelName, cost: cost)
            }
            .sorted { $0.cost > $1.cost }
        return Array(items.prefix(self.breakdownLimit))
    }

    private func color(for modelName: String) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .yellow, .red]
        let hash = abs(modelName.hashValue)
        return palette[hash % palette.count]
    }
}

/// One point on the trend chart. Kept separate from `HeatmapDay` so the chart
/// can plot a different metric (cost vs tokens) without a separate struct.
struct TrendPoint: Identifiable, Hashable {
    let date: Date
    let value: Double

    var id: TimeInterval {
        self.date.timeIntervalSince1970
    }
}
