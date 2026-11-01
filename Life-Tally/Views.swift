import Charts
import SwiftData
import SwiftUI

enum LifeTallyTheme {
    static let accent = Color.blue
    static let background = Color(.systemGroupedBackground)
    static let surface = Color(.secondarySystemGroupedBackground)
    static let border = Color.primary.opacity(0.06)
    static let shadow = Color.black.opacity(0.035)
}

struct RootView: View {
    let store: LifeTallyStore

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") {
                NavigationStack { TodayView(store: store) }
            }
            Tab("History", systemImage: "clock.fill") {
                NavigationStack { HistoryView(store: store) }
            }
            Tab("Habits", systemImage: "checkmark.square.fill") {
                NavigationStack { HabitsView(store: store) }
            }
            Tab("Statistics", systemImage: "chart.bar.fill") {
                NavigationStack { StatsView(store: store) }
            }
            Tab("Levels", systemImage: "arrow.up.right.circle.fill") {
                NavigationStack {
                    LevelsView(store: store)
                }
            }
        }
        .tint(LifeTallyTheme.accent)
        .fontDesign(.rounded)
    }
}

struct TodayView: View {
    let store: LifeTallyStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                NavigationLink {
                    LevelsView(store: store)
                } label: {
                    LevelProgressHeader(store: store)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens detailed level progression")
                TodayCounterCard(store: store, log: log, correct: correct)
                HabitCard(store: store)
                CustomHabitsCard(store: store)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .padding(.bottom, 72)
        }
        .background(LifeTallyTheme.background)
        .navigationTitle("Life Tally")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings", systemImage: "gear") { showingSettings = true }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Settings and sync status")
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView(store: store)
            }
        }
        .task(id: scenePhase) {
            if scenePhase == .active { store.reconcile() }
        }
    }

    private func log(_ amount: Int) {
        let before = store.progression
        _ = store.addTasks(amount)
        UIImpactFeedbackGenerator(style: amount == 5 ? .rigid : .medium).impactOccurred()
        let after = store.progression
        if after.level > before.level {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func correct(_ amount: Int) {
        store.correct(amount)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

struct LevelProgressHeader: View {
    let store: LifeTallyStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let progress = store.progression
        let remaining = max(0, progress.levelCost - progress.pointsWithinLevel)
        let fraction = progress.levelCost > 0
            ? min(1, Double(progress.pointsWithinLevel) / Double(progress.levelCost))
            : 0

        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("Lifetime")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(LifeTallyFormat.points(store.lifetimePointsHundredths))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.green)
                    .contentTransition(.numericText())
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.2),
                        value: store.lifetimePointsHundredths
                    )
            }

            HStack {
                Text("Level \(progress.level)")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(value: Double(progress.level)))
                Spacer()
                Text("\(LifeTallyFormat.points(remaining)) to Level \(progress.level + 1)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }

            ProgressView(value: fraction)
                .tint(LifeTallyTheme.accent)
                .scaleEffect(x: 1, y: 0.85)
                .animation(.smooth, value: fraction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(LifeTallyTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(LifeTallyTheme.border, lineWidth: 1)
        }
        .shadow(color: LifeTallyTheme.shadow, radius: 6, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Lifetime \(LifeTallyFormat.points(store.lifetimePointsHundredths)). Level \(progress.level). \(LifeTallyFormat.points(remaining)) to level \(progress.level + 1)"
        )
    }
}

struct TodayCounterCard: View {
    let store: LifeTallyStore
    let log: (Int) -> Void
    let correct: (Int) -> Void
    var body: some View {
        let summary = store.today
        let completedHabits = store.completedHabitCount()
        let baseMultiplier = ScoringRules.combinedMultiplierHundredths(
            goodSleep: summary.sleep,
            failed: summary.failed,
            completedDays: summary.completedStreakBeforeDay,
            completedHabits: completedHabits
        )
        let levelMultiplier = ScoringRules.levelMultiplierTenThousandths(level: store.progression.level)
        let oneTaskGrowth = ScoringRules.taskGrowthMultiplierTenThousandths(
            completedTasks: store.lifetimeTasks
        )
        let fiveTaskGrowth = ScoringRules.taskGrowthMultiplierTenThousandths(
            completedTasks: store.lifetimeTasks,
            units: 5
        )
        let oneTaskMultiplier = levelMultiplier * oneTaskGrowth / 10_000
        let fiveTaskMultiplier = levelMultiplier * fiveTaskGrowth / 10_000
        let multiplier = baseMultiplier * oneTaskMultiplier / 10_000
        let oneTaskReward = ScoringRules.taskPointsHundredths(
            units: 1,
            goodSleep: summary.sleep,
            failed: summary.failed,
            completedDays: summary.completedStreakBeforeDay,
            completedHabits: completedHabits,
            levelMultiplierTenThousandths: oneTaskMultiplier
        )
        let fiveTaskReward = ScoringRules.taskPointsHundredths(
            units: 5,
            goodSleep: summary.sleep,
            failed: summary.failed,
            completedDays: summary.completedStreakBeforeDay,
            completedHabits: completedHabits,
            levelMultiplierTenThousandths: fiveTaskMultiplier
        )

        VStack(spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Made today")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(LifeTallyFormat.points(summary.pointsHundredths))
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .contentTransition(.numericText(value: Double(summary.pointsHundredths) / 100))
                }
                Spacer()
                Label(LifeTallyFormat.multiplier(multiplier), systemImage: "bolt.fill")
                    .font(.headline)
                    .foregroundStyle(.blue)
                    .contentTransition(.numericText(value: Double(multiplier)))
                    .accessibilityLabel("Current multiplier \(LifeTallyFormat.multiplier(multiplier))")
            }
            .accessibilityElement(children: .contain)

