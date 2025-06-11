import SwiftUI
import SwiftData

@main
struct TrulySimpleTimelineApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // This line creates the database and prepares it for our Event model.
        .modelContainer(for: Event.self)
    }
}
