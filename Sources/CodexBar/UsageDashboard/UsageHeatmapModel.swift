import CodexBarCore
import Foundation

/// Which daily metric drives the heatmap intensity and the summary statistics.
enum HeatmapMetric: String, CaseIterable, Hashable {
    case tokens
    case cost
}

/// A single day that has recorded usage for one provider.
struct HeatmapDay: Identifiable, Hashable {
    let dayKey: String
    let date: Date
    let tokens: Int
    let costUSD: Double
    let requests: Int
    let entry: CostUsageDailyReport.Entry

    var id: String {
        self.dayKey
    }

    func value(for metric: HeatmapMetric) -> Double {
        switch metric {
        case .tokens: Double(self.tokens)
        case .cost: self.costUSD
        }
    }

    static func == (lhs: HeatmapDay, rhs: HeatmapDay) -> Bool {
        lhs.dayKey == rhs.dayKey
            && lhs.tokens == rhs.tokens
            && lhs.costUSD == rhs.costUSD
            && lhs.requests == rhs.requests
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.dayKey)
    }
}

/// One square in the calendar grid. `date == nil` means the slot is outside the
/// rendered window (a future day or leading padding) and should not be drawn.
struct HeatmapCell: Identifiable, Hashable {
    let column: Int
    let row: Int
    let date: Date?
    let day: HeatmapDay?

    var id: String {
        "\(self.column)-\(self.row)"
    }

    var isDrawable: Bool {
        self.date != nil
    }
}

/// Aggregated totals over a time window (today, last N days, month, all-time).
struct UsageWindowStats: Equatable {
    let tokens: Int
    let costUSD: Double
    let requests: Int

    func value(for metric: HeatmapMetric) -> Double {
        switch metric {
        case .tokens: Double(self.tokens)
        case .cost: self.costUSD
        }
    }

    static let zero = UsageWindowStats(tokens: 0, costUSD: 0, requests: 0)
}

/// Pure, view-agnostic model backing the usage dashboard. Built from a provider's
/// daily cost-usage entries and laid out as a GitHub-style 53-week calendar.
struct UsageHeatmapData {
    static let weekColumns = 53

    let days: [HeatmapDay]
    let daysByKey: [String: HeatmapDay]
    let columns: [[HeatmapCell]]
    let monthLabels: [(column: Int, label: String)]
    let maxTokens: Int
    let maxCostUSD: Double
    let referenceDay: Date

    var isEmpty: Bool {
        self.days.isEmpty
    }

    var activeDayCount: Int {
        self.days.count
    }

    // MARK: Construction