            HStack(spacing: 12) {
                HoldTallyButton(
                    amount: 5,
                    rewardHundredths: fiveTaskReward,
                    canRemove: summary.tasks >= 5,
                    onAdd: { log(5) },
                    onRemove: { correct(5) }
                )
                HoldTallyButton(
                    amount: 1,
                    rewardHundredths: oneTaskReward,
                    canRemove: summary.tasks >= 1,
                    onAdd: { log(1) },
                    onRemove: { correct(1) }
                )
            }

            HStack {
                Text("\(summary.tasks) \(summary.tasks == 1 ? "task" : "tasks")")
                    .font(.footnote.weight(.semibold))
                Spacer()
                CompactEntryTimer(entry: store.latestRemainingPositive(on: Date()))
            }

        }
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
        .background(LifeTallyTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(LifeTallyTheme.border, lineWidth: 1)
        }
        .shadow(color: LifeTallyTheme.shadow, radius: 8, y: 3)
    }
}

struct HoldTallyButton: View {
    let amount: Int
    let rewardHundredths: Int64
    let canRemove: Bool
    let onAdd: () -> Void
    let onRemove: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressing = false
    @State private var showsCorrectionIntent = false
    @State private var longPressCompleted = false
    @State private var isRewardVisible = false
    @State private var holdTask: Task<Void, Never>?
    @State private var rewardAnimationTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.blue)
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(canRemove ? Color(red: 0.38, green: 0.72, blue: 1) : Color.secondary.opacity(0.35))
                    .frame(width: showsCorrectionIntent ? proxy.size.width : 0)
                    .animation(
                        showsCorrectionIntent && !reduceMotion ? .easeInOut(duration: 0.6) : nil,
                        value: showsCorrectionIntent
                    )
            }
            VStack(spacing: 2) {
                Text(showsCorrectionIntent ? "−\(amount)" : "+\(amount)")
                    .font(.headline.weight(.bold))
                    .contentTransition(.numericText())

                Text(
                    showsCorrectionIntent
                        ? "−\(LifeTallyFormat.points(rewardHundredths))"
                        : "+\(LifeTallyFormat.points(rewardHundredths))"
                )
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .opacity(0.88)
                .contentTransition(.numericText())
            }
            .foregroundStyle(.white)

            if isRewardVisible {
                HStack(spacing: 4) {
                    Image(systemName: "dollarsign.circle.fill")
                        .font(.caption)
                    Text(LifeTallyFormat.points(rewardHundredths))
                        .monospacedDigit()
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.orange)
                .offset(y: -48)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .offset(y: 10).combined(with: .opacity)
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .scaleEffect(isPressing && !reduceMotion ? 0.985 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isPressing)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let movedTooFar = abs(value.translation.width) > 30 || abs(value.translation.height) > 30
                    guard !movedTooFar else {
                        cancelHold()
                        return
                    }
                    guard !isPressing, !longPressCompleted else { return }
                    isPressing = true
                    longPressCompleted = false
                    holdTask = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled, isPressing else { return }
                        showsCorrectionIntent = true
                        try? await Task.sleep(for: .milliseconds(600))
                        guard !Task.isCancelled, isPressing else { return }
                        longPressCompleted = true
                        if canRemove {
                            onRemove()
                        } else {
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        }
                        isPressing = false
                        showsCorrectionIntent = false
                        holdTask = nil
                    }
                }
                .onEnded { _ in
                    holdTask?.cancel()
                    if !longPressCompleted {
                        addReward()
                    }
                    isPressing = false
                    showsCorrectionIntent = false
                    longPressCompleted = false
                    holdTask = nil
                }
        )
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(
            "Add \(amount) \(amount == 1 ? "task" : "tasks") for \(LifeTallyFormat.points(rewardHundredths))"
        )
        .accessibilityHint(canRemove ? "Double tap to add. Long press to remove." : "Double tap to add.")
        .accessibilityAction { addReward() }
        .onDisappear {
            holdTask?.cancel()
            rewardAnimationTask?.cancel()
        }
        .accessibilityAction(named: "Remove \(amount)") {
            if canRemove { onRemove() }
        }
    }

    private func addReward() {
        rewardAnimationTask?.cancel()
        onAdd()

        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            isRewardVisible = true
        }

        rewardAnimationTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                isRewardVisible = false
            }
            rewardAnimationTask = nil
        }
    }

    private func cancelHold() {
        holdTask?.cancel()
        holdTask = nil
        isPressing = false
        showsCorrectionIntent = false
        longPressCompleted = false
    }
}

struct TallyPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: configuration.isPressed)
    }
}

struct CompactEntryTimer: View {
    let entry: TallyEntry?

    var body: some View {
        if let entry {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                Label(
                    LifeTallyFormat.preciseDuration(context.date.timeIntervalSince(entry.timestamp)),
                    systemImage: "timer"
                )
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Since last entry")
                .accessibilityValue(LifeTallyFormat.preciseDuration(context.date.timeIntervalSince(entry.timestamp)))
                .accessibilityAddTraits(.updatesFrequently)
            }
        } else {
            Label("Ready", systemImage: "timer")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityLabel("First task starts the timer")
        }
    }
}

