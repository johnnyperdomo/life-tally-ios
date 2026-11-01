import Foundation
import SwiftData

enum LedgerKind: String, Codable, CaseIterable {
    case task
    case correction
    case sleepBonus
    case habitBonus

    var title: String {
        switch self {
        case .task: "Task entry"
        case .correction: "Correction"
        case .sleepBonus: "Good sleep bonus"
        case .habitBonus: "Stayed on track bonus"
        }
    }
}

@Model
final class TallyEntry {
    var stableID: String = UUID().uuidString
    var timestamp: Date = Date()
    var dayKey: String = ""
    var kindRawValue: String = LedgerKind.task.rawValue
    var taskUnits: Int = 0
    var correctedEntryID: String?
    var intervalSeconds: Double?
    var levelMultiplierTenThousandths: Int64 = 10_000
    var createdAt: Date = Date()

    init(
        stableID: String = UUID().uuidString,
        timestamp: Date,
        dayKey: String,
        kind: LedgerKind,
        taskUnits: Int,
        correctedEntryID: String? = nil,
        intervalSeconds: Double? = nil,
        levelMultiplierTenThousandths: Int64 = 10_000
    ) {
        self.stableID = stableID
        self.timestamp = timestamp
        self.dayKey = dayKey
        self.kindRawValue = kind.rawValue
        self.taskUnits = taskUnits
        self.correctedEntryID = correctedEntryID
        self.intervalSeconds = intervalSeconds
        self.levelMultiplierTenThousandths = levelMultiplierTenThousandths
        self.createdAt = Date()
    }

    var kind: LedgerKind { LedgerKind(rawValue: kindRawValue) ?? .task }
}

@Model
final class DailyState {
    var stableID: String = UUID().uuidString
    var dayKey: String = ""
    var date: Date = Date()
    var goodSleep: Bool = false
    var habitFailed: Bool = false
    var finalized: Bool = false
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()

    init(dayKey: String, date: Date) {
        self.stableID = "day-\(dayKey)"
        self.dayKey = dayKey
        self.date = date
    }
}

@Model
final class AppProfile {
    var stableID: String = "life-tally-profile"
    var trackingStart: Date = Date()
    var createdAt: Date = Date()

    init(trackingStart: Date) {
        self.trackingStart = trackingStart
    }
}

@Model
final class TrackedHabit {
    var stableID: String = UUID().uuidString
    var name: String = ""
    var details: String = ""
    var symbolName: String = "checkmark.circle.fill"
    var createdAt: Date = Date()
    var isArchived: Bool = false

    init(name: String, details: String, symbolName: String) {
        self.name = name
        self.details = details
        self.symbolName = symbolName
    }

    var displaySymbolName: String {
        let trimmedSymbolName = symbolName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedSymbolName.isEmpty ? "checkmark.circle.fill" : trimmedSymbolName
    }
}

@Model
final class HabitCompletion {
    var stableID: String = UUID().uuidString
    var habitID: String = ""
    var dayKey: String = ""
    var completedAt: Date = Date()

    init(habitID: String, dayKey: String, completedAt: Date) {
        self.stableID = "habit-\(habitID)-\(dayKey)"
        self.habitID = habitID
        self.dayKey = dayKey
        self.completedAt = completedAt
    }
}

struct DaySummary: Identifiable, Equatable {
    let dayKey: String
    let date: Date
    let tasks: Int
    let pointsHundredths: Int64
    let sleep: Bool
    let failed: Bool
    let finalized: Bool
    let completedStreakBeforeDay: Int

    var id: String { dayKey }
}

struct Progression: Equatable {
    let level: Int
    let pointsWithinLevel: Int64
    let levelCost: Int64
}

struct HabitDayMark: Identifiable, Equatable {
    let dayKey: String
    let date: Date
    let isCompleted: Bool
    let isToday: Bool

    var id: String { dayKey }
}

enum ScoringRules {
    // The first base task earns $100 before streak, sleep, habit, and level multipliers.
    static let economyScale: Int64 = 100
    static let ultimateGoalHundredths: Int64 = 1_000_000_000 * 100
    static let sleepBonusHundredths: Int64 = 50 * economyScale * 100
    static let successBonusHundredths: Int64 = 100 * economyScale * 100
    static let habitCompletionHundredths: Int64 = 5 * economyScale * 100
    // Level 3 stays near 20–30 additions from a fresh start; progression remains money-based.
    static let startingLevelCostHundredths: Int64 = 1_200 * 100
    static let levelCostGrowthPercent: Int64 = 18