    static func make(
        daily: [CostUsageDailyReport.Entry],
        reference: Date = Date(),
        calendar: Calendar = .current,
        weeks: Int = weekColumns) -> UsageHeatmapData
    {
        let weekColumns = max(1, min(53, weeks))
        var cal = calendar
        cal.timeZone = calendar.timeZone

        var days: [HeatmapDay] = []
        var byKey: [String: HeatmapDay] = [:]
        var maxTokens = 0
        var maxCost = 0.0

        for entry in daily {
            guard let date = Self.date(fromDayKey: entry.date, calendar: cal) else { continue }
            let tokens = max(0, entry.totalTokens ?? 0)
            let cost = max(0, entry.costUSD ?? 0)
            let requests = max(0, entry.requestCount ?? 0)
            guard tokens > 0 || cost > 0 || requests > 0 else { continue }
            let day = HeatmapDay(
                dayKey: entry.date,
                date: date,
                tokens: tokens,
                costUSD: cost,
                requests: requests,
                entry: entry)
            // Keep the richest entry if a key appears twice.
            if let existing = byKey[entry.date], existing.tokens >= tokens, existing.costUSD >= cost {
                continue
            }
            byKey[entry.date] = day
            maxTokens = max(maxTokens, tokens)
            maxCost = max(maxCost, cost)
        }
        days = byKey.values.sorted { $0.date < $1.date }

        let today = cal.startOfDay(for: reference)
        let currentWeekStart = Self.startOfWeek(for: today, calendar: cal)

        var columns: [[HeatmapCell]] = []
        columns.reserveCapacity(weekColumns)
        var monthLabels: [(column: Int, label: String)] = []
        var lastMonth = -1

        for index in 0..<weekColumns {
            let columnsFromEnd = weekColumns - 1 - index
            guard let weekStart = cal.date(
                byAdding: .weekOfYear,
                value: -columnsFromEnd,
                to: currentWeekStart)
            else { continue }

            var cells: [HeatmapCell] = []
            cells.reserveCapacity(7)
            for row in 0..<7 {
                guard let cellDate = cal.date(byAdding: .day, value: row, to: weekStart) else {
                    cells.append(HeatmapCell(column: index, row: row, date: nil, day: nil))
                    continue
                }
                let dayStart = cal.startOfDay(for: cellDate)
                if dayStart > today {
                    cells.append(HeatmapCell(column: index, row: row, date: nil, day: nil))
                    continue
                }
                let key = Self.dayKey(for: dayStart, calendar: cal)
                cells.append(HeatmapCell(column: index, row: row, date: dayStart, day: byKey[key]))

                if row == 0 {
                    let month = cal.component(.month, from: dayStart)
                    if month != lastMonth {
                        monthLabels.append((index, Self.monthLabel(for: dayStart, calendar: cal)))
                        lastMonth = month
                    }
                }
            }
            columns.append(cells)
        }

        return UsageHeatmapData(
            days: days,
            daysByKey: byKey,
            columns: columns,
            monthLabels: monthLabels,
            maxTokens: maxTokens,
            maxCostUSD: maxCost,
            referenceDay: today)
    }

    // MARK: Statistics

    func stats(within window: StatWindow, calendar: Calendar = .current) -> UsageWindowStats {
        var cal = calendar
        cal.timeZone = calendar.timeZone
        let today = self.referenceDay

        let lowerBound: Date? = switch window {
        case .today:
            today
        case .threeDays:
            cal.date(byAdding: .day, value: -2, to: today)
        case .sevenDays:
            cal.date(byAdding: .day, value: -6, to: today)
        case .thisMonth:
            nil // handled below via month comparison
        case .allTime:
            nil
        }

        var tokens = 0
        var cost = 0.0
        var requests = 0
        let todayMonth = cal.component(.month, from: today)
        let todayYear = cal.component(.year, from: today)

        for day in self.days {
            let dayStart = cal.startOfDay(for: day.date)
            let include: Bool = switch window {
            case .today, .threeDays, .sevenDays:
                dayStart >= (lowerBound ?? today) && dayStart <= today
            case .thisMonth:
                cal.component(.month, from: dayStart) == todayMonth
                    && cal.component(.year, from: dayStart) == todayYear
            case .allTime:
                true
            }
            guard include else { continue }
            tokens += day.tokens
            cost += day.costUSD
            requests += day.requests
        }
        return UsageWindowStats(tokens: tokens, costUSD: cost, requests: requests)
    }

    /// Intensity bucket 0...4 (0 = no usage) for a cell under the given metric.
    func level(for day: HeatmapDay?, metric: HeatmapMetric) -> Int {
        guard let day else { return 0 }
        let value = day.value(for: metric)
        guard value > 0 else { return 0 }
        let maxValue: Double = switch metric {
        case .tokens: Double(self.maxTokens)
        case .cost: self.maxCostUSD
        }
        guard maxValue > 0 else { return 1 }
        let ratio = value / maxValue
        switch ratio {
        case ..<0.25: return 1
        case ..<0.5: return 2
        case ..<0.75: return 3
        default: return 4
        }
    }

    enum StatWindow: String, CaseIterable, Hashable {
        case today
        case threeDays
        case sevenDays
        case thisMonth
        case allTime
    }

    // MARK: Date helpers

    static func date(fromDayKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        return calendar.date(from: comps)
    }

    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = comps.year, let month = comps.month, let day = comps.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func startOfWeek(for date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        let delta = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -delta, to: calendar.startOfDay(for: date))
            ?? calendar.startOfDay(for: date)
    }

    private static func monthLabel(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = codexBarLocalizedLocale()
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter.string(from: date)
    }
}
