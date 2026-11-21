import AppIntents
import SwiftUI
import WidgetHosting

@main
struct WidgieWidgets: WidgetBundle {
    var body: some Widget {
        CreationWidget()
    }
}

/// Lets App Intents find `RunAction` and `PickWidget`, which live in the package.
struct WidgieWidgetsIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [HostingIntents.self] }
}
