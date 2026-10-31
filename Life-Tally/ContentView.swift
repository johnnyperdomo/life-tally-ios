import SwiftUI

struct ContentView: View {
    let store: LifeTallyStore

    var body: some View {
        RootView(store: store)
    }
}
