import AppIntents
import SwiftUI
import WidgetEngine
import WidgetHosting

@main
struct WidgieApp: App {
    @Environment(\.scenePhase) private var phase
    @State private var library: Library
    /// Nil when the app hosts its unit tests (`AccountSync.hostedByTests`).
    @State private var account: AccountSync?

    init() {
        Engine.removeLeftoverScratch()
        let library = Library()
        _library = State(initialValue: library)
        _account = State(
            initialValue: AccountSync.hostedByTests() ? nil : AccountSync(pulled: { library.refresh() }))
    }

    var body: some Scene {
        WindowGroup {
            RootView(library: library)
        }
        // iOS kills a suspended app that holds the shared database lock, so writes stop in the background.
        .onChange(of: phase) { _, phase in
            switch phase {
            case .background:
                account?.background()
                SharedWrites.suspend()
            case .active:
                SharedWrites.resume()
                library.refresh()
                account?.foreground()
            default:
                break
            }
        }
    }
}

/// Lets App Intents find `RunAction` and `PickWidget`, which live in the package.
struct WidgieIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [HostingIntents.self] }
}
