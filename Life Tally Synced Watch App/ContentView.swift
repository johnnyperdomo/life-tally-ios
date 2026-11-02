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
                    latestEntryTimestamp: store.latestEntryTimestamp,
                    isStopwatchPaused: store.isStopwatchPaused,
                    stopwatchPausedElapsed: store.stopwatchPausedElapsed,
                    onTogglePause: { store.setStopwatchPaused(!store.isStopwatchPaused) }
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
    let isStopwatchPaused: Bool
    let stopwatchPausedElapsed: TimeInterval
    let onTogglePause: () -> Void

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
                WatchEntryTimer(
                    entryTimestamp: latestEntryTimestamp,
                    isPaused: isStopwatchPaused,
                    pausedElapsed: stopwatchPausedElapsed,
                    onTogglePause: onTogglePause
                )
            }
            .font(.caption)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct WatchEntryTimer: View {
    let entryTimestamp: Date?
    let isPaused: Bool
    let pausedElapsed: TimeInterval
    let onTogglePause: () -> Void
    @State private var displayedStart: Date?
    @State private var displayedIsPaused: Bool
    @State private var displayedPausedElapsed: TimeInterval

    init(
        entryTimestamp: Date?,
        isPaused: Bool,
        pausedElapsed: TimeInterval,
        onTogglePause: @escaping () -> Void
    ) {
        self.entryTimestamp = entryTimestamp
        self.isPaused = isPaused
        self.pausedElapsed = pausedElapsed
        self.onTogglePause = onTogglePause
        _displayedStart = State(initialValue: entryTimestamp)
        _displayedIsPaused = State(initialValue: isPaused)
        _displayedPausedElapsed = State(initialValue: pausedElapsed)
    }

    var body: some View {
        if let start = displayedStart {
            HStack(spacing: 4) {
                Label {
                    if displayedIsPaused {
                        Text(Self.duration(displayedPausedElapsed))
                    } else {
                        Text(
                            .currentDate,
                            format: .stopwatch(startingAt: start, showsHours: false)
                        )
                    }
                } icon: {
                    Image(systemName: "timer")
                }
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .accessibilityLabel("Since last entry")
                .accessibilityValue(displayedIsPaused ? Self.duration(displayedPausedElapsed) : "Running")
                .accessibilityAddTraits(displayedIsPaused ? [] : .updatesFrequently)

                Button(action: togglePause) {
                    Image(systemName: displayedIsPaused ? "play.fill" : "pause.fill")
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .accessibilityLabel(displayedIsPaused ? "Resume stopwatch" : "Pause stopwatch")
            }
            .onChange(of: entryTimestamp) { _, newValue in
                displayedStart = newValue
                displayedIsPaused = isPaused
                displayedPausedElapsed = pausedElapsed
            }
            .onChange(of: isPaused) { _, newValue in
                displayedIsPaused = newValue
                displayedPausedElapsed = pausedElapsed
                if !newValue {
                    displayedStart = entryTimestamp
                }
            }
            .onChange(of: pausedElapsed) { _, newValue in
                if isPaused {
                    displayedPausedElapsed = newValue
                }
            }
        } else {
            Label("--:--", systemImage: "timer")
                .foregroundStyle(.tertiary)
        }
    }

    private func togglePause() {
        let now = Date.now
        if displayedIsPaused {
            displayedStart = now.addingTimeInterval(-displayedPausedElapsed)
            displayedIsPaused = false
        } else {
            displayedPausedElapsed = max(0, now.timeIntervalSince(displayedStart ?? now))
            displayedIsPaused = true
        }
        onTogglePause()
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
                Text(reward)
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
