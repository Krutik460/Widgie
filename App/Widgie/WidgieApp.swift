import AppIntents
import SwiftUI
import WidgetEngine
import WidgetHosting

@main
struct WidgieApp: App {
    @Environment(\.scenePhase) private var phase
    @State private var library = Library()

    init() {
        Engine.removeLeftoverScratch()
    }

    var body: some Scene {
        WindowGroup {
            LibraryView(library: library)
                .onOpenURL { library.open($0) }
        }
        // iOS kills a suspended app that holds the shared database lock, so writes stop in the background.
        .onChange(of: phase) { _, phase in
            switch phase {
            case .background:
                Engine.suspend()
            case .active:
                Engine.resume()
                library.refresh()
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
