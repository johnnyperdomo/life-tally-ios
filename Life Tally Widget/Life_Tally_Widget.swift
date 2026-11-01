import SwiftUI
import WidgetKit

private enum LifeTallyWidgetStorage {
    static let suiteName = "group.com.flytebuddyllc.lifetally"
    static let snapshotKey = "LifeTally.watch.syncedSnapshot"

    static func snapshot() -> LifeTallyWidgetEntry {
        let defaults = UserDefaults(suiteName: suiteName)
        // The extension can outlive the watch app's writes to the shared suite.
        defaults?.synchronize()
        guard
            let values = defaults?.dictionary(forKey: snapshotKey)
        else {
            return .waitingForSync
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
            oneTaskRewardHundredths: oneTaskReward(in: values),
            latestEntryTimestamp: date(values["latestEntryTimestamp"])
        )
    }

    private static func int64(_ value: Any?, fallback: Int64 = 0) -> Int64 {
        (value as? NSNumber)?.int64Value ?? fallback
    }

    private static func int(_ value: Any?, fallback: Int = 0) -> Int {
        (value as? NSNumber)?.intValue ?? fallback
    }

    static func addOneTask(at date: Date) {
        guard
            let defaults = UserDefaults(suiteName: suiteName),
            var values = defaults.dictionary(forKey: snapshotKey)
        else {
            return
        }

        let reward = oneTaskReward(in: values)
        var level = int(values["level"], fallback: 1)
        var pointsWithinLevel = int64(values["pointsWithinLevel"])
        var levelCost = int64(values["levelCost"], fallback: levelCost(for: level))

        values["lifetimePointsHundredths"] = int64(values["lifetimePointsHundredths"]) + reward
        values["todayPointsHundredths"] = int64(values["todayPointsHundredths"]) + reward
        values["todayTasks"] = int(values["todayTasks"]) + 1
        values["latestEntryTimestamp"] = date.timeIntervalSince1970
        values["updatedAt"] = date.timeIntervalSince1970

        let nextReward = Int64((Double(reward) * 1.005).rounded())
        pointsWithinLevel += boundedLevelProgress(reward: reward, levelCost: levelCost)
        if pointsWithinLevel >= levelCost {
            pointsWithinLevel -= levelCost
            level += 1
            levelCost = lockedLevelCost(nextReward: nextReward)
        }
        let currentMultiplier = int64(values["combinedMultiplierHundredths"], fallback: 100)
        let remainingPoints = max(0, levelCost - pointsWithinLevel)
        values["oneTaskRewardHundredths"] = nextReward
        values["combinedMultiplierHundredths"] = Int64((Double(currentMultiplier) * 1.005).rounded())
        values["level"] = level
        values["pointsWithinLevel"] = pointsWithinLevel
        values["levelCost"] = levelCost
        let nextProgress = boundedLevelProgress(reward: nextReward, levelCost: levelCost)
        values["tasksToNextLevel"] = nextProgress > 0
            ? Int((remainingPoints + nextProgress - 1) / nextProgress)
            : 0

        defaults.set(values, forKey: snapshotKey)
        defaults.synchronize()
    }

    private static func oneTaskReward(in values: [String: Any]) -> Int64 {
        if let exactReward = (values["oneTaskRewardHundredths"] as? NSNumber)?.int64Value {
            return exactReward
        }

        // Older snapshots predate the exact reward field. The combined multiplier
        // already includes the daily and level multipliers.
        return int64(values["combinedMultiplierHundredths"], fallback: 100) * 100
    }

    private static func lockedLevelCost(nextReward: Int64) -> Int64 {
        max(1, nextReward) * 12
    }

    private static func boundedLevelProgress(reward: Int64, levelCost: Int64) -> Int64 {
        let cost = max(1, levelCost)
        let minimumProgress = (cost + 14) / 15
        let maximumProgress = max(1, cost / 10)
        return min(max(reward, minimumProgress), maximumProgress)
    }

