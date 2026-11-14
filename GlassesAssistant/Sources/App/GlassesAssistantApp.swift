import MWDATCore
import SwiftUI

@main
struct GlassesAssistantApp: App {
    @State private var model: AppModel?
    private let startupError: String?

    init() {
        // Unit tests use this app as their host; they don't need (or have) the glasses SDK.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            _model = State(initialValue: nil)
            startupError = nil
            return
        }
        // Must run once, before anything touches `Wearables.shared`.
        do {
            try Wearables.configure()
            _model = State(initialValue: AppModel())
            startupError = nil
        } catch {
            _model = State(initialValue: nil)
            startupError = "The Meta Wearables SDK couldn't start (\(error)). Check the MWDAT keys in Info.plist and that the Meta AI app is installed."
        }
    }

    var body: some Scene {
        WindowGroup {
            if let model {
                ContentView()
                    .environment(model)
                    .onOpenURL { url in model.glasses.handleCallbackURL(url) }
            } else if let startupError {
                ContentUnavailableView(
                    "Glasses SDK unavailable",
                    systemImage: "eyeglasses",
                    description: Text(startupError)
                )
            } else {
                Text("Running tests")
            }
        }
    }
}
