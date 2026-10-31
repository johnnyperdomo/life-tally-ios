import SwiftUI

struct ContentView: View {
    let store: WatchTallyStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var feedbackTrigger = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                WatchProgressHeader(
                    lifetimeAmount: store.lifetimeAmountText,
                    level: store.level,
                    levelProgress: store.levelProgress,
                    nextLevelAmount: store.nextLevelText
                )

                WatchCounterSummary(
                    todayAmount: store.todayAmountText,
                    rate: store.rateText,
                    tasks: store.todayTasks
                )

                HStack(spacing: 8) {
                    WatchTallyButton(
                        amount: 1,
                        reward: store.rewardText(for: 1)
                    ) {
                        add(1)
                    }

                    WatchTallyButton(
                        amount: 5,
                        reward: store.rewardText(for: 5)
                    ) {
                        add(5)
                    }
                }
                Text(store.syncStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
            }

            HStack {
                Text("Level \(level)")
                    .fontWeight(.semibold)
                Spacer()
                Text("\(nextLevelAmount) to go")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Made today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(todayAmount)
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                Spacer()

                Label(rate, systemImage: "bolt.fill")
                    .font(.headline)
                    .foregroundStyle(.blue)
            }

            Text("\(tasks) \(tasks == 1 ? "task" : "tasks")")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Made today \(todayAmount). Current rate \(rate). \(tasks) tasks."
        )
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