    static func streakMultiplierHundredths(completedDays: Int) -> Int64 {
        switch completedDays {
        case ..<1: 100
        case 1: 150
        case 2: 200
        default: 300
        }
    }

    static func habitMultiplierHundredths(completedHabits: Int) -> Int64 {
        100 + Int64(max(0, completedHabits)) * 17
    }

    static func combinedMultiplierHundredths(
        goodSleep: Bool,
        failed: Bool,
        completedDays: Int,
        completedHabits: Int
    ) -> Int64 {
        let streakAndSleep: Int64
        if failed {
            streakAndSleep = 100
        } else {
            let sleep: Int64 = goodSleep ? 150 : 100
            streakAndSleep = sleep * streakMultiplierHundredths(completedDays: completedDays) / 100
        }

        return streakAndSleep * habitMultiplierHundredths(completedHabits: completedHabits) / 100
    }

    static func levelMultiplierTenThousandths(level: Int) -> Int64 {
        10_000 + Int64(max(0, level - 1)) * 960
    }

    static func taskGrowthMultiplierTenThousandths(completedTasks: Int, units: Int = 1) -> Int64 {
        let taskCount = max(0, completedTasks)
        let unitCount = max(1, units)
        let firstMultiplier = pow(1.005, Double(taskCount))
        let averageMultiplier = (0..<unitCount).reduce(0.0) { total, offset in
            total + firstMultiplier * pow(1.005, Double(offset))
        } / Double(unitCount)
        return Int64((averageMultiplier * 10_000).rounded())
    }

    static func taskPointsHundredths(
        units: Int,
        goodSleep: Bool,
        failed: Bool,
        completedDays: Int,
        completedHabits: Int,
        levelMultiplierTenThousandths: Int64 = 10_000
    ) -> Int64 {
        let base = Int64(units) * economyScale * combinedMultiplierHundredths(
            goodSleep: goodSleep,
            failed: failed,
            completedDays: completedDays,
            completedHabits: completedHabits
        )
        return base * levelMultiplierTenThousandths / 10_000
    }

    static func levelCostHundredths(from level: Int) -> Int64 {
        let normalizedLevel = max(1, level)
        var cost = startingLevelCostHundredths

        for _ in 1..<normalizedLevel {
            cost = min(
                ultimateGoalHundredths,
                cost * (100 + levelCostGrowthPercent) / 100
            )
        }

        let adjustedForPermanentBonus = cost
            * levelMultiplierTenThousandths(level: normalizedLevel)
            / 10_000
        return min(ultimateGoalHundredths, adjustedForPermanentBonus)
    }

    static func pointsRequiredToReachLevel(_ targetLevel: Int) -> Int64 {
        guard targetLevel > 1 else { return 0 }
        return (1..<targetLevel).reduce(Int64(0)) { total, level in
            total + levelCostHundredths(from: level)
        }
    }

    static func progression(for lifetimeHundredths: Int64) -> Progression {
        var remaining = max(0, lifetimeHundredths)
        var level = 1
        while remaining >= levelCostHundredths(from: level) {
            remaining -= levelCostHundredths(from: level)
            level += 1
        }
        return Progression(
            level: level,
            pointsWithinLevel: remaining,
            levelCost: levelCostHundredths(from: level)
        )
    }
}

enum LifeTallyFormat {
    static func points(_ hundredths: Int64) -> String {
        let value = Decimal(abs(hundredths)) / 100
        let amount = value.formatted(.number.precision(.fractionLength(2)))
        return hundredths < 0 ? "-$\(amount)" : "$\(amount)"
    }

    static func pointsLabel(_ hundredths: Int64) -> String {
        points(hundredths)
    }

    static func multiplier(_ hundredths: Int64) -> String {
        let value = Decimal(hundredths) / 100
        return value.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 { return "\(total / 3600)h \((total % 3600) / 60)m" }
        if total >= 60 { return "\(total / 60)m \(total % 60)s" }
        return "\(total)s"
    }

    static func preciseDuration(_ seconds: Double) -> String {
        let elapsed = max(0, seconds)
        let minutes = Int(elapsed) / 60
        let remainingSeconds = elapsed.truncatingRemainder(dividingBy: 60)
        if minutes > 0 {
            return String(format: "%d:%05.2f", minutes, remainingSeconds)
        }
        return String(format: "%.2fs", remainingSeconds)
    }
}