    private static func levelCost(for level: Int) -> Int64 {
        var cost: Int64 = 150_000
        if level > 1 {
            for _ in 1..<level {
                cost = cost * 106 / 100
            }
        }
        return cost * (10_000 + Int64(max(0, level - 1)) * 960) / 10_000
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
    let oneTaskRewardHundredths: Int64
    let latestEntryTimestamp: Date?

    var hasData = true

    static let waitingForSync = LifeTallyWidgetEntry(
        date: .now,
        lifetimePointsHundredths: 0,
        todayPointsHundredths: 0,
        todayTasks: 0,
        level: 1,
        pointsWithinLevel: 0,
        levelCost: 150_000,
        tasksToNextLevel: 0,
        combinedMultiplierHundredths: 100,
        oneTaskRewardHundredths: 10_000,
        latestEntryTimestamp: nil,
        hasData: false
    )

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
        oneTaskRewardHundredths: 72_194,
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

    var oneTaskAmount: String {
        currency(oneTaskRewardHundredths)
    }

    var nextLevelAmount: String {
        currency(max(0, levelCost - pointsWithinLevel))
    }

    var levelGoalAmount: String {
        currency(todayPointsHundredths + max(0, levelCost - pointsWithinLevel))
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
        if entry.hasData {
            content
        } else {
            switch family {
            case .accessoryInline:
                Text("Open Life Tally to sync")
            case .accessoryCircular, .accessoryCorner:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .accessibilityLabel("Open Life Tally to sync")
            default:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Life Tally").font(.headline)
                    Text("Open the watch and iPhone apps to sync.")
                        .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
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
            Text("Today")
                .font(.system(size: 8, weight: .semibold))

            HStack(alignment: .firstTextBaseline) {
                Text(entry.todayAmount)
                    .font(.system(size: 19, weight: .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)

                Spacer(minLength: 4)

                if let latestEntryTimestamp = entry.latestEntryTimestamp {
                    // Live timer text needs a bounded width in the widget renderer.
                    // Its unconstrained ideal width can prevent updated timelines from rendering.
                    Text(
                        .currentDate,
                        format: .stopwatch(startingAt: latestEntryTimestamp)
                    )
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.orange)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64, alignment: .trailing)
                } else {
                    Text("--:--.--")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.18))

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(.blue)
                            .frame(width: geometry.size.width * entry.levelProgress)

                        ForEach(1..<12) { step in
                            Rectangle()
                                .fill(.primary.opacity(0.28))
                                .frame(width: 0.75)
                                .offset(
                                    x: geometry.size.width * Double(step) / 12
                                )
                        }
                    }
                }

                HStack(spacing: 4) {
                    Text(entry.tasksToNextLevel.formatted())

                    Spacer(minLength: 4)

                    Text("+\(entry.oneTaskAmount)")
                }
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .shadow(color: .black.opacity(0.7), radius: 1)
                .padding(.horizontal, 4)
                .accessibilityHidden(true)
            }
            .frame(height: 11)
            .clipShape(Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Progress to next level")
            .accessibilityValue("\(entry.nextLevelAmount) remaining")

            Spacer(minLength: 0)

            HStack {
                Text(entry.lifetimeAmount)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(entry.lifetimeAmount) lifetime total")

                Spacer(minLength: 4)

                Text(entry.levelGoalAmount)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("\(entry.levelGoalAmount) level goal")
            }
            .font(.system(size: 8, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
    nonisolated static let kind = "Life_Tally_Widget_v6"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: LifeTallyWidgetProvider()) { entry in
            LifeTallyWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Life Tally")
        .description("See today's progress and task count at a glance.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline, .accessoryCorner])
    }
}

// A separate identity lets us compare a fresh widget with existing installations.
struct LifeTallyTestWidget: Widget {
    nonisolated static let kind = "Life_Tally_Widget_Test"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: LifeTallyWidgetProvider()) { entry in
            LifeTallyWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Life Tally Test")
        .description("A fresh widget using the same Life Tally data and display.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline, .accessoryCorner])
    }
}

#Preview(as: .accessoryRectangular) {
    Life_Tally_Widget()
} timeline: {
    LifeTallyWidgetEntry.placeholder
}
