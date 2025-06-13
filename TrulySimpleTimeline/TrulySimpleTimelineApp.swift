import SwiftUI
import SwiftData

@main
struct TrulySimpleTimelineApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Event.self, Character.self])
    }
}
