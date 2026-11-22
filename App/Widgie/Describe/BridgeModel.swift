import Foundation
import WidgetBuilder

extension BridgeModel {
    /// The bridge this build names in the Debug-only `WidgieModelBridge` Info.plist key, or nil in a build
    /// without one.
    static let configured: BridgeModel? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "WidgieModelBridge") as? String,
            let base = URL(string: value)
        else { return nil }
        return BridgeModel(base: base)
    }()
}
