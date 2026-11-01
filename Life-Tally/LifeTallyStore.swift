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
        ensureLockedProgression()
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

        let reward = ScoringRules.taskPointsHundredths(
            units: units,
            goodSleep: day.goodSleep,
            failed: day.habitFailed,
            completedDays: completedStreak(before: day.date),
            completedHabits: completedHabitCount(on: day.date),
            levelMultiplierTenThousandths: rewardMultiplier
        )
        applyLevelProgress(for: units, startingCompletedTasks: lifetimeTasks)
        saveAndReload()
        return reward
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
        guard
            let profile,
            profile.progressionLevelCostHundredths > 0
        else {
            return ScoringRules.progression(for: lifetimePointsHundredths)
        }

        return Progression(
            level: profile.progressionLevel,
            pointsWithinLevel: profile.progressionPointsHundredths,
            levelCost: profile.progressionLevelCostHundredths
        )
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

    func habitStatus(_ habit: TrackedHabit, on date: Date = Date()) -> HabitDayStatus? {
        let key = dayKey(date)
        return habitCompletions.first {
            $0.habitID == habit.stableID && $0.dayKey == key
        }?.status
    }

    func isHabitCompleted(_ habit: TrackedHabit, on date: Date = Date()) -> Bool {
        habitStatus(habit, on: date) == .completed
    }

    func isHabitSkipped(_ habit: TrackedHabit, on date: Date = Date()) -> Bool {
        habitStatus(habit, on: date) == .skipped
    }

    func toggleHabit(_ habit: TrackedHabit, on date: Date = Date()) {
        setHabitStatus(isHabitCompleted(habit, on: date) ? nil : .completed, for: habit, on: date)
    }

    func toggleHabitSkipped(_ habit: TrackedHabit, on date: Date = Date()) {
        setHabitStatus(isHabitSkipped(habit, on: date) ? nil : .skipped, for: habit, on: date)
    }

    private func setHabitStatus(_ status: HabitDayStatus?, for habit: TrackedHabit, on date: Date) {
        let key = dayKey(date)
        let existing = habitCompletions.first {
            $0.habitID == habit.stableID && $0.dayKey == key
        }

        if let status {
            if let existing {
                existing.statusRawValue = status.rawValue
                existing.completedAt = date
            } else {
                context.insert(HabitCompletion(
                    habitID: habit.stableID,
                    dayKey: key,
                    completedAt: date,
                    status: status
                ))
            }
        } else if let existing {
            context.delete(existing)
        }
        saveAndReload()
    }

    func completedHabitCount(on date: Date = Date()) -> Int {
        let key = dayKey(date)
        return habitCompletions.filter { $0.dayKey == key && $0.status == .completed }.count
    }

    func habitStreak(_ habit: TrackedHabit, through date: Date = Date()) -> Int {
        let calendar = Calendar.autoupdatingCurrent
        var cursor = calendar.startOfDay(for: date)
        var streak = 0

        while let status = habitStatus(habit, on: cursor) {
            if status == .completed {
                streak += 1
            }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    func habitHistory(_ habit: TrackedHabit, endingOn date: Date = Date(), dayCount: Int = 126) -> [HabitDayMark] {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: date)
        let count = max(1, dayCount)
        let statuses = Dictionary(
            uniqueKeysWithValues: habitCompletions
                .filter { $0.habitID == habit.stableID }
                .map { ($0.dayKey, $0.status) }
        )

        return (0..<count).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset - count + 1, to: today) else {
                return nil
            }
            let key = dayKey(day)
            return HabitDayMark(
                dayKey: key,
                date: day,
                status: statuses[key],
                isToday: calendar.isDate(day, inSameDayAs: today)
            )
        }
    }

    func habitCompletionCount(_ habit: TrackedHabit) -> Int {
        habitCompletions.filter { $0.habitID == habit.stableID && $0.status == .completed }.count
    }

    func habitBestStreak(_ habit: TrackedHabit) -> Int {
        let calendar = Calendar.autoupdatingCurrent
        let records = habitCompletions
            .filter { $0.habitID == habit.stableID }
            .sorted { $0.completedAt < $1.completedAt }
        guard !records.isEmpty else { return 0 }

        var best = 0
        var current = 0
        var previousDate: Date?

        for record in records {
            let date = calendar.startOfDay(for: record.completedAt)
            if let previousDate,
               calendar.dateComponents([.day], from: previousDate, to: date).day ?? 0 > 1 {
                current = 0
            }
            if record.status == .completed {
                current += 1
                best = max(best, current)
            }
            previousDate = date
        }
        return best
    }

    func habitCompletionRate(_ habit: TrackedHabit, dayCount: Int = 30) -> Double {
        let applicableDays = habitHistory(habit, dayCount: dayCount).filter { !$0.isSkipped }
        guard !applicableDays.isEmpty else { return 0 }
        return Double(applicableDays.filter(\.isCompleted).count) / Double(applicableDays.count)
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

    private func ensureLockedProgression() {
        guard
            let profile,
            profile.progressionLevelCostHundredths <= 0
        else {
            return
        }

        let legacyProgression = ScoringRules.progression(for: lifetimePointsHundredths)
        let nextReward = oneTaskRewardHundredths(
            level: legacyProgression.level,
            completedTasks: lifetimeTasks
        )
        let lockedCost = ScoringRules.lockedLevelCostHundredths(
            nextTaskRewardHundredths: nextReward
        )
        let progressFraction = Double(legacyProgression.pointsWithinLevel)
            / Double(max(1, legacyProgression.levelCost))

        profile.progressionLevel = legacyProgression.level
        profile.progressionLevelCostHundredths = lockedCost
        profile.progressionPointsHundredths = min(
            lockedCost - 1,
            Int64((Double(lockedCost) * progressFraction).rounded())
        )
    }

    private func applyLevelProgress(for units: Int, startingCompletedTasks: Int) {
        ensureLockedProgression()
        guard let profile else { return }

        for offset in 0..<max(0, units) {
            let reward = oneTaskRewardHundredths(
                level: profile.progressionLevel,
                completedTasks: startingCompletedTasks + offset
            )
            profile.progressionPointsHundredths += ScoringRules.boundedLevelProgressHundredths(
                rewardHundredths: reward,
                levelCostHundredths: profile.progressionLevelCostHundredths
            )

            if profile.progressionPointsHundredths >= profile.progressionLevelCostHundredths {
                profile.progressionPointsHundredths -= profile.progressionLevelCostHundredths
                profile.progressionLevel += 1

                let nextReward = oneTaskRewardHundredths(
                    level: profile.progressionLevel,
                    completedTasks: startingCompletedTasks + offset + 1
                )
                profile.progressionLevelCostHundredths = ScoringRules.lockedLevelCostHundredths(
                    nextTaskRewardHundredths: nextReward
                )
            }
        }
    }

    private func oneTaskRewardHundredths(level: Int, completedTasks: Int) -> Int64 {
        let summary = today
        let levelMultiplier = ScoringRules.levelMultiplierTenThousandths(level: level)
        let growthMultiplier = ScoringRules.taskGrowthMultiplierTenThousandths(
            completedTasks: completedTasks
        )
        return ScoringRules.taskPointsHundredths(
            units: 1,
            goodSleep: summary.sleep,
            failed: summary.failed,
            completedDays: summary.completedStreakBeforeDay,
            completedHabits: completedHabitCount(),
            levelMultiplierTenThousandths: levelMultiplier * growthMultiplier / 10_000
        )
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
