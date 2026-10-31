import Foundation
import Observation
import WidgetKit
@preconcurrency import WatchConnectivity

@MainActor
@Observable
final class WatchTallyStore: NSObject, WCSessionDelegate {
    private struct Snapshot: Codable {
        var lifetimePointsHundredths: Int64
        var todayPointsHundredths: Int64
        var todayTasks: Int
        var level: Int
        var pointsWithinLevel: Int64
        var levelCost: Int64
        var combinedMultiplierHundredths: Int64
        var oneTaskRewardHundredths: Int64
        var fiveTaskRewardHundredths: Int64
        var latestEntryTimestamp: Date?
        var updatedAt: Date
        var isAuthoritative: Bool?
    }

    private static let storageKey = "LifeTally.watch.syncedSnapshot"
    private static let widgetKind = "Life_Tally_Widget"
    private static let timerWidgetKind = "Life_Tally_Timer_Widget"
    private static let widgetSuiteName = "group.devplaceholder.I1AQHERN.Life-Tally"

    private let session: WCSession?
    private(set) var lifetimePointsHundredths: Int64 = 0
    private(set) var todayPointsHundredths: Int64 = 0
    private(set) var todayTasks = 0
    private(set) var level = 1
    private(set) var pointsWithinLevel: Int64 = 0
    private(set) var levelCost: Int64 = 1_000_000
    private(set) var combinedMultiplierHundredths: Int64 = 100
    private(set) var oneTaskRewardHundredths: Int64 = 10_000
    private(set) var fiveTaskRewardHundredths: Int64 = 50_000
    private(set) var latestEntryTimestamp: Date?
    private(set) var lastUpdated: Date?
    private(set) var isReachable = false
    private(set) var isUpdating = false
    private(set) var hasAuthoritativeData = false

    override init() {
        session = WCSession.isSupported() ? .default : nil
        super.init()
        load()

        session?.delegate = self
        session?.activate()
    }

    var levelProgress: Double {
        let value = Double(pointsWithinLevel) / Double(max(1, levelCost))
        return min(max(value, 0), 1)
    }

    var lifetimeAmountText: String {
        Self.dollarText(lifetimePointsHundredths)
    }

    var todayAmountText: String {
        Self.dollarText(todayPointsHundredths)
    }

