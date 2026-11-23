import DeviceCheck
import Foundation
import WidgetBuilder

/// Which model service this build talks to, decided once.
///
/// - The simulator in a Debug build uses the dev bridge on the Mac (`WidgieModelBridge`, written by the Debug build
///   phase in project.yml), because the simulator has no App Attest.
/// - A phone uses the backend named by `WidgieModelService`, the dev Worker in Debug and production in Release,
///   with every request signed by App Attest.
/// - Anything else has no service, and Make says building is unavailable.
enum ModelService {
    static let configured: (any WidgetModel)? = {
        #if targetEnvironment(simulator)
            return bridge.map { BridgeModel(base: $0) }
        #else
            guard let service, DCAppAttestService.shared.isSupported else { return nil }
            return AttestedModel(base: service, account: service.host() ?? service.absoluteString)
        #endif
    }()

    /// The endpoint the Debug hint under a failure names.
    static var endpoint: String? {
        #if targetEnvironment(simulator)
            return bridge.map { "the bridge at \($0.host() ?? ""):\($0.port ?? 80)" }
        #else
            return service?.host()
        #endif
    }

    private static let bridge = url(for: "WidgieModelBridge")
    private static let service = url(for: "WidgieModelService")

    private static func url(for key: String) -> URL? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap(URL.init(string:))
    }
}
