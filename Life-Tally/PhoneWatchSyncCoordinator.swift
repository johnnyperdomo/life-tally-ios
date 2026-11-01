import Foundation
@preconcurrency import WatchConnectivity

@MainActor
final class PhoneWatchSyncCoordinator: NSObject, WCSessionDelegate {
    private static let processedCommandIDsKey = "LifeTally.watch.processedCommandIDs"
    private static let processedCommandIDLimit = 200

    private let store: LifeTallyStore
    private let session: WCSession?

    init(store: LifeTallyStore) {
        self.store = store
        session = WCSession.isSupported() ? .default : nil
        super.init()

        store.setChangeHandler { [weak self] in
            self?.sendCurrentState()
        }

        session?.delegate = self
        session?.activate()
    }

    func sendCurrentState() {
        guard
            let session,
            session.activationState == .activated
        else {
            return
        }

        let currentPayload = payload()
        try? session.updateApplicationContext(currentPayload)

        if session.isReachable {
            session.sendMessage(currentPayload, replyHandler: nil, errorHandler: nil)
        }
    }

    private func payload() -> [String: Any] {
        let summary = store.today
        let progress = store.progression
        let completedHabits = store.completedHabitCount()
        let dailyMultiplier = ScoringRules.combinedMultiplierHundredths(
            goodSleep: summary.sleep,
            failed: summary.failed,
            completedDays: summary.completedStreakBeforeDay,
            completedHabits: completedHabits
        )
        let levelMultiplier = ScoringRules.levelMultiplierTenThousandths(level: progress.level)
        let oneTaskGrowth = ScoringRules.taskGrowthMultiplierTenThousandths(
            completedTasks: store.lifetimeTasks
        )
        let fiveTaskGrowth = ScoringRules.taskGrowthMultiplierTenThousandths(
            completedTasks: store.lifetimeTasks,
            units: 5
        )
        let oneTaskMultiplier = levelMultiplier * oneTaskGrowth / 10_000
        let fiveTaskMultiplier = levelMultiplier * fiveTaskGrowth / 10_000
        let combinedMultiplier = dailyMultiplier * oneTaskMultiplier / 10_000
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
        let latestEntryTimestamp = store.latestRemainingPositive(on: Date())?
            .timestamp.timeIntervalSince1970 ?? 0

        return [
            "lifetimePointsHundredths": store.lifetimePointsHundredths,
            "todayPointsHundredths": summary.pointsHundredths,
            "todayTasks": summary.tasks,
            "level": progress.level,
            "pointsWithinLevel": progress.pointsWithinLevel,
            "levelCost": progress.levelCost,
            "combinedMultiplierHundredths": combinedMultiplier,
            "oneTaskRewardHundredths": oneTaskReward,
            "fiveTaskRewardHundredths": fiveTaskReward,
            "latestEntryTimestamp": latestEntryTimestamp,
            "processedCommandIDs": UserDefaults.standard.stringArray(forKey: Self.processedCommandIDsKey) ?? [],
            "updatedAt": Date.now.timeIntervalSince1970
        ]
    }

    private func handle(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)? = nil) {
        Task { @MainActor in
            if let amount = Self.int(message["addTasks"]), amount == 1 || amount == 5 {
                if let commandID = message["commandID"] as? String {
                    if markCommandAsProcessed(commandID) {
                        _ = store.addTasks(amount)
                    }
                } else {
                    _ = store.addTasks(amount)
                }
            } else {
                store.reload()
            }

            let currentPayload = payload()
            replyHandler?(currentPayload)
            try? session?.updateApplicationContext(currentPayload)
            session?.transferUserInfo(currentPayload)
        }
    }

    private func markCommandAsProcessed(_ commandID: String) -> Bool {
        let defaults = UserDefaults.standard
        var commandIDs = defaults.stringArray(forKey: Self.processedCommandIDsKey) ?? []
        guard !commandIDs.contains(commandID) else { return false }

        commandIDs.append(commandID)
        if commandIDs.count > Self.processedCommandIDLimit {
            commandIDs.removeFirst(commandIDs.count - Self.processedCommandIDLimit)
        }
        defaults.set(commandIDs, forKey: Self.processedCommandIDsKey)
        return true
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        Task { @MainActor in
            sendCurrentState()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            if session.isReachable {
                sendCurrentState()
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            handle(message, replyHandler: replyHandler)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            handle(userInfo)
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            sendCurrentState()
        }
    }
}
