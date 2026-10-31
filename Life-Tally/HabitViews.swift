import SwiftUI

struct HabitsView: View {
    let store: LifeTallyStore
    @State private var showingNewHabit = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                HabitDaySummary(
                    completed: store.completedHabitCount(),
                    total: store.activeHabits.count
                )

                if store.activeHabits.isEmpty {
                    HabitEmptyState { showingNewHabit = true }
                } else {
                    ForEach(store.activeHabits) { habit in
                        DailyHabitTile(
                            habit: habit,
                            store: store,
                            name: habit.name,
                            details: habit.details,
                            symbolName: habit.symbolName,
                            isCompleted: store.isHabitCompleted(habit),
                            streak: store.habitStreak(habit),
                            history: store.habitHistory(habit),
                            toggle: { toggle(habit) },
                            archive: { store.archiveHabit(habit) }
                        )
                    }
                }
            }
            .padding()
        }
        .background(LifeTallyTheme.background)
        .navigationTitle("Daily Habits")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New habit", systemImage: "plus") {
                    showingNewHabit = true
                }
                .accessibilityHint("Creates a custom daily habit")
            }
        }
        .sheet(isPresented: $showingNewHabit) {
            NewHabitView(store: store)
        }
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

struct HabitDaySummary: View {
    let completed: Int
    let total: Int

    var body: some View {
        let fraction = total == 0 ? 0 : Double(completed) / Double(total)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                    Text(completed == total && total > 0 ? "All done today" : "Build your momentum")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                }
                Spacer()
                Text("\(completed)/\(total)")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }

            ProgressView(value: fraction)
                .tint(.white)

            Label(
                "\(LifeTallyFormat.points(Int64(completed) * ScoringRules.habitCompletionHundredths)) earned today",
                systemImage: "sparkles"
            )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [LifeTallyTheme.accent, LifeTallyTheme.accent.opacity(0.72)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Today's habits. \(completed) of \(total) complete. \(LifeTallyFormat.points(Int64(completed) * ScoringRules.habitCompletionHundredths)) earned."
        )
    }
}

struct DailyHabitTile: View {
    let habit: TrackedHabit
    let store: LifeTallyStore
    let name: String
    let details: String
    let symbolName: String
    let isCompleted: Bool
    let streak: Int
    let history: [HabitDayMark]
    let toggle: () -> Void
    let archive: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 13) {
                Image(systemName: symbolName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(LifeTallyTheme.accent)
                    .frame(width: 44, height: 44)
                    .background(
                        LifeTallyTheme.accent.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.headline)
                    if !details.isEmpty {
                        Text(details)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                NavigationLink {
                    HabitDetailView(store: store, habit: habit)
                } label: {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LifeTallyTheme.accent)
                        .frame(width: 38, height: 38)
                        .background(LifeTallyTheme.accent.opacity(0.08), in: Circle())
                }
                .accessibilityLabel("View stats for \(name)")

                Button(action: toggle) {
                    Image(systemName: isCompleted ? "checkmark" : "plus")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(isCompleted ? .white : LifeTallyTheme.accent)
                        .frame(width: 42, height: 42)
                        .background(
                            isCompleted ? LifeTallyTheme.accent : LifeTallyTheme.accent.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(LifeTallyTheme.accent.opacity(0.35), lineWidth: 1.5)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isCompleted
                        ? "Mark \(name) incomplete"
                        : "Complete \(name) for \(LifeTallyFormat.points(ScoringRules.habitCompletionHundredths))"
                )
            }

            HabitHeatmap(history: history)

            HStack {
                Label(streak == 1 ? "1 day streak" : "\(streak) day streak", systemImage: "flame.fill")
                Spacer()
                Label(
                    isCompleted
                        ? "\(LifeTallyFormat.points(ScoringRules.habitCompletionHundredths)) earned"
                        : "Worth \(LifeTallyFormat.points(ScoringRules.habitCompletionHundredths))",
                    systemImage: "sparkles"
                )
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(LifeTallyTheme.accent)
        }
        .padding(17)
        .background(LifeTallyTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(isCompleted ? LifeTallyTheme.accent.opacity(0.22) : LifeTallyTheme.border, lineWidth: 1)
        }
        .shadow(color: LifeTallyTheme.shadow, radius: 10, y: 4)
        .contextMenu {
            Button("Archive habit", systemImage: "archivebox", role: .destructive, action: archive)
        }
    }
}

struct HabitDetailView: View {
    let store: LifeTallyStore
    let habit: TrackedHabit

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                HabitDetailHero(
                    name: habit.name,
                    details: habit.details,
                    symbolName: habit.symbolName,
                    isCompletedToday: store.isHabitCompleted(habit),
                    toggle: { store.toggleHabit(habit) }
                )

                HabitMetricsGrid(
                    currentStreak: store.habitStreak(habit),
                    bestStreak: store.habitBestStreak(habit),
                    completions: store.habitCompletionCount(habit),
                    points: store.habitCompletionCount(habit) * Int(ScoringRules.habitCompletionHundredths / 100)
                )

