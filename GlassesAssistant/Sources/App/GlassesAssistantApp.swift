import MWDATCore
import SwiftUI

@main
struct GlassesAssistantApp: App {
    @State private var model: AppModel

    init() {
        // Must run once, before anything touches `Wearables.shared`.
        do {
            try Wearables.configure()
        } catch {
            assertionFailure("Failed to configure the Wearables SDK: \(error)")
        }
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .onOpenURL { url in model.glasses.handleCallbackURL(url) }
        }
    }
}