    var rateText: String {
        let rate = Decimal(combinedMultiplierHundredths) / 100
        return rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    var nextLevelText: String {
        Self.dollarText(max(0, levelCost - pointsWithinLevel))
    }

    var syncStatusText: String {
        if isUpdating { return "Updating…" }
        guard let lastUpdated else { return "Standalone • Sync pending" }
        guard isReachable else { return "Offline • Changes saved" }
        return "Updated \(lastUpdated.formatted(.relative(presentation: .named)))"
    }

    func rewardText(for amount: Int) -> String {
        switch amount {
        case 1:
            return Self.dollarText(oneTaskRewardHundredths)
        case 5:
            return Self.dollarText(fiveTaskRewardHundredths)
        default:
            return Self.dollarText(0)
        }
    }

    func requestSync() {
        guard let session, session.activationState == .activated else { return }
        isReachable = session.isReachable

        if !session.receivedApplicationContext.isEmpty {
            apply(session.receivedApplicationContext)
        }

        guard session.isReachable else {
            session.transferUserInfo(["request": "state"])
            return
        }
        isUpdating = true
        session.sendMessage(
            ["request": "state"],
            replyHandler: { [weak self] reply in
                Task { @MainActor in
                    self?.apply(reply)
                    self?.isUpdating = false
                }
            },
            errorHandler: { [weak self] _ in
                Task { @MainActor in
                    self?.isUpdating = false
                }
            }
        )
    }

    func addTasks(_ amount: Int) {
        guard amount == 1 || amount == 5 else { return }
        let message: [String: Any] = [
            "addTasks": amount,
            "commandID": UUID().uuidString
        ]

        if let session, session.activationState == .activated, session.isReachable {
            isUpdating = true
            session.sendMessage(
                message,
                replyHandler: { [weak self] reply in
                    Task { @MainActor in
                        self?.apply(reply)
                        self?.isUpdating = false
                    }
                },
                errorHandler: { [weak self] _ in
                    session.transferUserInfo(message)
                    Task { @MainActor in
                        self?.applyOptimisticAddition(amount)
                        self?.isUpdating = false
                    }
                }
            )
        } else if let session {
            if session.activationState == .activated {
                session.transferUserInfo(message)
            }
            applyOptimisticAddition(amount)
            isUpdating = false
        } else {
            applyOptimisticAddition(amount)
        }
    }

    private func applyOptimisticAddition(_ amount: Int) {
        let reward = amount == 1 ? oneTaskRewardHundredths : fiveTaskRewardHundredths
        todayTasks += amount
        todayPointsHundredths += reward
        lifetimePointsHundredths += reward
        pointsWithinLevel += reward
        while pointsWithinLevel >= levelCost {
            pointsWithinLevel -= levelCost
            level += 1
        }
        latestEntryTimestamp = .now
        lastUpdated = .now
        save()
    }

    private func apply(_ payload: [String: Any]) {
        guard let lifetime = Self.int64(payload["lifetimePointsHundredths"]) else { return }

        if
            let timestamp = payload["updatedAt"] as? TimeInterval,
            let lastUpdated,
            timestamp < lastUpdated.timeIntervalSince1970,
            hasAuthoritativeData
        {
            return
        }

        hasAuthoritativeData = true
        lifetimePointsHundredths = lifetime
        todayPointsHundredths = Self.int64(payload["todayPointsHundredths"]) ?? 0
        todayTasks = Self.int(payload["todayTasks"]) ?? 0
        level = Self.int(payload["level"]) ?? 1
        pointsWithinLevel = Self.int64(payload["pointsWithinLevel"]) ?? 0
        levelCost = Self.int64(payload["levelCost"]) ?? 1
        combinedMultiplierHundredths = Self.int64(payload["combinedMultiplierHundredths"]) ?? 100
        oneTaskRewardHundredths = Self.int64(payload["oneTaskRewardHundredths"]) ?? 10_000
        fiveTaskRewardHundredths = Self.int64(payload["fiveTaskRewardHundredths"]) ?? 50_000
        if let timestamp = payload["latestEntryTimestamp"] as? TimeInterval, timestamp > 0 {
            latestEntryTimestamp = Date(timeIntervalSince1970: timestamp)
        } else {
            latestEntryTimestamp = nil
        }

        if let timestamp = payload["updatedAt"] as? TimeInterval {
            lastUpdated = Date(timeIntervalSince1970: timestamp)
        } else {
            lastUpdated = .now
        }

        save()
    }

    private func load() {
        guard
            let data = UserDefaults.standard.data(forKey: Self.storageKey),
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else {
            return
        }

        lifetimePointsHundredths = snapshot.lifetimePointsHundredths
        todayPointsHundredths = snapshot.todayPointsHundredths
        todayTasks = snapshot.todayTasks
        level = snapshot.level
        pointsWithinLevel = snapshot.pointsWithinLevel
        levelCost = snapshot.levelCost
        combinedMultiplierHundredths = snapshot.combinedMultiplierHundredths
        oneTaskRewardHundredths = snapshot.oneTaskRewardHundredths
        fiveTaskRewardHundredths = snapshot.fiveTaskRewardHundredths
        latestEntryTimestamp = snapshot.latestEntryTimestamp
        lastUpdated = snapshot.updatedAt
        hasAuthoritativeData = snapshot.isAuthoritative ?? false
    }

    private func save() {
        let remainingPoints = max(0, levelCost - pointsWithinLevel)
        let tasksToNextLevel = oneTaskRewardHundredths > 0
            ? Int((remainingPoints + oneTaskRewardHundredths - 1) / oneTaskRewardHundredths)
            : 0
        let snapshot = Snapshot(
            lifetimePointsHundredths: lifetimePointsHundredths,
            todayPointsHundredths: todayPointsHundredths,
            todayTasks: todayTasks,
            level: level,
            pointsWithinLevel: pointsWithinLevel,
            levelCost: levelCost,
            combinedMultiplierHundredths: combinedMultiplierHundredths,
            oneTaskRewardHundredths: oneTaskRewardHundredths,
            fiveTaskRewardHundredths: fiveTaskRewardHundredths,
            latestEntryTimestamp: latestEntryTimestamp,
            updatedAt: lastUpdated ?? .now,
            isAuthoritative: hasAuthoritativeData
        )

        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)

        UserDefaults(suiteName: Self.widgetSuiteName)?.set([
            "lifetimePointsHundredths": lifetimePointsHundredths,
            "todayPointsHundredths": todayPointsHundredths,
            "todayTasks": todayTasks,
            "level": level,
            "pointsWithinLevel": pointsWithinLevel,
            "levelCost": levelCost,
            "tasksToNextLevel": tasksToNextLevel,
            "combinedMultiplierHundredths": combinedMultiplierHundredths,
            "latestEntryTimestamp": latestEntryTimestamp?.timeIntervalSince1970 ?? 0,
            "updatedAt": (lastUpdated ?? .now).timeIntervalSince1970
        ], forKey: Self.storageKey)
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
        WidgetCenter.shared.reloadTimelines(ofKind: Self.timerWidgetKind)
    }

    private static func dollarText(_ hundredths: Int64) -> String {
        let amount = Decimal(hundredths) / 100
        return amount.formatted(
            .currency(code: "USD")
                .precision(.fractionLength(2))
        )
    }

    private static func int64(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
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
            isReachable = session.isReachable
            requestSync()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            isReachable = session.isReachable
            if session.isReachable {
                requestSync()
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor in
            apply(applicationContext)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            apply(message)
            replyHandler([:])
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            apply(message)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            apply(userInfo)
        }
    }
}
