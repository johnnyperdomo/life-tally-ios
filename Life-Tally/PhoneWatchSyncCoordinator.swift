import Foundation
@preconcurrency import WatchConnectivity

@MainActor
final class PhoneWatchSyncCoordinator: NSObject, WCSessionDelegate {
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
        let combinedMultiplier = dailyMultiplier * levelMultiplier / 10_000
        let oneTaskReward = ScoringRules.taskPointsHundredths(
            units: 1,
            goodSleep: summary.sleep,
            failed: summary.failed,
            completedDays: summary.completedStreakBeforeDay,
            completedHabits: completedHabits,
            levelMultiplierTenThousandths: levelMultiplier
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
            "fiveTaskRewardHundredths": oneTaskReward * 5,
            "latestEntryTimestamp": latestEntryTimestamp,
            "updatedAt": Date.now.timeIntervalSince1970
        ]
    }

    private func handle(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)? = nil) {
        Task { @MainActor in
            if let amount = message["addTasks"] as? Int, amount == 1 || amount == 5 {
                _ = store.addTasks(amount)
            } else {
                store.reload()
            }

            let currentPayload = payload()
            replyHandler?(currentPayload)
            try? session?.updateApplicationContext(currentPayload)
            session?.transferUserInfo(currentPayload)
        }
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
