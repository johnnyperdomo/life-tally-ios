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
        var isStopwatchPaused: Bool?
        var stopwatchPausedElapsed: TimeInterval?
        var updatedAt: Date
        var isAuthoritative: Bool?
        var syncState: WatchSyncState?
    }

    private static let storageKey = "LifeTally.watch.syncedSnapshot"
    private static let economyVersion = 3
    private static let economyVersionKey = "LifeTally.watch.economyVersion"
    private static let widgetSuiteName = "group.com.flytebuddyllc.lifetally"

    private let session: WCSession?
    private var syncState = WatchSyncState()
    private(set) var lifetimePointsHundredths: Int64 = 0
    private(set) var todayPointsHundredths: Int64 = 0
    private(set) var todayTasks = 0
    private(set) var level = 1
    private(set) var pointsWithinLevel: Int64 = 0
    private(set) var levelCost: Int64 = 150_000
    private(set) var combinedMultiplierHundredths: Int64 = 100
    private(set) var oneTaskRewardHundredths: Int64 = 10_000
    private(set) var fiveTaskRewardHundredths: Int64 = 50_500
    private(set) var latestEntryTimestamp: Date?
    private(set) var isStopwatchPaused = false
    private(set) var stopwatchPausedElapsed: TimeInterval = 0
    private(set) var lastUpdated: Date?
    private(set) var isReachable = false
    private(set) var isUpdating = false
    private(set) var hasAuthoritativeData = false

    override init() {
        session = WCSession.isSupported() ? .default : nil
        super.init()
        migrateEconomyIfNeeded()
        load()
        // Restore the shared widget cache even when the phone is offline.
        if lastUpdated != nil {
            save()
        }

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
        // Republish known data when returning from the widget, even while offline.
        if lastUpdated != nil {
            save()
        }
        guard let session, session.activationState == .activated else { return }
        isReachable = session.isReachable
        for (commandID, amount) in syncState.pendingCommands {
            sendCommand(["addTasks": amount, "commandID": commandID], using: session)
        }

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
        let commandID = UUID().uuidString
        syncState.pendingCommands[commandID] = amount
        let message: [String: Any] = [
            "addTasks": amount,
            "commandID": commandID
        ]

        // Update the Watch UI and widget snapshot immediately. The phone reply
        // reconciles this optimistic state with the authoritative data.
        applyOptimisticAddition(amount)

        guard let session, session.activationState == .activated else { return }
        sendCommand(message, using: session)
    }

    func setStopwatchPaused(_ paused: Bool) {
        guard latestEntryTimestamp != nil, isStopwatchPaused != paused else { return }
        let actionDate = Date.now
        if paused, let latestEntryTimestamp {
            stopwatchPausedElapsed = max(0, actionDate.timeIntervalSince(latestEntryTimestamp))
        } else {
            latestEntryTimestamp = actionDate.addingTimeInterval(-stopwatchPausedElapsed)
        }
        isStopwatchPaused = paused
        save()

        guard let session, session.activationState == .activated else { return }
        sendCommand(
            [
                "setStopwatchPaused": paused,
                "stopwatchElapsed": stopwatchPausedElapsed,
                "stopwatchActionTimestamp": actionDate.timeIntervalSince1970
            ],
            using: session
        )
    }

    private func sendCommand(_ message: [String: Any], using session: WCSession) {
        let commandID = message["commandID"] as? String
        if session.isReachable {
            isUpdating = true
            session.sendMessage(
                message,
                replyHandler: { [weak self] reply in
                    Task { @MainActor in
                        self?.apply(reply, acknowledging: commandID)
                        self?.isUpdating = false
                    }
                },
                errorHandler: { [weak self] _ in
                    session.transferUserInfo(message)
                    Task { @MainActor in
                        self?.isUpdating = false
                    }
                }
            )
        } else {
            if session.activationState == .activated {
                session.transferUserInfo(message)
            }
            isUpdating = false
        }
    }

    private func applyOptimisticAddition(_ amount: Int) {
        let reward = amount == 1 ? oneTaskRewardHundredths : fiveTaskRewardHundredths
        todayTasks += amount
        todayPointsHundredths += reward
        lifetimePointsHundredths += reward
        for offset in 0..<amount {
            let taskReward = Self.increasedReward(oneTaskRewardHundredths, by: offset)
            pointsWithinLevel += Self.boundedLevelProgress(
                reward: taskReward,
                levelCost: levelCost
            )
            if pointsWithinLevel >= levelCost {
                pointsWithinLevel -= levelCost
                level += 1
                levelCost = Self.lockedLevelCost(
                    nextReward: Self.increasedReward(taskReward, by: 1)
                )
            }
        }
        oneTaskRewardHundredths = Self.increasedReward(oneTaskRewardHundredths, by: amount)
        fiveTaskRewardHundredths = Self.fiveTaskReward(startingAt: oneTaskRewardHundredths)
        combinedMultiplierHundredths = Self.increasedReward(combinedMultiplierHundredths, by: amount)
        latestEntryTimestamp = .now
        isStopwatchPaused = false
        stopwatchPausedElapsed = 0
        lastUpdated = .now
        hasAuthoritativeData = true
        save()
    }

    private func apply(_ payload: [String: Any], acknowledging commandID: String? = nil) {
        guard let lifetime = Self.int64(payload["lifetimePointsHundredths"]) else { return }

        // A phone snapshot must include all local taps before replacing the
        // optimistic total. Compare phone timestamps only with other phone timestamps.
        guard syncState.accept(
            updatedAt: (payload["updatedAt"] as? NSNumber)?.doubleValue,
            acknowledgedCommandIDs: (payload["processedCommandIDs"] as? [String] ?? [])
                + (commandID.map { [$0] } ?? [])
        ) else {
            save()
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
        fiveTaskRewardHundredths = Self.int64(payload["fiveTaskRewardHundredths"]) ?? 50_500
        if let timestamp = payload["latestEntryTimestamp"] as? TimeInterval, timestamp > 0 {
            latestEntryTimestamp = Date(timeIntervalSince1970: timestamp)
        } else {
            latestEntryTimestamp = nil
        }
        isStopwatchPaused = Self.bool(payload["isStopwatchPaused"]) ?? false
        stopwatchPausedElapsed = (payload["stopwatchPausedElapsed"] as? NSNumber)?.doubleValue ?? 0

        if let timestamp = payload["updatedAt"] as? TimeInterval {
            lastUpdated = Date(timeIntervalSince1970: timestamp)
        } else {
            lastUpdated = .now
        }

        save()
    }

    private func migrateEconomyIfNeeded() {
        guard UserDefaults.standard.integer(forKey: Self.economyVersionKey) < Self.economyVersion else {
            return
        }

        UserDefaults.standard.removeObject(forKey: Self.storageKey)
        UserDefaults(suiteName: Self.widgetSuiteName)?.removeObject(forKey: Self.storageKey)
        UserDefaults.standard.set(Self.economyVersion, forKey: Self.economyVersionKey)
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
        isStopwatchPaused = snapshot.isStopwatchPaused ?? false
        stopwatchPausedElapsed = snapshot.stopwatchPausedElapsed ?? 0
        lastUpdated = snapshot.updatedAt
        hasAuthoritativeData = snapshot.isAuthoritative ?? false
        syncState = snapshot.syncState ?? WatchSyncState()
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
            isStopwatchPaused: isStopwatchPaused,
            stopwatchPausedElapsed: stopwatchPausedElapsed,
            updatedAt: lastUpdated ?? .now,
            isAuthoritative: hasAuthoritativeData,
            syncState: syncState
        )

        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)

        if let widgetDefaults = UserDefaults(suiteName: Self.widgetSuiteName) {
            let values: [String: Any] = [
                "lifetimePointsHundredths": lifetimePointsHundredths,
                "todayPointsHundredths": todayPointsHundredths,
                "todayTasks": todayTasks,
                "level": level,
                "pointsWithinLevel": pointsWithinLevel,
                "levelCost": levelCost,
                "tasksToNextLevel": tasksToNextLevel,
                "combinedMultiplierHundredths": combinedMultiplierHundredths,
                "oneTaskRewardHundredths": oneTaskRewardHundredths,
                "latestEntryTimestamp": latestEntryTimestamp?.timeIntervalSince1970 ?? 0,
                "isStopwatchPaused": isStopwatchPaused,
                "stopwatchPausedElapsed": stopwatchPausedElapsed,
                "updatedAt": (lastUpdated ?? .now).timeIntervalSince1970
            ]
            var previous = widgetDefaults.dictionary(forKey: Self.storageKey) ?? [:]
            var visibleValues = values
            previous.removeValue(forKey: "updatedAt")
            visibleValues.removeValue(forKey: "updatedAt")
            guard !NSDictionary(dictionary: previous).isEqual(to: visibleValues) else { return }
            widgetDefaults.set(values, forKey: Self.storageKey)
            widgetDefaults.synchronize()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private static func increasedReward(_ reward: Int64, by tasks: Int) -> Int64 {
        Int64((Double(reward) * pow(1.005, Double(max(0, tasks)))).rounded())
    }

    private static func fiveTaskReward(startingAt reward: Int64) -> Int64 {
        (0..<5).reduce(Int64(0)) { total, offset in
            total + increasedReward(reward, by: offset)
        }
    }

    private static func lockedLevelCost(nextReward: Int64) -> Int64 {
        max(1, nextReward) * 12
    }

    private static func boundedLevelProgress(reward: Int64, levelCost: Int64) -> Int64 {
        let cost = max(1, levelCost)
        let minimumProgress = (cost + 14) / 15
        let maximumProgress = max(1, cost / 10)
        return min(max(reward, minimumProgress), maximumProgress)
    }

    private static func levelCost(for level: Int) -> Int64 {
        var cost: Int64 = 150_000
        if level > 1 {
            for _ in 1..<level {
                cost = cost * 106 / 100
            }
        }
        return cost * (10_000 + Int64(max(0, level - 1)) * 960) / 10_000
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

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        return (value as? NSNumber)?.boolValue
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

/// Tracks local taps until the phone confirms that its snapshot includes them.
struct WatchSyncState: Codable {
    var pendingCommands: [String: Int] = [:]
    var lastPhoneUpdate: TimeInterval?

    mutating func accept(updatedAt: TimeInterval?, acknowledgedCommandIDs: [String]) -> Bool {
        if let lastPhoneUpdate {
            guard let updatedAt, updatedAt >= lastPhoneUpdate else { return false }
        }

        lastPhoneUpdate = updatedAt
        for commandID in acknowledgedCommandIDs {
            pendingCommands.removeValue(forKey: commandID)
        }
        return pendingCommands.isEmpty
    }
}