struct SinceLastEntryTimer: View {
    let entry: TallyEntry?

    var body: some View {
        if let entry {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Label("Since last entry: \(LifeTallyFormat.duration(context.date.timeIntervalSince(entry.timestamp)))", systemImage: "timer")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        } else {
            Label("First task starts the timer", systemImage: "timer")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

struct LogButton: View {
    let amount: Int
    let prominent: Bool
    let action: (Int) -> Void

    var body: some View {
        Button { action(amount) } label: {
            Label("+\(amount)", systemImage: "plus")
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 16))
        .accessibilityLabel("Add \(amount) task units")
    }
}

struct CorrectionButton: View {
    let amount: Int
    let available: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("−\(amount)", systemImage: "minus")
                .frame(minWidth: 80, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(!available)
        .accessibilityLabel("Correct \(amount) task units")
        .accessibilityHint(available ? "Removes the most recent task units" : "Not enough task units today")
    }
}

struct HabitCard: View {
    let store: LifeTallyStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text("Streak Boosts")
                    .font(.headline)
                Spacer()
                NavigationLink {
                    BoostHistoryView(store: store)
                } label: {
                    Label("History", systemImage: "chart.xyaxis.line")
                        .font(.footnote.weight(.semibold))
                }
            }
            .padding(.horizontal, 2)

            HStack(alignment: .top, spacing: 8) {
                BoostCircle(
                    title: "Good sleep",
                    iconName: "LucideBedDouble",
                    streak: store.currentGoodSleepStreak,
                    isActive: store.today.sleep,
                    activeColor: store.today.sleep ? .green : .blue,
                    completedLabel: store.today.sleep ? "" : nil,
                    accessibilityHint: "Press and hold to \(store.today.sleep ? "remove" : "confirm") good sleep for today"
                ) {
                    store.setGoodSleep(!store.today.sleep)
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                }

                BoostCircle(
                    title: store.today.failed ? "Habit occurred" : "On track",
                    iconName: store.today.failed ? "LucideShieldX" : "LucideShieldCheck",
                    streak: store.currentCompletedStreak,
                    isActive: true,
                    activeColor: store.today.failed ? .red : .green,
                    completedLabel: nil,
                    accessibilityHint: store.today.failed
                        ? "Press and hold to undo today's failure"
                        : "Press and hold only if the habit occurred today"
                ) {
                    store.setHabitFailed(!store.today.failed)
                    UINotificationFeedbackGenerator().notificationOccurred(store.today.failed ? .warning : .success)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .cardStyle(padding: 12)
    }
}

struct CustomHabitsCard: View {
    let store: LifeTallyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text("Custom Habits")
                    .font(.headline)
                Spacer()
                NavigationLink {
                    HabitsView(store: store)
                } label: {
                    Label("See All", systemImage: "chevron.right")
                        .font(.footnote.weight(.semibold))
                }
            }
            .padding(.horizontal, 2)

            if store.activeHabits.isEmpty {
                NavigationLink {
                    HabitsView(store: store)
                } label: {
                    Label("Create your first custom habit", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 72)
                }
                .buttonStyle(.plain)
                .foregroundStyle(LifeTallyTheme.accent)
                .background(
                    LifeTallyTheme.accent.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .accessibilityHint("Opens the custom habits screen")
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(store.activeHabits) { habit in
                            Button {
                                toggle(habit)
                            } label: {
                                CustomHabitHomeTile(
                                    name: habit.name,
                                    symbolName: habit.displaySymbolName,
                                    streak: store.habitStreak(habit),
                                    isCompleted: store.isHabitCompleted(habit),
                                    isSkipped: store.isHabitSkipped(habit)
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(
                                    store.isHabitSkipped(habit) ? "Undo skip" : "Skip today",
                                    systemImage: "forward.fill"
                                ) {
                                    store.toggleHabitSkipped(habit)
                                }
                            }
                            .accessibilityHint(
                                store.isHabitCompleted(habit)
                                    ? "Marks this habit incomplete for today"
                                    : "Marks this habit complete for today"
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
        .cardStyle(padding: 12)
    }

    private func toggle(_ habit: TrackedHabit) {
        let wasCompleted = store.isHabitCompleted(habit)
        store.toggleHabit(habit)

        if wasCompleted {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}

struct CustomHabitHomeTile: View {
    let name: String
    let symbolName: String
    let streak: Int
    let isCompleted: Bool
    let isSkipped: Bool

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(
                        isCompleted
                            ? LifeTallyTheme.accent
                            : LifeTallyTheme.accent.opacity(0.1)
                    )

                Image(systemName: symbolName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isCompleted ? .white : LifeTallyTheme.accent)
            }
            .frame(width: 68, height: 68)
            .overlay(alignment: .bottomTrailing) {
                if isCompleted || isSkipped {
                    Image(systemName: isCompleted ? "checkmark" : "forward.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(LifeTallyTheme.accent)
                        .frame(width: 22, height: 22)
                        .background(.background, in: Circle())
                        .overlay {
                            Circle()
                                .stroke(LifeTallyTheme.accent.opacity(0.2), lineWidth: 1)
                        }
                }
            }

            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 86)
                .frame(minHeight: 30, alignment: .top)

            Label(
                streak == 1 ? "1 day" : "\(streak) days",
                systemImage: "flame.fill"
            )
            .font(.caption2.weight(.semibold))
            .foregroundStyle(streak > 0 ? .orange : .secondary)
        }
        .frame(width: 92)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(name), \(streak) day streak, \(isCompleted ? "completed today" : isSkipped ? "skipped today" : "not completed today")"
        )
    }
}

struct BoostCircle: View {
    let title: String
    let iconName: String
    let streak: Int
    let isActive: Bool
    let activeColor: Color
    let completedLabel: String?
    let accessibilityHint: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressing = false
    @State private var didTriggerCurrentPress = false
    @State private var pressResetTask: Task<Void, Never>?

    private let holdDuration = 0.8

    private var streakLabel: String {
        streak.formatted()
    }

    var body: some View {
        VStack(spacing: 7) {
            BoostCircleArtwork(
                iconName: iconName,
                streakLabel: streakLabel,
                isActive: isActive,
                activeColor: activeColor,
                isPressing: isPressing,
                completedLabel: completedLabel,
                reduceMotion: reduceMotion,
                holdDuration: holdDuration
            )

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(minHeight: 30, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onLongPressGesture(
            minimumDuration: holdDuration,
            maximumDistance: 30,
            pressing: updatePressState,
            perform: completeLongPress
        )
        .onDisappear {
            pressResetTask?.cancel()
        }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(title), \(streak) day streak")
        .accessibilityValue(isActive ? "Active" : "Not active")
        .accessibilityHint(accessibilityHint)
        .accessibilityAction { completeLongPress() }
    }

    private func updatePressState(_ pressing: Bool) {
        isPressing = pressing

        if pressing {
            pressResetTask?.cancel()
            pressResetTask = nil
        } else {
            // State changes can rebuild a long-press gesture while the same finger
            // remains down. Delay re-arming so one physical hold fires only once.
            pressResetTask?.cancel()
            pressResetTask = Task {
                try? await Task.sleep(for: .seconds(0.5))
                guard !Task.isCancelled else { return }
                didTriggerCurrentPress = false
                pressResetTask = nil
            }
        }
    }

    private func completeLongPress() {
        guard !didTriggerCurrentPress else { return }
        didTriggerCurrentPress = true
        isPressing = false
        action()
    }
}

private struct BoostCircleArtwork: View {
    let iconName: String
    let streakLabel: String
    let isActive: Bool
    let activeColor: Color
    let isPressing: Bool
    let completedLabel: String?
    let reduceMotion: Bool
    let holdDuration: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(isActive ? activeColor : Color.secondary.opacity(0.09))
            Circle()
                .strokeBorder(
                    isActive ? Color.black.opacity(0.1) : Color.secondary.opacity(0.22),
                    lineWidth: isActive ? 3 : 2
                )
                .padding(5)
            Circle()
                .trim(from: 0, to: isActive || isPressing ? 1 : 0)
                .stroke(
                    isActive ? Color.black.opacity(0.14) : activeColor,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(2)
                .animation(
                    reduceMotion ? nil : .linear(duration: holdDuration),
                    value: isPressing
                )

            VStack(spacing: 3) {
                if completedLabel != nil {
                    Image(systemName: "checkmark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 13, height: 13)
                        .frame(width: 18, height: 18)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Image(iconName)
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .transition(.scale.combined(with: .opacity))
                }

                Text(streakLabel)
                    .font(.caption2.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.numericText())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
            }
            .foregroundStyle(isActive ? Color.white : Color.secondary)
            .animation(reduceMotion ? nil : .snappy, value: completedLabel)
        }
        .frame(width: 64, height: 64)
        .scaleEffect(isPressing && !reduceMotion ? 0.96 : 1)
        .shadow(
            color: isActive ? activeColor.opacity(0.25) : .clear,
            radius: 4,
            y: 2
        )
    }
}

enum BoostHistoryKind {
    case sleep
    case onTrack
}

struct BoostHistoryView: View {
    let store: LifeTallyStore

    var body: some View {
        let recentDays = Array(store.days.sorted { $0.date < $1.date }.suffix(60))

        ScrollView {
            LazyVStack(spacing: 16) {
                BoostHistorySection(
                    title: "Good sleep",
                    subtitle: "Manually confirmed days",
                    iconName: "LucideBedDouble",
                    color: .blue,
                    currentStreak: store.currentGoodSleepStreak,
                    bestStreak: store.longestGoodSleepStreak,
                    days: recentDays,
                    kind: .sleep
                )

                BoostHistorySection(
                    title: "Stayed on track",
                    subtitle: "Successful unless marked otherwise",
                    iconName: "LucideShieldCheck",
                    color: .green,
                    currentStreak: store.currentCompletedStreak,
                    bestStreak: store.longestCompletedStreak,
                    days: recentDays,
                    kind: .onTrack
                )
            }
            .padding()
        }
        .background(LifeTallyTheme.background)
        .navigationTitle("Boost history")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct BoostHistorySection: View {
    let title: String
    let subtitle: String
    let iconName: String
    let color: Color
    let currentStreak: Int
    let bestStreak: Int
    let days: [DailyState]
    let kind: BoostHistoryKind

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 10)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(iconName)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(color)
                    .frame(width: 28, height: 28)
                    .frame(width: 48, height: 48)
                    .background(color.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                StreakMetric(title: "Current", value: currentStreak, color: color)
                StreakMetric(title: "Best", value: bestStreak, color: color)
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("Recent days")
                    .font(.subheadline.weight(.semibold))

                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(days, id: \.stableID) { day in
                        let successful = kind == .sleep ? day.goodSleep : !day.habitFailed
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(successful ? color : Color.secondary.opacity(0.12))
                            .aspectRatio(1, contentMode: .fit)
                            .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                            .accessibilityValue(successful ? "Successful" : "Not successful")
                    }
                }

                if days.isEmpty {
                    Text("Your daily history will appear here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .cardStyle()
    }
}

struct StreakMetric: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("\(value) \(value == 1 ? "day" : "days")")
                .font(.headline.weight(.bold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct ProgressCard: View {
    let store: LifeTallyStore

    var body: some View {
        let progression = store.progression
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Level \(progression.level)")
                        .font(.headline.weight(.bold))
                }
                Spacer()
                Image(systemName: "shield.lefthalf.filled")
                    .font(.title)
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)
            }
            ProgressView(
                value: Double(progression.pointsWithinLevel),
                total: Double(progression.levelCost)
            )
            Text("\(LifeTallyFormat.points(progression.pointsWithinLevel)) of \(LifeTallyFormat.points(progression.levelCost)) to next level")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Divider()
            Text("Lifetime goal")
                .font(.headline)
            ProgressView(
                value: Double(store.lifetimePointsHundredths),
                total: Double(ScoringRules.ultimateGoalHundredths)
            )
            Text("\(LifeTallyFormat.points(store.lifetimePointsHundredths)) / \(LifeTallyFormat.points(ScoringRules.ultimateGoalHundredths))")
                .font(.callout.weight(.semibold))
            Text(Double(store.lifetimePointsHundredths) / Double(ScoringRules.ultimateGoalHundredths), format: .percent.precision(.fractionLength(2)))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }
}

struct TodayDetails: View {
    let store: LifeTallyStore

    var body: some View {
        let summary = store.today
        let completedHabits = store.completedHabitCount()
        let streak = ScoringRules.streakMultiplierHundredths(completedDays: summary.completedStreakBeforeDay)
        let combined = ScoringRules.combinedMultiplierHundredths(
            goodSleep: summary.sleep,
            failed: summary.failed,
            completedDays: summary.completedStreakBeforeDay,
            completedHabits: completedHabits
        )
        let intervals = store.positiveIntervals(on: Date())
        VStack(spacing: 10) {
            LabeledContent("Sleep multiplier", value: summary.sleep ? "1.5×" : "1×")
            LabeledContent("Streak multiplier", value: LifeTallyFormat.multiplier(streak))
            LabeledContent("Combined task effect", value: LifeTallyFormat.multiplier(combined))
            Divider()
            LabeledContent("Previous interval", value: intervals.last.map { LifeTallyFormat.duration($0) } ?? "Not enough entries")
            LabeledContent("Average interval", value: average(intervals).map { LifeTallyFormat.duration($0) } ?? "Not enough entries")
            LabeledContent("Median interval", value: median(intervals).map { LifeTallyFormat.duration($0) } ?? "Not enough entries")
            Text("Intervals reflect logging pace, not time spent working.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

struct HistoryView: View {
    let store: LifeTallyStore

    var body: some View {
        let items = store.entries(for: store.selectedHistoryDate)
        ScrollView {
            LazyVStack(spacing: 12) {
                HStack(spacing: 12) {
                    VStack(spacing: 0) {
                        Text(store.selectedHistoryDate, format: .dateTime.day())
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.primary)
                        Text(store.selectedHistoryDate, format: .dateTime.month(.abbreviated))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 54, height: 54)
                    .background(.background, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    Text(store.selectedHistoryDate, format: .dateTime.weekday(.wide))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    DatePicker("History date", selection: Binding(
                        get: { store.selectedHistoryDate },
                        set: { store.selectedHistoryDate = $0 }
                    ), in: ...(Date()), displayedComponents: .date)
                    .labelsHidden()
                }
                .padding(.horizontal)
                if items.isEmpty {
                    ContentUnavailableView("No entries", systemImage: "clock", description: Text("Tasks and bonuses for this date will appear here."))
                        .padding(.top, 80)
                } else {
                    ForEach(items) { entry in
                        HistoryRow(
                            entry: entry,
                            points: store.points(for: entry),
                            runningTotal: store.runningTaskTotal(at: entry)
                        )
                    }
                }
            }
            .padding(.vertical)
        }
        .background(LifeTallyTheme.background)
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct HistoryRow: View {
    let entry: TallyEntry
    let points: Int64
    let runningTotal: Int

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 6) {
                Text(entry.timestamp, format: .dateTime.hour().minute())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if let interval = entry.intervalSeconds {
                    Text(LifeTallyFormat.duration(interval))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 2, height: 36)
            }
            .frame(width: 72)
            VStack(alignment: .leading, spacing: 8) {
                if entry.kind != .task {
                    Text(entry.kind.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(LifeTallyFormat.points(points))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(entry.kind == .task ? .blue : .orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background((entry.kind == .task ? Color.blue : Color.orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    Spacer()
                    Label("\(runningTotal)", systemImage: "arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }
                if entry.taskUnits != 0 {
                    Text(
                        "\(entry.taskUnits > 0 ? "+" : "")\(entry.taskUnits) \(abs(entry.taskUnits) == 1 ? "task" : "tasks")"
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .padding(.trailing)
        .accessibilityElement(children: .combine)
    }
}

enum StatsPeriod: String, CaseIterable, Identifiable {
    case day = "Day"
    case week = "Week"
    case month = "Month"
    case year = "Year"
    case all = "All"
    var id: Self { self }
}

enum ChartMetric: String, CaseIterable, Identifiable {
    case tasks = "Tasks"
    case points = "$"
    var id: Self { self }
}

struct ChartDatum: Identifiable, Equatable {
    let id: Date
    let label: String
    let tasks: Int
    let points: Double
}

struct StatsView: View {
    let store: LifeTallyStore
    @State private var period: StatsPeriod = .week
    @State private var metric: ChartMetric = .tasks

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                Picker("Period", selection: $period) {
                    ForEach(StatsPeriod.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                StatsDateNavigation(store: store, period: period)
                StatsSummaryGrid(store: store, dates: dates)
                Picker("Chart metric", selection: $metric) {
                    ForEach(ChartMetric.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                StatsChart(data: chartData, metric: metric)
                PaceCard(store: store)
            }
            .padding()
        }
        .background(LifeTallyTheme.background)
        .navigationTitle("Statistics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var dates: [Date] {
        let calendar = Calendar.autoupdatingCurrent
        let selected = store.selectedStatsDate
        let start: Date
        let end: Date
        switch period {
        case .day:
            start = calendar.startOfDay(for: selected); end = start
        case .week:
            let interval = calendar.dateInterval(of: .weekOfYear, for: selected)!
            start = interval.start; end = calendar.date(byAdding: .day, value: 6, to: start)!
        case .month:
            let interval = calendar.dateInterval(of: .month, for: selected)!
            start = interval.start; end = calendar.date(byAdding: .day, value: -1, to: interval.end)!
        case .year:
            let interval = calendar.dateInterval(of: .year, for: selected)!
            start = interval.start; end = calendar.date(byAdding: .day, value: -1, to: interval.end)!
        case .all:
            start = store.profile?.trackingStart ?? selected; end = Date()
        }
        let allowedStart = max(calendar.startOfDay(for: store.profile?.trackingStart ?? start), start)
        let allowedEnd = min(calendar.startOfDay(for: Date()), end)
        guard allowedStart <= allowedEnd else { return [] }
        var output: [Date] = []
        var cursor = allowedStart
        while cursor <= allowedEnd {
            output.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        return output
    }

    private var chartData: [ChartDatum] {
        let calendar = Calendar.autoupdatingCurrent
        if period == .day {
            let summary = store.summary(for: store.selectedStatsDate)
            let completedHabits = store.completedHabitCount(on: store.selectedStatsDate)
            return store.hourlyTasks(on: store.selectedStatsDate).map { item in
                let date = calendar.date(bySettingHour: item.hour, minute: 0, second: 0, of: store.selectedStatsDate)!
                let pointsHundredths = ScoringRules.taskPointsHundredths(
                    units: item.tasks,
                    goodSleep: summary.sleep,
                    failed: summary.failed,
                    completedDays: summary.completedStreakBeforeDay,
                    completedHabits: completedHabits
                )
                return ChartDatum(
                    id: date,
                    label: date.formatted(.dateTime.hour()),
                    tasks: item.tasks,
                    points: Double(pointsHundredths) / 100
                )
            }
        }
        let grouping: Calendar.Component = period == .year || period == .all ? .month : .day
        let groups = Dictionary(grouping: dates) { date in
            calendar.dateInterval(of: grouping, for: date)?.start ?? date
        }
        return groups.keys.sorted().map { key in
            let summaries = groups[key, default: []].map(store.summary)
            return ChartDatum(
                id: key,
                label: grouping == .month ? key.formatted(.dateTime.month(.abbreviated)) : key.formatted(.dateTime.weekday(.narrow).day()),
                tasks: summaries.reduce(0) { $0 + $1.tasks },
                points: Double(summaries.reduce(Int64(0)) { $0 + $1.pointsHundredths }) / 100
            )
        }
    }
}

struct StatsDateNavigation: View {
    let store: LifeTallyStore
    let period: StatsPeriod

    var body: some View {
        HStack {
            Button("Previous", systemImage: "chevron.left") { move(-1) }
                .labelStyle(.iconOnly)
            Spacer()
            DatePicker("Statistics date", selection: Binding(
                get: { store.selectedStatsDate },
                set: { store.selectedStatsDate = $0 }
            ), in: ...(Date()), displayedComponents: .date)
            .labelsHidden()
            Spacer()
            Button("Next", systemImage: "chevron.right") { move(1) }
                .labelStyle(.iconOnly)
                .disabled(Calendar.current.isDate(store.selectedStatsDate, inSameDayAs: Date()) || period == .all)
        }
        .cardStyle()
    }

    private func move(_ direction: Int) {
        let component: Calendar.Component
        switch period {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        case .all: return
        }
        store.selectedStatsDate = min(Date(), Calendar.current.date(byAdding: component, value: direction, to: store.selectedStatsDate) ?? store.selectedStatsDate)
    }
}

struct StatsSummaryGrid: View {
    let store: LifeTallyStore
    let dates: [Date]

    var body: some View {
        let summaries = dates.map(store.summary)
        let tasks = summaries.reduce(0) { $0 + $1.tasks }
        let points = summaries.reduce(Int64(0)) { $0 + $1.pointsHundredths }
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            SummaryTile(title: "Tasks completed", value: tasks.formatted(), icon: "checkmark", color: .blue)
            SummaryTile(title: "Earned", value: LifeTallyFormat.points(points), icon: "sparkles", color: .orange)
            SummaryTile(title: "Average tasks/day", value: dates.isEmpty ? "0" : (Double(tasks) / Double(dates.count)).formatted(.number.precision(.fractionLength(0...1))), icon: "divide", color: .secondary)
            SummaryTile(title: "Days with tasks", value: summaries.filter { $0.tasks > 0 }.count.formatted(), icon: "calendar", color: .green)
        }
    }
}

struct SummaryTile: View {
    let title: LocalizedStringResource
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).accessibilityHidden(true)
            Text(value).font(.headline.weight(.bold))
            Text(title).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .accessibilityElement(children: .combine)
    }
}

struct StatsChart: View {
    let data: [ChartDatum]
    let metric: ChartMetric
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Things done")
                    .font(.headline.weight(.bold))
                Spacer()
                Text(data.reduce(0) { $0 + (metric == .tasks ? Double($1.tasks) : $1.points) }, format: .number.precision(.fractionLength(0...2)))
                    .font(.headline)
            }
            Text(metric == .tasks ? "Tasks recorded in the selected period" : "$ earned in the selected period")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Chart(data) { item in
                BarMark(
                    x: .value("Period", item.label),
                    y: .value(metric.rawValue, metric == .tasks ? Double(item.tasks) : item.points)
                )
                .foregroundStyle(.blue)
                .cornerRadius(4)
            }
            .frame(minHeight: 220)
            .accessibilityLabel("\(metric.rawValue) activity chart")
        }
        .cardStyle()
    }
}

struct PaceCard: View {
    let store: LifeTallyStore

    var body: some View {
        let intervals = store.positiveIntervals(on: Date())
        VStack(alignment: .leading, spacing: 10) {
            Label("Pace records", systemImage: "gauge.with.dots.needle.67percent")
                .font(.headline)
            LabeledContent("Highest daily task count", value: store.highestDailyTaskCount.formatted())
            LabeledContent("Best recorded hour", value: store.bestHour.map { "\($0.label) • \($0.tasks) tasks" } ?? "No entries")
            LabeledContent("Today's intervals", value: intervals.isEmpty ? "Not enough entries" : "\(intervals.count)")
            Text("Intervals are between positive entries and describe logging pace.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }
}


struct ProgressionView: View {
    let store: LifeTallyStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let progress = store.progression
        ScrollView {
            LazyVStack(spacing: 18) {
                VStack(spacing: 3) {
                    Text("CURRENT LEVEL")
                        .font(.caption.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                    Text(progress.level, format: .number)
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .foregroundStyle(.blue)
                        .contentTransition(.numericText())
                }
                .padding(.vertical, 12)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Next level").font(.headline)
                        Spacer()
                        Text(LifeTallyFormat.points(progress.levelCost - progress.pointsWithinLevel))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(progress.pointsWithinLevel), total: Double(progress.levelCost))
                        .tint(.blue)
                    Text("\(LifeTallyFormat.points(progress.pointsWithinLevel)) of \(LifeTallyFormat.points(progress.levelCost))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .cardStyle()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Lifetime goal").font(.headline)
                    Text(LifeTallyFormat.points(store.lifetimePointsHundredths))
                        .font(.title3.weight(.bold))
                    Text("of \(LifeTallyFormat.points(ScoringRules.ultimateGoalHundredths)) lifetime")
                        .foregroundStyle(.secondary)
                    ProgressView(value: Double(store.lifetimePointsHundredths), total: Double(ScoringRules.ultimateGoalHundredths))
                        .tint(.blue)
                    Text(Double(store.lifetimePointsHundredths) / Double(ScoringRules.ultimateGoalHundredths), format: .percent.precision(.fractionLength(2)))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.blue)
                }
                .cardStyle()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Current momentum").font(.headline)
                    LabeledContent("Good-sleep streak", value: "\(store.currentGoodSleepStreak) days")
                    LabeledContent("Best good-sleep streak", value: "\(store.longestGoodSleepStreak) days")
                    Divider()
                    LabeledContent("Avoid-bad-habit streak", value: "\(store.currentCompletedStreak) days")
                    LabeledContent("Best avoid streak", value: "\(store.longestCompletedStreak) days")
                    Divider()
                    LabeledContent("Lifetime tasks", value: store.lifetimeTasks.formatted())
                }
                .cardStyle()
            }
            .padding()
        }
        .background(LifeTallyTheme.background)
        .navigationTitle("Progression")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LevelsView: View {
    let store: LifeTallyStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let progress = store.progression
        let visibleLevels = Array(max(1, progress.level - 2)...(progress.level + 12))

        ScrollView {
            LazyVStack(spacing: 14) {
                LifetimeGoalMilestone(pointsHundredths: store.lifetimePointsHundredths)
                CurrentLevelProgress(progress: progress)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Level path")
                        .font(.headline)
                    ForEach(visibleLevels, id: \.self) { level in
                        LevelProgressRow(
                            level: level,
                            currentLevel: progress.level,
                            currentPointsHundredths: progress.pointsWithinLevel
                        )
                    }
                }
            }
            .padding()
        }
        .background(LifeTallyTheme.background)
        .navigationTitle("Levels")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LifetimeGoalMilestone: View {
    let pointsHundredths: Int64

    var body: some View {
        let goal = ScoringRules.ultimateGoalHundredths
        let remaining = max(0, goal - pointsHundredths)
        let fraction = min(1, Double(pointsHundredths) / Double(goal))

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lifetime goal")
                        .font(.headline)
                    Text("Your ultimate milestone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "target")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(LifeTallyTheme.accent)
                    .frame(width: 34, height: 34)
                    .background(LifeTallyTheme.accent.opacity(0.1), in: Circle())
                    .accessibilityHidden(true)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(LifeTallyFormat.points(pointsHundredths))
                    .font(.title3.weight(.bold))
                    .contentTransition(.numericText(value: Double(pointsHundredths)))
                Text("of \(LifeTallyFormat.points(goal))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: fraction)
                .tint(LifeTallyTheme.accent)
                .scaleEffect(x: 1, y: 1.25)
                .animation(.smooth, value: fraction)

            HStack {
                Text(fraction, format: .percent.precision(.fractionLength(2)))
                    .foregroundStyle(LifeTallyTheme.accent)
                Spacer()
                Text("\(LifeTallyFormat.points(remaining)) to go")
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.semibold))
        }
        .cardStyle()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Lifetime goal. \(LifeTallyFormat.points(pointsHundredths)) of 1 billion dollars. \(LifeTallyFormat.points(remaining)) remaining."
        )
    }
}

struct CurrentLevelProgress: View {
    let progress: Progression

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Level \(progress.level)")
                    .font(.headline.weight(.bold))
                Spacer()
                Text("Level \(progress.level + 1)")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.blue)
            }
            ProgressView(
                value: Double(progress.pointsWithinLevel),
                total: Double(progress.levelCost)
            )
            .tint(.blue)
            .scaleEffect(x: 1, y: 1.5)
            HStack {
                Text(LifeTallyFormat.points(progress.pointsWithinLevel))
                Spacer()
                Text("\(LifeTallyFormat.points(progress.levelCost - progress.pointsWithinLevel)) to go")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.blue.opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct LevelProgressRow: View {
    let level: Int
    let currentLevel: Int
    let currentPointsHundredths: Int64

    var body: some View {
        let cost = ScoringRules.levelCostHundredths(from: level)
        let progress: Int64 = level < currentLevel ? cost : (level == currentLevel ? currentPointsHundredths : 0)

        VStack(spacing: 8) {
            HStack {
                Text("Level \(level)")
                    .font(.subheadline.weight(level == currentLevel ? .bold : .semibold))
                Spacer()
                Text("Level \(level + 1)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(level == currentLevel ? .blue : .secondary)
            }
            ProgressView(value: Double(progress), total: Double(cost))
                .tint(level <= currentLevel ? .blue : Color.secondary.opacity(0.3))
            Group {
                if level < currentLevel {
                    Label("Complete", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                } else if level == currentLevel {
                    Text("\(LifeTallyFormat.points(progress)) / \(LifeTallyFormat.points(cost))")
                        .foregroundStyle(.blue)
                } else {
                    Text("\(LifeTallyFormat.points(cost)) required")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            level == currentLevel ? Color.blue.opacity(0.08) : LifeTallyTheme.surface,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(level == currentLevel ? Color.blue.opacity(0.3) : LifeTallyTheme.border, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ProgressionMetric: View {
    let title: LocalizedStringResource
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .cardStyle()
        .accessibilityElement(children: .combine)
    }
}

struct SettingsView: View {
    let store: LifeTallyStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Storage") {
                Label("Saved locally with SwiftData", systemImage: "internaldrive")
                if let errorMessage = store.lastError {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            Section("iCloud") {
                Label("CloudKit sync is automatic when the signed app has the iCloud capability and a private CloudKit container.", systemImage: "icloud")
                Text("Life Tally does not claim a verified sync state because CloudKit synchronization is asynchronous.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ResetDataSection(store: store)
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

private struct ResetDataSection: View {
    private static let confirmationPhrase = "RESET"

    let store: LifeTallyStore
    @State private var confirmationText = ""
    @State private var showingConfirmation = false

    var body: some View {
        Section("Reset Data") {
            Text("Permanently delete all Life Tally data, including tasks, history, habits, and progress.")
                .foregroundStyle(.secondary)

            Button("Reset All Data", systemImage: "trash", role: .destructive) {
                confirmationText = ""
                showingConfirmation = true
            }
        }
        .alert("Are you sure you want to reset data?", isPresented: $showingConfirmation) {
            TextField("Type RESET to confirm", text: $confirmationText)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()

            Button("Reset Data", role: .destructive) {
                store.resetAllData()
                confirmationText = ""
            }
            .disabled(confirmationText != Self.confirmationPhrase)

            Button("Cancel", role: .cancel) {
                confirmationText = ""
            }
        } message: {
            Text("This cannot be undone. Type RESET to permanently delete all of your data.")
        }
    }
}

extension View {
    func cardStyle(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(LifeTallyTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(LifeTallyTheme.border, lineWidth: 1)
            }
            .shadow(color: LifeTallyTheme.shadow, radius: 8, y: 3)
    }
}
