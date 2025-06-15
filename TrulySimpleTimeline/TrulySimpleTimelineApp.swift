import SwiftUI
import SwiftData

@main
struct TrulySimpleTimelineApp: App {
    @State private var purchaseManager = PurchaseManager()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Timeline.self,
            Event.self,
            Person.self,
            Location.self
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                // The task modifier belongs on a View, not a Scene.
                // Attaching it to our root view is the correct place.
                .task {
                    await purchaseManager.updatePurchasedStatus()
                }
        }
        .modelContainer(sharedModelContainer)
        .environment(purchaseManager)
    }
}
