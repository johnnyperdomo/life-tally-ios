import Foundation
import Observation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class LifeTallyStore {
    private static let economyVersion = 3
    private static let economyVersionKey = "LifeTally.economyVersion"

    private let context: ModelContext
    private(set) var entries: [TallyEntry] = []
    private(set) var days: [DailyState] = []
    private(set) var habits: [TrackedHabit] = []
    private(set) var habitCompletions: [HabitCompletion] = []
    private(set) var profile: AppProfile?
    private(set) var lastError: String?
    var selectedHistoryDate = Date()
    var selectedStatsDate = Date()
    @ObservationIgnored private var changeHandler: (() -> Void)?

    init(context: ModelContext) {
        self.context = context
        reload()

        if UserDefaults.standard.integer(forKey: Self.economyVersionKey) < Self.economyVersion,
           resetAllData() {
            UserDefaults.standard.set(Self.economyVersion, forKey: Self.economyVersionKey)
        }

        reconcile()
    }

    func setChangeHandler(_ handler: @escaping () -> Void) {
        changeHandler = handler
    }

    func reload() {
        do {
            let fetchedEntries = try context.fetch(FetchDescriptor<TallyEntry>(
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            ))
            entries = Dictionary(grouping: fetchedEntries, by: \.stableID)
                .compactMap { $0.value.max(by: { $0.createdAt < $1.createdAt }) }
                .sorted { $0.timestamp > $1.timestamp }
            days = try context.fetch(FetchDescriptor<DailyState>(
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            ))
            habits = try context.fetch(FetchDescriptor<TrackedHabit>(
                sortBy: [SortDescriptor(\.createdAt)]
            ))
            habitCompletions = try context.fetch(FetchDescriptor<HabitCompletion>(
                sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
            ))
            let profiles = try context.fetch(FetchDescriptor<AppProfile>())
            if let existing = profiles.first {
                profile = existing
            } else {
                let created = AppProfile(trackingStart: Calendar.current.startOfDay(for: Date()))
                context.insert(created)
                profile = created
                try context.save()
            }
            lastError = nil
        } catch {
            lastError = "Local data could not be loaded: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func resetAllData(now: Date = Date()) -> Bool {
        do {
            try context.delete(model: TallyEntry.self)
            try context.delete(model: DailyState.self)
            try context.delete(model: TrackedHabit.self)
            try context.delete(model: HabitCompletion.self)
            try context.delete(model: AppProfile.self)

            let startOfToday = Calendar.autoupdatingCurrent.startOfDay(for: now)
            context.insert(AppProfile(trackingStart: startOfToday))
            context.insert(DailyState(dayKey: dayKey(startOfToday), date: startOfToday))
            try context.save()

            selectedHistoryDate = now
            selectedStatsDate = now
            reload()
            changeHandler?()
            return true
        } catch {
            context.rollback()
            lastError = "Data could not be reset: \(error.localizedDescription)"
            return false
        }
    }

    func reconcile(now: Date = Date()) {
        guard let start = profile?.trackingStart else { return }
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: now)
        var cursor = calendar.startOfDay(for: start)
        while cursor <= today {
            _ = ensureDay(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        for day in days where day.date < today && !day.finalized {
            day.finalized = true
            day.modifiedAt = now
            ensureReward(kind: .habitBonus, day: day)
        }
        saveAndReload()
    }

    func addTasks(_ units: Int, now: Date = Date()) -> Int64 {
        reconcile(now: now)
        let day = ensureDay(now)
        let positive = positiveEntries(on: day.dayKey)
        let latest = positive.max(by: { $0.timestamp < $1.timestamp })
        let interval = latest.map { max(0, now.timeIntervalSince($0.timestamp)) }
        let levelMultiplier = ScoringRules.levelMultiplierTenThousandths(level: progression.level)
        let growthMultiplier = ScoringRules.taskGrowthMultiplierTenThousandths(
            completedTasks: lifetimeTasks,
            units: units
        )
        let rewardMultiplier = levelMultiplier * growthMultiplier / 10_000
        let entry = TallyEntry(
            timestamp: now,
            dayKey: day.dayKey,
            kind: .task,
            taskUnits: units,
            intervalSeconds: interval,
            levelMultiplierTenThousandths: rewardMultiplier
        )
        context.insert(entry)
        saveAndReload()
        return ScoringRules.taskPointsHundredths(
            units: units,
            goodSleep: day.goodSleep,
            failed: day.habitFailed,
            completedDays: completedStreak(before: day.date),
            completedHabits: completedHabitCount(on: day.date),
            levelMultiplierTenThousandths: rewardMultiplier
        )
    }

    func correct(_ requestedUnits: Int, now: Date = Date()) {
        reconcile(now: now)
        let key = dayKey(now)
        var remaining = min(requestedUnits, taskCount(for: key))
        guard remaining > 0 else { return }
        let positives = positiveEntries(on: key).sorted { $0.timestamp > $1.timestamp }
        for source in positives where remaining > 0 {
            let alreadyCorrected = -entries
                .filter { $0.kind == .correction && $0.correctedEntryID == source.stableID }
                .reduce(0) { $0 + $1.taskUnits }
            let available = max(0, source.taskUnits - alreadyCorrected)
            let amount = min(available, remaining)
            guard amount > 0 else { continue }
            context.insert(TallyEntry(
                timestamp: now,
                dayKey: key,
                kind: .correction,
                taskUnits: -amount,
                correctedEntryID: source.stableID,
                levelMultiplierTenThousandths: source.levelMultiplierTenThousandths
            ))
            remaining -= amount
        }
        saveAndReload()
    }

    func setGoodSleep(_ enabled: Bool, now: Date = Date()) {
        reconcile(now: now)
        let day = ensureDay(now)
        day.goodSleep = enabled
        day.modifiedAt = now
        if enabled {
            ensureReward(kind: .sleepBonus, day: day)
        }
        saveAndReload()
    }

    func setHabitFailed(_ failed: Bool, now: Date = Date()) {
        reconcile(now: now)
        let day = ensureDay(now)
        day.habitFailed = failed
        day.modifiedAt = now
        saveAndReload()
    }

    func summary(for date: Date) -> DaySummary {
        let key = dayKey(date)
        let day = ensureDay(date)
        let streak = completedStreak(before: day.date)
        let tasks = taskCount(for: key)
        let completedHabits = completedHabitCount(on: date)
        var points = entries
            .filter { $0.dayKey == key && ($0.kind == .task || $0.kind == .correction) }
            .reduce(Int64(0)) { total, entry in
                total + ScoringRules.taskPointsHundredths(
                    units: entry.taskUnits,
                    goodSleep: day.goodSleep,
                    failed: day.habitFailed,
                    completedDays: streak,
                    completedHabits: completedHabits,
                    levelMultiplierTenThousandths: entry.levelMultiplierTenThousandths
                )
            }
        if day.goodSleep { points += ScoringRules.sleepBonusHundredths }
        if day.finalized && !day.habitFailed { points += ScoringRules.successBonusHundredths }
        points += Int64(completedHabits) * ScoringRules.habitCompletionHundredths
        return DaySummary(
            dayKey: key,
            date: day.date,
            tasks: tasks,
            pointsHundredths: points,
            sleep: day.goodSleep,
            failed: day.habitFailed,
            finalized: day.finalized,
            completedStreakBeforeDay: streak
        )
    }

    var today: DaySummary { summary(for: Date()) }

    var lifetimeTasks: Int {
        entries.filter { $0.kind == .task || $0.kind == .correction }.reduce(0) { $0 + $1.taskUnits }
    }

    var lifetimePointsHundredths: Int64 {
        days.reduce(0) { $0 + summary(for: $1.date).pointsHundredths }
    }

    var progression: Progression {
        ScoringRules.progression(for: lifetimePointsHundredths)
    }

    var activeHabits: [TrackedHabit] {
        habits.filter { !$0.isArchived }
    }

    func addHabit(name: String, details: String, symbolName: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let trimmedSymbolName = symbolName.trimmingCharacters(in: .whitespacesAndNewlines)
        context.insert(TrackedHabit(
            name: trimmedName,
            details: details.trimmingCharacters(in: .whitespacesAndNewlines),
            symbolName: trimmedSymbolName.isEmpty ? "checkmark.circle.fill" : trimmedSymbolName
        ))
        saveAndReload()
    }

    func archiveHabit(_ habit: TrackedHabit) {
        habit.isArchived = true
        saveAndReload()
    }

    func isHabitCompleted(_ habit: TrackedHabit, on date: Date = Date()) -> Bool {
        let key = dayKey(date)
        return habitCompletions.contains { $0.habitID == habit.stableID && $0.dayKey == key }
    }

    func toggleHabit(_ habit: TrackedHabit, on date: Date = Date()) {
        let key = dayKey(date)
        if let completion = habitCompletions.first(where: {
            $0.habitID == habit.stableID && $0.dayKey == key
        }) {
            context.delete(completion)
        } else {
            context.insert(HabitCompletion(habitID: habit.stableID, dayKey: key, completedAt: date))
        }
        saveAndReload()
    }

    func completedHabitCount(on date: Date = Date()) -> Int {
        let key = dayKey(date)
        return habitCompletions.filter { $0.dayKey == key }.count
    }

    func habitStreak(_ habit: TrackedHabit, through date: Date = Date()) -> Int {
        let calendar = Calendar.autoupdatingCurrent
        var cursor = calendar.startOfDay(for: date)
        var streak = 0
        while isHabitCompleted(habit, on: cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    func habitHistory(_ habit: TrackedHabit, endingOn date: Date = Date(), dayCount: Int = 126) -> [HabitDayMark] {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: date)
        let count = max(1, dayCount)
        let completionKeys = Set(
            habitCompletions
                .filter { $0.habitID == habit.stableID }
                .map(\.dayKey)
        )

        return (0..<count).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset - count + 1, to: today) else {
                return nil
            }
            let key = dayKey(day)
            return HabitDayMark(
                dayKey: key,
                date: day,
                isCompleted: completionKeys.contains(key),
                isToday: calendar.isDate(day, inSameDayAs: today)
            )
        }
    }

    func habitCompletionCount(_ habit: TrackedHabit) -> Int {
        habitCompletions.filter { $0.habitID == habit.stableID }.count
    }

    func habitBestStreak(_ habit: TrackedHabit) -> Int {
        let calendar = Calendar.autoupdatingCurrent
        let completedDates = habitCompletions
            .filter { $0.habitID == habit.stableID }
            .map { calendar.startOfDay(for: $0.completedAt) }
            .sorted()
        guard !completedDates.isEmpty else { return 0 }

        var best = 1
        var current = 1
        for pair in zip(completedDates, completedDates.dropFirst()) {
            let daysApart = calendar.dateComponents([.day], from: pair.0, to: pair.1).day ?? 0
            if daysApart == 1 {
                current += 1
                best = max(best, current)
            } else if daysApart > 1 {
                current = 1
            }
        }
        return best
    }

    func habitCompletionRate(_ habit: TrackedHabit, dayCount: Int = 30) -> Double {
        let history = habitHistory(habit, dayCount: dayCount)
        guard !history.isEmpty else { return 0 }
        return Double(history.filter(\.isCompleted).count) / Double(history.count)
    }

    var currentCompletedStreak: Int {
        completedStreak(before: Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: Date()) ?? Date())
    }

    var longestCompletedStreak: Int {
        var longest = 0
        var current = 0
        for day in days.filter(\.finalized).sorted(by: { $0.date < $1.date }) {
            current = day.habitFailed ? 0 : current + 1
            longest = max(longest, current)
        }
        return longest
    }

    var currentGoodSleepStreak: Int {
        var count = 0
        for day in days.filter(\.finalized).sorted(by: { $0.date > $1.date }) {
            guard day.goodSleep else { break }
            count += 1
        }
        return count
    }

    var longestGoodSleepStreak: Int {
        var longest = 0
        var current = 0
        for day in days.filter(\.finalized).sorted(by: { $0.date < $1.date }) {
            current = day.goodSleep ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }

    func entries(for date: Date) -> [TallyEntry] {
        entries.filter { $0.dayKey == dayKey(date) }.sorted { $0.timestamp > $1.timestamp }
    }

    func points(for entry: TallyEntry) -> Int64 {
        guard let day = days.first(where: { $0.dayKey == entry.dayKey }) else { return 0 }
        switch entry.kind {
        case .task, .correction:
            return ScoringRules.taskPointsHundredths(
                units: entry.taskUnits,
                goodSleep: day.goodSleep,
                failed: day.habitFailed,
                completedDays: completedStreak(before: day.date),
                completedHabits: completedHabitCount(on: day.date),
                levelMultiplierTenThousandths: entry.levelMultiplierTenThousandths
            )
        case .sleepBonus:
            return day.goodSleep ? ScoringRules.sleepBonusHundredths : 0
        case .habitBonus:
            return day.finalized && !day.habitFailed ? ScoringRules.successBonusHundredths : 0
        }
    }

    func runningTaskTotal(at entry: TallyEntry) -> Int {
        entries
            .filter { $0.dayKey == entry.dayKey && $0.timestamp <= entry.timestamp && ($0.kind == .task || $0.kind == .correction) }
            .reduce(0) { $0 + $1.taskUnits }
    }

    func positiveIntervals(on date: Date) -> [Double] {
        let remaining = remainingPositiveEntries(on: dayKey(date)).sorted { $0.timestamp < $1.timestamp }
        return zip(remaining, remaining.dropFirst()).map { later, next in
            max(0, next.timestamp.timeIntervalSince(later.timestamp))
        }
    }

    func latestRemainingPositive(on date: Date) -> TallyEntry? {
        remainingPositiveEntries(on: dayKey(date)).max { $0.timestamp < $1.timestamp }
    }

    func hourlyTasks(on date: Date) -> [(hour: Int, tasks: Int)] {
        let calendar = Calendar.autoupdatingCurrent
        return (0..<24).map { hour in
            let tasks = positiveEntries(on: dayKey(date))
                .filter { calendar.component(.hour, from: $0.timestamp) == hour }
                .reduce(0) { $0 + $1.taskUnits }
            return (hour, tasks)
        }
    }

    var highestDailyTaskCount: Int { days.map { summary(for: $0.date).tasks }.max() ?? 0 }

    var bestHour: (label: String, tasks: Int)? {
        let calendar = Calendar.autoupdatingCurrent
        let grouped = Dictionary(grouping: entries.filter { $0.kind == .task }) {
            "\($0.dayKey)-\(calendar.component(.hour, from: $0.timestamp))"
        }
        guard let best = grouped.max(by: {
            $0.value.reduce(0) { $0 + $1.taskUnits } < $1.value.reduce(0) { $0 + $1.taskUnits }
        }) else { return nil }
        let hour = calendar.component(.hour, from: best.value[0].timestamp)
        let label = Date(timeIntervalSince1970: Double(hour * 3600)).formatted(.dateTime.hour())
        return (label, best.value.reduce(0) { $0 + $1.taskUnits })
    }

    private func ensureDay(_ date: Date) -> DailyState {
        let key = dayKey(date)
        if let existing = days.first(where: { $0.dayKey == key }) { return existing }
        let day = DailyState(dayKey: key, date: Calendar.autoupdatingCurrent.startOfDay(for: date))
        context.insert(day)
        days.append(day)
        return day
    }

    private func ensureReward(kind: LedgerKind, day: DailyState) {
        guard kind == .sleepBonus || (kind == .habitBonus && !day.habitFailed) else { return }
        let id = "reward-\(kind.rawValue)-\(day.dayKey)"
        guard !entries.contains(where: { $0.stableID == id }) else { return }
        context.insert(TallyEntry(stableID: id, timestamp: day.date, dayKey: day.dayKey, kind: kind, taskUnits: 0))
    }

    private func taskCount(for key: String) -> Int {
        max(0, entries.filter { $0.dayKey == key && ($0.kind == .task || $0.kind == .correction) }.reduce(0) { $0 + $1.taskUnits })
    }

    private func positiveEntries(on key: String) -> [TallyEntry] {
        entries.filter { $0.dayKey == key && $0.kind == .task }
    }

    private func remainingPositiveEntries(on key: String) -> [TallyEntry] {
        positiveEntries(on: key).filter { source in
            let corrected = -entries
                .filter { $0.kind == .correction && $0.correctedEntryID == source.stableID }
                .reduce(0) { $0 + $1.taskUnits }
            return corrected < source.taskUnits
        }
    }

    private func completedStreak(before date: Date) -> Int {
        var count = 0
        for day in days.filter({ $0.finalized && $0.date < date }).sorted(by: { $0.date > $1.date }) {
            if day.habitFailed { break }
            count += 1
        }
        return count
    }

    private func dayKey(_ date: Date) -> String {
        let components = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func saveAndReload() {
        do {
            try context.save()
            reload()
            changeHandler?()
        } catch {
            lastError = "Changes are safe in memory, but saving failed: \(error.localizedDescription)"
        }
    }
}
