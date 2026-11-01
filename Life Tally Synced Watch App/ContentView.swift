import SwiftUI

struct ContentView: View {
    let store: WatchTallyStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var feedbackTrigger = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                WatchCounterSummary(
                    todayAmount: store.todayAmountText,
                    rate: store.rateText,
                    tasks: store.todayTasks,
                    latestEntryTimestamp: store.latestEntryTimestamp
                )

                HStack(spacing: 8) {
                    WatchTallyButton(
                        amount: 5,
                        reward: store.rewardText(for: 5)
                    ) {
                        add(5)
                    }

                    WatchTallyButton(
                        amount: 1,
                        reward: store.rewardText(for: 1)
                    ) {
                        add(1)
                    }
                }

                Text(store.syncStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                WatchProgressHeader(
                    lifetimeAmount: store.lifetimeAmountText,
                    level: store.level,
                    levelProgress: store.levelProgress,
                    nextLevelAmount: store.nextLevelText
                )
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
        .containerBackground(
            LinearGradient(
                colors: [.blue.opacity(0.18), .clear],
                startPoint: .top,
                endPoint: .bottom
            ),
            for: .navigation
        )
        .sensoryFeedback(.success, trigger: feedbackTrigger)
        .task { store.requestSync() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                store.requestSync()
            }
        }
    }

    private func add(_ amount: Int) {
        store.addTasks(amount)
        feedbackTrigger += 1
    }
}

private struct WatchProgressHeader: View {
    let lifetimeAmount: String
    let level: Int
    let levelProgress: Double
    let nextLevelAmount: String

    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("Lifetime")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(lifetimeAmount)
                    .fontWeight(.bold)
                    .foregroundStyle(.green)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .layoutPriority(1)
            }

            HStack {
                Text("Level \(level)")
                    .fontWeight(.semibold)
                Spacer()
                Text("\(nextLevelAmount) to go")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }

            ProgressView(value: levelProgress)
                .tint(.blue)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Lifetime \(lifetimeAmount). Level \(level). \(nextLevelAmount) to the next level."
        )
    }
}

private struct WatchCounterSummary: View {
    let todayAmount: String
    let rate: String
    let tasks: Int
    let latestEntryTimestamp: Date?

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Made today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Label(rate, systemImage: "bolt.fill")
                    .font(.headline)
                    .foregroundStyle(.blue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Text(todayAmount)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.42)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Text("\(tasks) \(tasks == 1 ? "task" : "tasks")")
                    .fontWeight(.semibold)
                Spacer()
                WatchEntryTimer(entryTimestamp: latestEntryTimestamp)
            }
            .font(.caption)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Made today \(todayAmount). Current rate \(rate). \(tasks) tasks."
        )
    }
}

private struct WatchEntryTimer: View {
    let entryTimestamp: Date?

    var body: some View {
        if let entryTimestamp {
            TimelineView(.periodic(from: .now, by: 0.05)) { context in
                Label(
                    Self.duration(context.date.timeIntervalSince(entryTimestamp)),
                    systemImage: "timer"
                )
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .accessibilityLabel("Since last entry")
                .accessibilityValue(Self.duration(context.date.timeIntervalSince(entryTimestamp)))
                .accessibilityAddTraits(.updatesFrequently)
            }
        } else {
            Label("--:--", systemImage: "timer")
                .foregroundStyle(.tertiary)
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let elapsed = max(0, seconds)
        let minutes = Int(elapsed) / 60
        let remainingSeconds = elapsed.truncatingRemainder(dividingBy: 60)
        return String(format: "%d:%05.2f", minutes, remainingSeconds)
    }
}

private struct WatchTallyButton: View {
    let amount: Int
    let reward: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text("+\(amount)")
                    .font(.headline.weight(.bold))
                Text("+\(reward)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.borderedProminent)
        .tint(.blue)
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .accessibilityLabel(
            "Add \(amount) \(amount == 1 ? "task" : "tasks") for \(reward)"
        )
    }
}
