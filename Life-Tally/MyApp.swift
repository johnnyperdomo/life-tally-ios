import SwiftData
import SwiftUI

@main
struct LifeTallyApp: App {
    private let container: ModelContainer
    private let store: LifeTallyStore
    private let watchSync: PhoneWatchSyncCoordinator

    init() {
        do {
            let schema = Schema([
                TallyEntry.self,
                DailyState.self,
                AppProfile.self,
                TrackedHabit.self,
                HabitCompletion.self
            ])
            let configuration = ModelConfiguration(
                "LifeTally",
                schema: schema,
                cloudKitDatabase: .automatic
            )
            container = try ModelContainer(for: schema, configurations: configuration)
        } catch {
            fatalError("Life Tally could not open its existing data store: \(error.localizedDescription)")
        }
        let store = LifeTallyStore(context: container.mainContext)
        self.store = store
        watchSync = PhoneWatchSyncCoordinator(store: store)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .modelContainer(container)
                .task { watchSync.sendCurrentState() }
        }
    }
}