                HabitHistoryCard(
                    history: store.habitHistory(habit, dayCount: 364),
                    completionRate: store.habitCompletionRate(habit)
                )
            }
            .padding()
        }
        .background(LifeTallyTheme.background)
        .navigationTitle(habit.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct HabitDetailHero: View {
    let name: String
    let details: String
    let symbolName: String
    let isCompletedToday: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbolName)
                .font(.title.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 62, height: 62)
                .background(LifeTallyTheme.accent, in: RoundedRectangle(cornerRadius: 19, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.headline.weight(.bold))
                if !details.isEmpty {
                    Text(details)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: toggle) {
                Image(systemName: isCompletedToday ? "checkmark" : "plus")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(LifeTallyTheme.accent, in: Circle())
            }
            .accessibilityLabel(
                isCompletedToday
                    ? "Mark incomplete today"
                    : "Complete for \(LifeTallyFormat.points(ScoringRules.habitCompletionHundredths))"
            )
        }
        .padding(18)
        .background(LifeTallyTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct HabitMetricsGrid: View {
    let currentStreak: Int
    let bestStreak: Int
    let completions: Int
    let points: Int

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            HabitMetricTile(title: "Current streak", value: "\(currentStreak)", symbol: "flame.fill")
            HabitMetricTile(title: "Best streak", value: "\(bestStreak)", symbol: "trophy.fill")
            HabitMetricTile(title: "Completions", value: "\(completions)", symbol: "checkmark.circle.fill")
            HabitMetricTile(title: "Earned", value: "$\(points)", symbol: "sparkles")
        }
    }
}

struct HabitMetricTile: View {
    let title: LocalizedStringKey
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(LifeTallyTheme.accent)
            Text(value)
                .font(.title3.weight(.bold))
                .contentTransition(.numericText())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(LifeTallyTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct HabitHistoryCard: View {
    let history: [HabitDayMark]
    let completionRate: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Completion history")
                        .font(.headline)
                    Text("One square per day")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(completionRate, format: .percent.precision(.fractionLength(0)))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(LifeTallyTheme.accent)
                    .accessibilityLabel("30 day completion rate")
            }

            HabitHeatmap(history: history)

            HStack(spacing: 14) {
                Label("Completed", systemImage: "square.fill")
                    .foregroundStyle(LifeTallyTheme.accent)
                Label("Missed", systemImage: "square.fill")
                    .foregroundStyle(LifeTallyTheme.accent.opacity(0.15))
            }
            .font(.caption)
        }
        .padding(18)
        .background(LifeTallyTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct HabitHeatmap: View {
    let history: [HabitDayMark]
    private let rows = Array(repeating: GridItem(.fixed(13), spacing: 3), count: 7)

    var body: some View {
        ScrollView(.horizontal) {
            LazyHGrid(rows: rows, spacing: 3) {
                ForEach(history) { day in
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(day.isCompleted ? LifeTallyTheme.accent : LifeTallyTheme.accent.opacity(0.08))
                        .frame(width: 13, height: 13)
                        .overlay {
                            if day.isToday {
                                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                    .stroke(LifeTallyTheme.accent, lineWidth: 1.5)
                            }
                        }
                        .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue(day.isCompleted ? "Completed" : "Not completed")
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.trailing)
        .frame(height: 109)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Completion history")
    }
}

struct HabitEmptyState: View {
    let create: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.square.fill")
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(LifeTallyTheme.accent)
                .frame(width: 72, height: 72)
                .background(LifeTallyTheme.accent.opacity(0.1), in: Circle())
            Text("Create your first habit")
                .font(.headline.weight(.bold))
            Text("Add a daily action, check it off, and earn \(LifeTallyFormat.points(ScoringRules.habitCompletionHundredths)) every time you complete it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Create a habit", systemImage: "plus", action: create)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(LifeTallyTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct NewHabitView: View {
    let store: LifeTallyStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var details = ""
    @State private var symbolName = "checkmark.circle.fill"

    private let symbols = [
        "checkmark.circle.fill", "figure.run", "drop.fill", "book.fill",
        "leaf.fill", "dumbbell.fill", "moon.stars.fill", "brain.head.profile"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Habit") {
                    TextField("Name", text: $name)
                    TextField("A short note (optional)", text: $details, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 14) {
                        ForEach(symbols, id: \.self) { symbol in
                            Button {
                                symbolName = symbol
                            } label: {
                                Image(systemName: symbol)
                                    .font(.title2)
                                    .foregroundStyle(symbolName == symbol ? .white : LifeTallyTheme.accent)
                                    .frame(width: 52, height: 52)
                                    .background(
                                        symbolName == symbol ? LifeTallyTheme.accent : LifeTallyTheme.accent.opacity(0.1),
                                        in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(symbol)
                            .accessibilityAddTraits(symbolName == symbol ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    Label(
                        "Each daily completion is worth \(LifeTallyFormat.points(ScoringRules.habitCompletionHundredths)).",
                        systemImage: "sparkles"
                    )
                        .foregroundStyle(LifeTallyTheme.accent)
                }
            }
            .navigationTitle("New Habit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        store.addHabit(name: name, details: details, symbolName: symbolName)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
