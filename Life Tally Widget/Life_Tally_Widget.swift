import SwiftUI
import WidgetKit

private enum LifeTallyWidgetStorage {
    static let suiteName = "group.devplaceholder.I1AQHERN.Life-Tally"
    static let snapshotKey = "LifeTally.watch.syncedSnapshot"

    static func snapshot() -> LifeTallyWidgetEntry {
        guard
            let values = UserDefaults(suiteName: suiteName)?
                .dictionary(forKey: snapshotKey)
        else {
            return .placeholder
        }

        return LifeTallyWidgetEntry(
            date: Date(),
            lifetimePointsHundredths: int64(values["lifetimePointsHundredths"]),
            todayPointsHundredths: int64(values["todayPointsHundredths"]),
            todayTasks: int(values["todayTasks"]),
            level: int(values["level"], fallback: 1),
            pointsWithinLevel: int64(values["pointsWithinLevel"]),
            levelCost: int64(values["levelCost"], fallback: 1),
            tasksToNextLevel: int(values["tasksToNextLevel"]),
            combinedMultiplierHundredths: int64(values["combinedMultiplierHundredths"], fallback: 100),
            latestEntryTimestamp: date(values["latestEntryTimestamp"])
        )
    }

    private static func int64(_ value: Any?, fallback: Int64 = 0) -> Int64 {
        (value as? NSNumber)?.int64Value ?? fallback
    }

    private static func int(_ value: Any?, fallback: Int = 0) -> Int {
        (value as? NSNumber)?.intValue ?? fallback
    }

    private static func date(_ value: Any?) -> Date? {
        guard let timestamp = (value as? NSNumber)?.doubleValue, timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }
}

struct LifeTallyWidgetEntry: TimelineEntry {
    let date: Date
    let lifetimePointsHundredths: Int64
    let todayPointsHundredths: Int64
    let todayTasks: Int
    let level: Int
    let pointsWithinLevel: Int64
    let levelCost: Int64
    let tasksToNextLevel: Int
    let combinedMultiplierHundredths: Int64
    let latestEntryTimestamp: Date?

    static let placeholder = LifeTallyWidgetEntry(
        date: .now,
        lifetimePointsHundredths: 43_841_138,
        todayPointsHundredths: 10_634_650,
        todayTasks: 74,
        level: 11,
        pointsWithinLevel: 6_950_516,
        levelCost: 10_000_000,
        tasksToNextLevel: 45,
        combinedMultiplierHundredths: 687,
        latestEntryTimestamp: Date().addingTimeInterval(-83.45)
    )

    var todayAmount: String {
        currency(todayPointsHundredths)
    }

    var lifetimeAmount: String {
        currency(lifetimePointsHundredths)
    }

    var multiplier: String {
        let value = Decimal(combinedMultiplierHundredths) / 100
        return value.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    var levelProgress: Double {
        let progress = Double(pointsWithinLevel) / Double(max(1, levelCost))
        return min(max(progress, 0), 1)
    }

    private func currency(_ hundredths: Int64) -> String {
        let value = Decimal(hundredths) / 100
        return value.formatted(
            .currency(code: "USD").precision(.fractionLength(2))
        )
    }
}

struct LifeTallyWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> LifeTallyWidgetEntry {
        .placeholder
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (LifeTallyWidgetEntry) -> Void
    ) {
        completion(context.isPreview ? .placeholder : LifeTallyWidgetStorage.snapshot())
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<LifeTallyWidgetEntry>) -> Void
    ) {
        let entry = LifeTallyWidgetStorage.snapshot()
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct LifeTallyWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LifeTallyWidgetEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            LifeTallyCircularWidget(entry: entry)
        case .accessoryInline:
            Text("\(entry.todayAmount) · \(entry.todayTasks) tasks")
        case .accessoryCorner:
            LifeTallyCornerWidget(entry: entry)
        default:
            LifeTallyRectangularWidget(entry: entry)
        }
    }
}

private struct LifeTallyRectangularWidget: View {
    let entry: LifeTallyWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Today")
                    .font(.caption2.weight(.semibold))
                Spacer()
                Text("Level \(entry.level)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(entry.todayAmount)
                .font(.headline.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)

            ProgressView(value: entry.levelProgress)
                .progressViewStyle(.linear)
                .tint(.blue)

            HStack {
                Label("\(entry.todayTasks) tasks", systemImage: "checkmark.circle.fill")
                    .widgetAccentable()
                Spacer()
                Text("\(entry.tasksToNextLevel) to L\(entry.level + 1)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

private struct LifeTallyCircularWidget: View {
    let entry: LifeTallyWidgetEntry

    var body: some View {
        Gauge(value: min(Double(entry.todayTasks), 100), in: 0...100) {
            Image(systemName: "bolt.fill")
        } currentValueLabel: {
            VStack(spacing: 0) {
                Text(entry.todayTasks.formatted())
                    .font(.headline.weight(.bold))
                Text("tasks")
                    .font(.system(.caption2))
            }
        }
        .gaugeStyle(.accessoryCircular)
        .tint(.blue)
    }
}

private struct LifeTallyCornerWidget: View {
    let entry: LifeTallyWidgetEntry

    var body: some View {
        Text(entry.todayTasks.formatted())
            .font(.headline.weight(.bold))
            .widgetCurvesContent()
            .widgetLabel {
                Label("tasks", systemImage: "bolt.fill")
            }
    }
}

struct Life_Tally_Widget: Widget {
    static let kind = "Life_Tally_Widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: LifeTallyWidgetProvider()) { entry in
            LifeTallyWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Life Tally")
        .description("See today's progress and task count at a glance.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct LifeTallyTimerWidget: Widget {
    static let kind = "Life_Tally_Timer_Widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: LifeTallyWidgetProvider()) { entry in
            LifeTallyStopwatchView(entryTimestamp: entry.latestEntryTimestamp)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Task Stopwatch")
        .description("Time since your most recent task entry.")
        .supportedFamilies([.accessoryCircular])
    }
}

private struct LifeTallyStopwatchView: View {
    let entryTimestamp: Date?

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()

            ForEach(0..<60, id: \.self) { tick in
                Capsule()
                    .fill(tick.isMultiple(of: 5) ? .primary : .secondary)
                    .frame(width: tick.isMultiple(of: 5) ? 1.5 : 1, height: tick.isMultiple(of: 5) ? 5 : 3)
                    .offset(y: -25)
                    .rotationEffect(.degrees(Double(tick) * 6))
            }

            if let entryTimestamp {
                Text(
                    .currentDate,
                    format: .stopwatch(
                        startingAt: entryTimestamp,
                        showsHours: false,
                        maxFieldCount: 2,
                        maxPrecision: .seconds(1)
                    )
                )
                .font(.caption2.weight(.bold))
                .foregroundStyle(.orange)
                .monospacedDigit()
                .minimumScaleFactor(0.45)
                .lineLimit(1)
                .padding(.horizontal, 7)
            } else {
                Text("--:--")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.orange)
                .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Time since the latest task")
    }
}

#Preview(as: .accessoryRectangular) {
    Life_Tally_Widget()
} timeline: {
    LifeTallyWidgetEntry.placeholder
}
