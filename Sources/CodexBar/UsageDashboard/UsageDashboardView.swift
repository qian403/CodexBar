import AppKit
import Charts
import CodexBarCore
import SwiftUI
import UniformTypeIdentifiers

enum UsageDashboardWindow {
    static let id = "usageWindow"
}

enum OpenCodeRequestLogWindow {
    static let id = "opencode-request-log"
}

/// What the dashboard is currently focused on: the combined total across every
/// provider, or a single provider.
enum DashboardSelection: Hashable {
    case overview
    case provider(UsageProvider)
}

/// How wide a window the heatmap renders. Data is always fetched for a full year;
/// this only controls how many week-columns are drawn.
enum HeatmapRange: String, CaseIterable, Hashable {
    case threeMonths
    case year

    var weeks: Int {
        switch self {
        case .threeMonths: 13
        case .year: 53
        }
    }

    var title: String {
        switch self {
        case .threeMonths: L("3 months")
        case .year: L("1 year")
        }
    }
}

@MainActor
struct UsageDashboardView: View {
    @Bindable var store: UsageStore
    @Bindable var settings: SettingsStore

    @Environment(\.openWindow) private var openWindowEnv

    @State private var selection: DashboardSelection = .overview
    @State private var range: HeatmapRange = .year
    @State private var selectedDayKey: String?
    @State private var hoveredCell: HeatmapCell?
    @State private var cachedHeatmap: UsageHeatmapData = .make(daily: [])
    @State private var extendedDaily: [UsageProvider: [CostUsageDailyReport.Entry]] = [:]

