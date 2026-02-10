import SwiftUI
import CoreData
import MWDATCore   // ✅ Meta SDK

@main
struct GlassesOCRApp: App {
    let persistenceController = PersistenceController.shared

    init() {
        // Configure Meta Wearables SDK before any other SDK access
        do {
            try Wearables.configure()
            print("[GlassesOCRApp] ✅ Wearables SDK configured successfully")
        } catch {
            print("[GlassesOCRApp] ❌ Failed to configure Wearables SDK: \(error)")
            // The app will continue but glasses features won't work
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .onOpenURL { url in
                    // Handle callback from Meta AI app after registration approval
                    print("[GlassesOCRApp] 📲 Received callback URL: \(url)")
                    Task {
                        do {
                            let result = try await Wearables.shared.handleUrl(url)
                            print("[GlassesOCRApp] ✅ URL handled successfully: \(result)")
                        } catch {
                            print("[GlassesOCRApp] ❌ Failed to handle URL: \(error)")
                        }
                    }
                }
        }
    }
}
