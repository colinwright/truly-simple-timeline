import SwiftUI
import SwiftData

@main
struct TrulySimpleTimelineApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Timeline.self, Event.self, Person.self, Location.self])
    }
}