    var body: some View {
        HStack(spacing: 0) {
            self.sidebar
            Divider()
            self.detail
        }
        .frame(minWidth: 820, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { self.bootstrapSelectionIfNeeded() }
        .onChange(of: self.dashboardProviders) { _, _ in self.bootstrapSelectionIfNeeded() }
        .onChange(of: self.selection) { _, _ in
            self.selectedDayKey = nil
            self.refreshHeatmap()
        }
        .onChange(of: self.range) { _, _ in self.refreshHeatmap() }
        .onChange(of: self.dailySignature) { _, _ in self.refreshHeatmap() }
        .task(id: self.selection) { await self.loadExtendedForSelection() }
        .task(id: self.requestLogReloadKey) { await self.loadRequestLogForSelection() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 1) {
                    self.selectionRow(
                        .overview,
                        title: L("Overview"),
                        color: .accentColor,
                        value: self.overviewSidebarValue,
                        systemImage: "square.grid.2x2")

                    Text(L("Providers"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.top, 10)
                        .padding(.bottom, 2)

                    ForEach(self.dashboardProviders, id: \.self) { provider in
                        self.selectionRow(
                            .provider(provider),
                            title: self.store.metadata(for: provider).displayName,
                            color: self.color(for: provider),
                            value: self.sidebarValue(for: provider),
                            systemImage: nil)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 12)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 200)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func selectionRow(
        _ target: DashboardSelection,
        title: String,
        color: Color,
        value: String,
        systemImage: String?) -> some View
    {
        let isSelected = target == self.selection
        return Button {
            self.selection = target
        } label: {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10))
                        .foregroundStyle(color)
                        .frame(width: 9, height: 9)
                } else {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: 9, height: 9)
                }
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(value)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.primary.opacity(0.1) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if self.dashboardProviders.isEmpty {
            self.emptyState
        } else {
            let hasToken = !self.cachedHeatmap.isEmpty
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    self.header(hasToken: hasToken)
                    if case let .provider(provider) = self.selection {
                        self.limitsSection(provider: provider)
                    }
                    if hasToken {
                        self.heatmapSection
                        self.statsSection
                        self.metricsRow
                        self.trendSection
                        self.modelsSection
                        if self.shouldShowRequestLog {
                            self.requestLogSection
                        }
                        self.daySection
                    } else {
                        self.noTokenHistoryNote
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func header(hasToken: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(self.selectionColor)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text(self.selectionTitle)
                        .font(.system(size: 16, weight: .semibold))
                    if let plan = self.planText {
                        Text(plan)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(self.selectionColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(self.selectionColor.opacity(0.15)))
                    }
                }
                if let subtitle = self.headerSubtitle(hasToken: hasToken) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if hasToken {
                Picker("", selection: self.$range) {
                    ForEach(HeatmapRange.allCases, id: \.self) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Menu {
                    Button(L("Export as CSV")) { self.export(asJSON: false) }
                    Button(L("Export as JSON")) { self.export(asJSON: true) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L("Export usage"))
            }
            Button {
                NotificationCenter.default.post(name: .codexbarOpenSettings, object: nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help(L("Settings..."))
        }
    }

    private var noTokenHistoryNote: some View {
        Text(L("No daily token usage to chart for this provider."))
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    // MARK: Limits & resets

    private struct LimitRow: Identifiable {
        let id: String
        let title: String
        let usedPercent: Double
        let resetText: String?
    }

    @ViewBuilder
    private func limitsSection(provider: UsageProvider) -> some View {
        let rows = self.limitRows(provider: provider)
        let spend = self.spendText(provider: provider)
        if !rows.isEmpty || spend != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Usage limits"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                ForEach(rows) { row in
                    self.limitRowView(provider: provider, row: row)
                }
                if let spend {
                    HStack(spacing: 6) {
                        Text(L("Spend"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(spend)
                            .font(.system(size: 11))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
                if let updated = self.updatedText(provider: provider) {
                    Text(updated)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
        }
    }

    private func limitRowView(provider: UsageProvider, row: LimitRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(row.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(UsageFormatter.usageLine(
                    remaining: 100 - row.usedPercent,
                    used: row.usedPercent,
                    showUsed: true))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let reset = row.resetText {
                    Text("·").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Text(reset)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule()
                        .fill(self.color(for: provider))
                        .frame(width: geo.size.width * CGFloat(min(100, max(0, row.usedPercent)) / 100))
                }
            }
            .frame(height: 6)
        }
    }

    private func limitRows(provider: UsageProvider) -> [LimitRow] {
        guard let snapshot = self.store.snapshot(for: provider) else { return [] }
        let meta = self.store.metadata(for: provider)
        let style = self.settings.resetTimeDisplayStyle
        var rows: [LimitRow] = []

        func add(_ id: String, _ title: String, _ window: RateWindow?) {
            guard let window else { return }
            rows.append(LimitRow(
                id: id,
                title: title,
                usedPercent: window.usedPercent,
                resetText: UsageFormatter.resetLine(for: window, style: style)))
        }

        add("primary", L(meta.sessionLabel), snapshot.primary)
        add("secondary", L(meta.weeklyLabel), snapshot.secondary)
        if meta.supportsOpus, let opus = meta.opusLabel {
            add("tertiary", L(opus), snapshot.tertiary)
        }
        for extra in snapshot.extraRateWindows ?? [] {
            add("extra-\(extra.id)", L(extra.title), extra.window)
        }
        return rows
    }

    private func updatedText(provider: UsageProvider) -> String? {
        guard let snapshot = self.store.snapshot(for: provider) else { return nil }
        return UsageFormatter.updatedString(from: snapshot.updatedAt)
    }

    private func spendText(provider: UsageProvider) -> String? {
        guard let cost = self.store.snapshot(for: provider)?.providerCost else { return nil }
        let used = UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
        let limit = UsageFormatter.currencyString(cost.limit, currencyCode: cost.currencyCode)
        var text = cost.limit > 0 ? "\(used) / \(limit)" : used
        if let period = cost.period, !period.isEmpty {
            text += " · \(L(period))"
        }
        if let resets = cost.resetsAt {
            let window = RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: resets,
                resetDescription: nil)
            if let reset = UsageFormatter.resetLine(for: window, style: self.settings.resetTimeDisplayStyle) {
                text += " · \(reset)"
            }
        }
        return text
    }

    // MARK: Request log (OpenCode only)

    /// Only OpenCode and OpenCode Go expose per-request granularity today;
    /// Codex/Claude/VertexAI readers don't produce per-message entries.
    private var shouldShowRequestLog: Bool {
        if case let .provider(provider) = self.selection,
           provider == .opencode || provider == .opencodego
        {
            return true
        }
        return false
    }

    /// Combined key so the request log reloads when either selection or range
    /// changes (range affects how many days of data we scan).
    private var requestLogReloadKey: String {
        let providerPart: String = if case let .provider(provider) = self.selection {
            provider.rawValue
        } else {
            "overview"
        }
        return "\(providerPart)-\(self.range.weeks)"
    }

    @ViewBuilder
    private var requestLogSection: some View {
        if case let .provider(provider) = self.selection,
           let log = self.store.openCodeRequestLog(for: provider)
        {
            OpenCodeRequestLogView(
                log: log,
                selectionColor: self.selectionColor,
                onViewAll: { self.openViewAll(for: provider) })
        } else {
            // Empty placeholder so the layout doesn't jump when the log is
            // still loading. Mirrors the heatmap's "no data" treatment.
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Recent requests"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(L("Loading OpenCode request log…"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
        }
    }

    private func openViewAll(for provider: UsageProvider) {
        AppOpenWindows.shared.openCodeRequestLogProvider = provider
        NSApp.activate(ignoringOtherApps: true)
        self.openWindowEnv(id: OpenCodeRequestLogWindow.id)
    }

    private func loadRequestLogForSelection() async {
        guard case let .provider(provider) = self.selection,
              provider == .opencode || provider == .opencodego
        else { return }
        await self.store.loadOpenCodeRequestLog(
            for: provider,
            rangeWeeks: self.range.weeks)
    }

    // MARK: Heatmap

    private var heatmapSection: some View {
        let data = self.cachedHeatmap
        return VStack(alignment: .leading, spacing: 6) {
            self.monthLabels(data: data)
            TokenHeatmapView(
                data: data,
                metric: .tokens,
                baseColor: self.selectionColor,
                selectedDayKey: self.selectedDayKey,
                onHover: { cell, _ in
                    self.hoveredCell = cell
                },
                onSelect: { cell in
                    self.selectedDayKey = cell.day?.dayKey
                })
            self.legend
            self.hoverReadout
        }
    }

    /// Fixed-height readout for the hovered day. A floating tooltip would overflow the
    /// short heatmap grid and cover the legend/stats below, so the detail is shown on a
    /// reserved line instead.
    private var hoverReadout: some View {
        HStack(spacing: 7) {
            if let day = self.hoveredCell?.day {
                Text(self.fullDateString(day.date))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(self.dayDetailString(day: day))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
            } else {
                Text(L("Hover a day to see usage."))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 18, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    private func monthLabels(data: UsageHeatmapData) -> some View {
        let step = TokenHeatmapView.cellSize + TokenHeatmapView.cellSpacing
        return ZStack(alignment: .topLeading) {
            ForEach(data.monthLabels, id: \.column) { item in
                Text(item.label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .offset(x: CGFloat(item.column) * step)
            }
        }
        .frame(height: 12, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var legend: some View {
        let dummy = UsageHeatmapData.make(daily: [])
        let heat = TokenHeatmapView(
            data: dummy,
            metric: .tokens,
            baseColor: self.selectionColor,
            selectedDayKey: nil,
            onHover: { _, _ in },
            onSelect: { _ in })
        return HStack(spacing: 5) {
            Spacer()
            Text(L("Less")).font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(heat.fill(for: level))
                    .frame(width: 10, height: 10)
            }
            Text(L("More")).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    // MARK: Stats

    private var statsSection: some View {
        HStack(spacing: 8) {
            self.statCard(L("Today"), window: .today)
            self.statCard(L("3 days"), window: .threeDays)
            self.statCard(L("7 days"), window: .sevenDays)
            self.statCard(L("This month"), window: .thisMonth)
            self.statCard(L("All time"), window: .allTime)
        }
    }

    private func statCard(_ title: String, window: UsageHeatmapData.StatWindow) -> some View {
        let stats = self.cachedHeatmap.stats(within: window)
        return VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(UsageFormatter.tokenCountString(stats.tokens))
                .font(.system(size: 16, weight: .semibold))
            Text(stats.costUSD > 0 ? self.costString(stats.costUSD) : " ")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
    }

    // MARK: Requests & cache

    @ViewBuilder
    private var metricsRow: some View {
        let totals = self.aggregateTotals()
        let items = self.metricItems(from: totals)
        if !items.isEmpty {
            HStack(spacing: 18) {
                ForEach(items, id: \.label) { item in
                    HStack(spacing: 5) {
                        Image(systemName: item.icon)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(item.label)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(item.value)
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private struct MetricItem {
        let icon: String
        let label: String
        let value: String
    }

    private func metricItems(from totals: AggregateTotals) -> [MetricItem] {
        var items: [MetricItem] = []
        if totals.requests > 0 {
            items.append(MetricItem(
                icon: "arrow.up.arrow.down",
                label: L("Requests"),
                value: UsageFormatter.tokenCountString(totals.requests)))
        }
        if totals.cacheRead > 0 {
            items.append(MetricItem(
                icon: "bolt.fill",
                label: L("Cache hit"),
                value: UsageFormatter.tokenCountString(totals.cacheRead)))
        }
        if totals.cacheWrite > 0 {
            items.append(MetricItem(
                icon: "square.and.arrow.down",
                label: L("Cache write"),
                value: UsageFormatter.tokenCountString(totals.cacheWrite)))
        }
        return items
    }

    // MARK: Models bar chart

    private struct ModelUsage: Identifiable {
        let name: String
        let tokens: Int
        let cost: Double
        var id: String {
            self.name
        }
    }

    @ViewBuilder
    private var modelsSection: some View {
        let models = self.aggregatedModels()
        if !models.isEmpty {
            let maxTokens = models.map(\.tokens).max() ?? 1
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Models"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                ForEach(models) { model in
                    self.modelBar(model, maxTokens: maxTokens)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
        }
    }

    private func modelBar(_ model: ModelUsage, maxTokens: Int) -> some View {
        let fraction = maxTokens > 0 ? CGFloat(model.tokens) / CGFloat(maxTokens) : 0
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(UsageFormatter.modelDisplayName(model.name))
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(UsageFormatter.tokenCountString(model.tokens))
                    .font(.system(size: 11, weight: .semibold))
                if model.cost > 0 {
                    Text("· \(self.costString(model.cost))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(self.selectionColor)
                        .frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(height: 7)
        }
    }
}

// MARK: - Aggregation, trend, export & helpers

@MainActor
extension UsageDashboardView {
    // MARK: Aggregation

    private struct AggregateTotals {
        var requests = 0
        var cacheRead = 0
        var cacheWrite = 0
    }

    private func aggregateTotals() -> AggregateTotals {
        var totals = AggregateTotals()
        for day in self.cachedHeatmap.days {
            totals.requests += day.entry.requestCount ?? 0
            totals.cacheRead += day.entry.cacheReadTokens ?? 0
            totals.cacheWrite += day.entry.cacheCreationTokens ?? 0
        }
        return totals
    }

    private func aggregatedModels(limit: Int = 8) -> [ModelUsage] {
        var byModel: [String: (tokens: Int, cost: Double)] = [:]
        for day in self.cachedHeatmap.days {
            for breakdown in day.entry.modelBreakdowns ?? [] {
                var entry = byModel[breakdown.modelName] ?? (0, 0)
                entry.tokens += breakdown.totalTokens ?? 0
                entry.cost += breakdown.costUSD ?? 0
                byModel[breakdown.modelName] = entry
            }
        }
        return byModel
            .map { ModelUsage(name: $0.key, tokens: $0.value.tokens, cost: $0.value.cost) }
            .filter { $0.tokens > 0 }
            .sorted { $0.tokens > $1.tokens }
            .prefix(limit)
            .map(\.self)
    }

    // MARK: Trend & forecast

    /// Whether the trend plots cost (when any spend is recorded) or falls back to tokens.
    private var trendUsesCost: Bool {
        self.cachedHeatmap.stats(within: .allTime).costUSD > 0
    }

    private var trendPoints: [TrendPoint] {
        self.cachedHeatmap.days
            .sorted { $0.date < $1.date }
            .map { TrendPoint(date: $0.date, value: self.trendUsesCost ? $0.costUSD : Double($0.tokens)) }
    }

    @ViewBuilder
    private var trendSection: some View {
        let points = self.trendPoints
        if points.count >= 2 {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(self.trendUsesCost ? L("Cost trend") : L("Token trend"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let forecast = self.monthForecastText {
                        Text(forecast)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                TrendChart(
                    points: points,
                    usesCost: self.trendUsesCost,
                    costString: { self.costString($0) },
                    selectionColor: self.selectionColor,
                    selectedDayKey: self.$selectedDayKey,
                    lookupDay: { date in
                        let key = UsageHeatmapData.dayKey(for: date, calendar: .current)
                        return self.cachedHeatmap.daysByKey[key]
                    })
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
        }
    }

    private func trendAxisLabel(_ value: Double) -> String {
        if self.trendUsesCost {
            return self.costString(value)
        }
        return UsageFormatter.tokenCountString(Int(value))
    }

    /// Projects this month's total from the month-to-date pace, when cost data exists.
    private var monthForecastText: String? {
        guard self.trendUsesCost else { return nil }
        let monthCost = self.cachedHeatmap.stats(within: .thisMonth).costUSD
        guard monthCost > 0 else { return nil }
        let calendar = Calendar.current
        let now = Date()
        let dayOfMonth = calendar.component(.day, from: now)
        guard dayOfMonth > 0,
              let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count
        else { return nil }
        let projected = monthCost / Double(dayOfMonth) * Double(daysInMonth)
        return String(format: L("Projected this month: %@"), self.costString(projected))
    }

    // MARK: Day detail

    @ViewBuilder
    private var daySection: some View {
        if let key = self.selectedDayKey, let day = self.cachedHeatmap.daysByKey[key] {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                Text(String(format: L("%@ · model breakdown"), self.fullDateString(day.date)))
                    .font(.system(size: 12, weight: .medium))
                let breakdowns = CostHistoryChartMenuView.orderedBreakdownItems(day.entry.modelBreakdowns ?? [])
                if breakdowns.isEmpty {
                    Text(self.combinedValueString(tokens: day.tokens, cost: day.costUSD))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(breakdowns.enumerated()), id: \.offset) { _, item in
                        self.breakdownRow(item: item)
                    }
                }
            }
        }
    }

    private func breakdownRow(item: CostUsageDailyReport.ModelBreakdown) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(self.selectionColor)
                .frame(width: 2, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(UsageFormatter.modelDisplayName(item.modelName))
                    .font(.system(size: 12))
                Text(self.breakdownSubtitle(item))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(L("No usage history yet."))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(L("Enable a provider with token-cost tracking (Codex, Claude, …) to see a heatmap."))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Selection helpers

    private var dashboardProviders: [UsageProvider] {
        self.store.enabledProviders()
    }

    private var selectionColor: Color {
        switch self.selection {
        case .overview: .accentColor
        case let .provider(provider): self.color(for: provider)
        }
    }

    private var selectionTitle: String {
        switch self.selection {
        case .overview: L("Overview")
        case let .provider(provider): self.store.metadata(for: provider).displayName
        }
    }

    private var planText: String? {
        guard case let .provider(provider) = self.selection else { return nil }
        let plan = UsageMenuCardView.Model.plan(
            for: provider,
            snapshot: self.store.snapshot(for: provider),
            account: self.store.accountInfo(for: provider),
            metadata: self.store.metadata(for: provider))
        guard let plan, !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return plan
    }

    private func headerSubtitle(hasToken: Bool) -> String? {
        if hasToken {
            let data = self.cachedHeatmap
            let all = data.stats(within: .allTime)
            let total = self.combinedValueString(tokens: all.tokens, cost: all.costUSD)
            return String(format: L("Past year · %@ · %d active days"), total, data.activeDayCount)
        }
        if case let .provider(provider) = self.selection {
            let email = self.store.snapshot(for: provider)?.identity?.accountEmail?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let email, !email.isEmpty { return email }
        }
        return nil
    }

    private func bootstrapSelectionIfNeeded() {
        if case let .provider(provider) = self.selection, !self.dashboardProviders.contains(provider) {
            self.selection = .overview
        }
        self.refreshHeatmap()
    }

    // MARK: Heatmap data

    private var dailySignature: String {
        switch self.selection {
        case .overview:
            return "overview-" + self.dashboardProviders.map { provider in
                "\(provider.rawValue):\(self.store.tokenSnapshot(for: provider)?.daily.count ?? 0)"
            }.joined(separator: ",")
        case let .provider(provider):
            guard let daily = self.store.tokenSnapshot(for: provider)?.daily else { return "" }
            let first = daily.first?.date ?? ""
            let last = daily.last?.date ?? ""
            return "\(provider.rawValue)-\(daily.count)-\(first)-\(last)"
        }
    }

    private func refreshHeatmap() {
        let daily: [CostUsageDailyReport.Entry] = switch self.selection {
        case .overview:
            self.mergedOverviewDaily()
        case let .provider(provider):
            self.providerDaily(provider)
        }
        self.cachedHeatmap = .make(daily: daily, weeks: self.range.weeks)
    }

    /// Daily entries for a provider, preferring the dashboard's full-year fetch and
    /// falling back to the menu's shorter cached snapshot until it arrives.
    private func providerDaily(_ provider: UsageProvider) -> [CostUsageDailyReport.Entry] {
        self.extendedDaily[provider] ?? self.store.tokenSnapshot(for: provider)?.daily ?? []
    }

    /// Fetches a full year of daily entries for the current selection (every contributing
    /// provider for the overview), then rebuilds the heatmap. The 30-day snapshot keeps the
    /// grid populated until the wider scan completes.
    private func loadExtendedForSelection() async {
        let providers: [UsageProvider] = switch self.selection {
        case .overview:
            self.dashboardProviders.filter { self.store.tokenSnapshot(for: $0)?.daily.isEmpty == false }
        case let .provider(provider):
            [provider]
        }
        for provider in providers where self.extendedDaily[provider] == nil {
            let entries = await self.store.dashboardDailyEntries(for: provider, days: 365)
            if Task.isCancelled { return }
            if !entries.isEmpty {
                self.extendedDaily[provider] = entries
            }
        }
        self.refreshHeatmap()
    }

    /// Sum every provider's daily token usage into one synthetic series so the
    /// overview heatmap and stats reflect combined spend. Model breakdowns are
    /// merged by model name across providers.
    private func mergedOverviewDaily() -> [CostUsageDailyReport.Entry] {
        struct DayAcc {
            var tokens = 0
            var cost = 0.0
            var requests = 0
            var cacheRead = 0
            var cacheWrite = 0
            var models: [String: (cost: Double, tokens: Int, requests: Int)] = [:]
        }
        var byDate: [String: DayAcc] = [:]

        for provider in self.dashboardProviders {
            let daily = self.providerDaily(provider)
            guard !daily.isEmpty else { continue }
            for entry in daily {
                var acc = byDate[entry.date] ?? DayAcc()
                acc.tokens += entry.totalTokens ?? 0
                acc.cost += entry.costUSD ?? 0
                acc.requests += entry.requestCount ?? 0
                acc.cacheRead += entry.cacheReadTokens ?? 0
                acc.cacheWrite += entry.cacheCreationTokens ?? 0
                for breakdown in entry.modelBreakdowns ?? [] {
                    var model = acc.models[breakdown.modelName] ?? (0, 0, 0)
                    model.cost += breakdown.costUSD ?? 0
                    model.tokens += breakdown.totalTokens ?? 0
                    model.requests += breakdown.requestCount ?? 0
                    acc.models[breakdown.modelName] = model
                }
                byDate[entry.date] = acc
            }
        }

        return byDate.map { date, acc in
            CostUsageDailyReport.Entry(
                date: date,
                inputTokens: nil,
                outputTokens: nil,
                cacheReadTokens: acc.cacheRead > 0 ? acc.cacheRead : nil,
                cacheCreationTokens: acc.cacheWrite > 0 ? acc.cacheWrite : nil,
                totalTokens: acc.tokens,
                requestCount: acc.requests,
                costUSD: acc.cost,
                modelsUsed: nil,
                modelBreakdowns: acc.models.map { name, value in
                    CostUsageDailyReport.ModelBreakdown(
                        modelName: name,
                        costUSD: value.cost,
                        totalTokens: value.tokens,
                        requestCount: value.requests)
                })
        }
    }

    // MARK: Formatting

    private func currencyCode() -> String {
        if case let .provider(provider) = self.selection {
            return self.store.tokenSnapshot(for: provider)?.currencyCode ?? "USD"
        }
        return "USD"
    }

    private func color(for provider: UsageProvider) -> Color {
        let c = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: 1)
    }

    private var overviewSidebarValue: String {
        switch self.settings.dashboardSidebarDisplay {
        case .percent:
            self.overviewPercentValue
        case .tokens:
            self.overviewTokensValue
        }
    }

    /// Sum today's token usage across every provider that has a daily
    /// snapshot. Mirrors the legacy `.tokens` behavior — empty when no
    /// provider has produced any token data for today.
    private var overviewTokensValue: String {
        let todayKey = UsageHeatmapData.dayKey(for: Date(), calendar: .current)
        var tokens = 0
        for provider in self.dashboardProviders {
            guard let daily = self.store.tokenSnapshot(for: provider)?.daily else { continue }
            tokens += daily.first(where: { $0.date == todayKey })?.totalTokens ?? 0
        }
        return tokens > 0 ? UsageFormatter.tokenCountString(tokens) : "—"
    }

    /// Average primary-window usage across enabled providers. Used when
    /// the user opts into `.percent` mode on the sidebar.
    private var overviewPercentValue: String {
        var sum: Double = 0
        var count = 0
        for provider in self.dashboardProviders {
            guard let window = self.store.snapshot(for: provider)?.primary else { continue }
            sum += min(100, max(0, window.usedPercent))
            count += 1
        }
        guard count > 0 else { return "—" }
        return String(format: "%.0f%%", sum / Double(count))
    }

    private func sidebarValue(for provider: UsageProvider) -> String {
        switch self.settings.dashboardSidebarDisplay {
        case .percent:
            self.percentValue(for: provider)
        case .tokens:
            self.tokensValue(for: provider)
        }
    }

    /// Today's token total for `provider`. When a daily token snapshot
    /// exists for today we show the count; otherwise we fall back to the
    /// provider's primary-window used percent (matches the legacy
    /// `sidebarValue(for:)` behavior that pre-dated the `.tokens` /
    /// `.percent` setting toggle).
    private func tokensValue(for provider: UsageProvider) -> String {
        if let daily = self.store.tokenSnapshot(for: provider)?.daily, !daily.isEmpty {
            let todayKey = UsageHeatmapData.dayKey(for: Date(), calendar: .current)
            if let entry = daily.first(where: { $0.date == todayKey }) {
                return UsageFormatter.tokenCountString(entry.totalTokens ?? 0)
            }
        }
        if let window = self.store.snapshot(for: provider)?.primary {
            return String(format: "%.0f%%", min(100, max(0, window.usedPercent)))
        }
        return "—"
    }

    /// Primary-window used percent for `provider`. Returns `"—"` when the
    /// provider has no primary window at all (e.g. an unconfigured
    /// OpenCode).
    private func percentValue(for provider: UsageProvider) -> String {
        guard let window = self.store.snapshot(for: provider)?.primary else { return "—" }
        return String(format: "%.0f%%", min(100, max(0, window.usedPercent)))
    }

    private func combinedValueString(tokens: Int, cost: Double) -> String {
        var text = "\(UsageFormatter.tokenCountString(tokens)) \(L("tokens"))"
        if cost > 0 {
            text += " · \(self.costString(cost))"
        }
        return text
    }

    private func dayDetailString(day: HeatmapDay) -> String {
        var parts = ["\(UsageFormatter.tokenCountString(day.tokens)) \(L("tokens"))"]
        if day.costUSD > 0 { parts.append("≈ \(self.costString(day.costUSD))") }
        if day.requests > 0 {
            parts.append(String(format: L("%@ requests"), UsageFormatter.tokenCountString(day.requests)))
        }
        if let cacheRead = day.entry.cacheReadTokens, cacheRead > 0 {
            parts.append(String(format: L("%@ cache hit"), UsageFormatter.tokenCountString(cacheRead)))
        }
        return parts.joined(separator: " · ")
    }

    private func breakdownSubtitle(_ item: CostUsageDailyReport.ModelBreakdown) -> String {
        var parts: [String] = []
        if let tokens = item.totalTokens, tokens > 0 {
            parts.append("\(UsageFormatter.tokenCountString(tokens)) \(L("tokens"))")
        }
        if let cost = item.costUSD, cost > 0 {
            parts.append(self.costString(cost))
        }
        if let requests = item.requestCount, requests > 0 {
            parts.append(String(format: L("%@ requests"), UsageFormatter.tokenCountString(requests)))
        }
        return parts.joined(separator: " · ")
    }

    private func costString(_ value: Double) -> String {
        UsageFormatter.currencyString(value, currencyCode: self.currencyCode())
    }

    private func fullDateString(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day().weekday(.abbreviated))
    }

    // MARK: Export

    private func export(asJSON: Bool) {
        let days = self.cachedHeatmap.days.sorted { $0.date < $1.date }
        guard !days.isEmpty else { return }
        let content = asJSON ? self.exportJSON(days: days) : self.exportCSV(days: days)
        guard let data = content.data(using: .utf8) else { return }

        let scopeSlug = self.selectionTitle
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "codexbar-usage-\(scopeSlug).\(asJSON ? "json" : "csv")"
        panel.allowedContentTypes = [asJSON ? .json : .commaSeparatedText]
        panel.isExtensionHidden = false
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    private func exportCSV(days: [HeatmapDay]) -> String {
        var lines = ["date,tokens,cost_usd,requests,cache_read,cache_write"]
        for day in days {
            lines.append([
                day.dayKey,
                String(day.tokens),
                String(format: "%.4f", day.costUSD),
                String(day.entry.requestCount ?? 0),
                String(day.entry.cacheReadTokens ?? 0),
                String(day.entry.cacheCreationTokens ?? 0),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func exportJSON(days: [HeatmapDay]) -> String {
        let dayObjects: [[String: Any]] = days.map { day in
            var object: [String: Any] = [
                "date": day.dayKey,
                "tokens": day.tokens,
                "costUSD": day.costUSD,
            ]
            if let requests = day.entry.requestCount { object["requests"] = requests }
            if let cacheRead = day.entry.cacheReadTokens { object["cacheRead"] = cacheRead }
            if let cacheWrite = day.entry.cacheCreationTokens { object["cacheWrite"] = cacheWrite }
            if let breakdowns = day.entry.modelBreakdowns, !breakdowns.isEmpty {
                object["models"] = breakdowns.map { breakdown -> [String: Any] in
                    var model: [String: Any] = ["name": breakdown.modelName]
                    if let tokens = breakdown.totalTokens { model["tokens"] = tokens }
                    if let cost = breakdown.costUSD { model["costUSD"] = cost }
                    return model
                }
            }
            return object
        }
        let root: [String: Any] = [
            "scope": self.selectionTitle,
            "range": self.range.rawValue,
            "currency": self.currencyCode(),
            "days": dayObjects,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]),
            let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }
}
