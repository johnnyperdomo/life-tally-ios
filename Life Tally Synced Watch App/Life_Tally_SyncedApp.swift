import SwiftUI

@main
struct Life_Tally_Watch_AppApp: App {
    @State private var store = WatchTallyStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
    }
}
