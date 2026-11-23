#if DEBUG
    import Foundation
    import OSLog
    import Synchronization
    import WidgetBuilder

    private let log = Logger(subsystem: "dev.krutikpatel.widgie", category: "model")

    /// Debug only: attests a fresh key against the dev Worker and sends two signed requests, writing every byte
    /// string to `Documents/attest-capture/` as the Worker's verifier fixtures. Copy them off with
    /// `xcrun devicectl device copy from --device <id> --domain-type appDataContainer
    /// --domain-identifier dev.krutikpatel.widgie --source Documents/attest-capture --destination <dir>`.
    enum AttestCapture {
        static func run() async {
            guard let service = Bundle.main.object(forInfoDictionaryKey: "WidgieModelService") as? String,
                let base = URL(string: service)
            else { return log.error("capture: no WidgieModelService") }
            let folder = URL.documentsDirectory.appending(path: "attest-capture")
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let count = Mutex(0)
            let write: @Sendable (String, Data) -> Void = { name, data in
                let index = count.withLock { value -> Int in
                    value += 1
                    return value
                }
                try? data.write(to: folder.appending(path: String(format: "%02d-%@", index, name)))
            }
            write("captured-at", Data(ISO8601DateFormatter().string(from: .now).utf8))
            // A fresh account, so the capture always attests a new key and never disturbs the app's own.
            let model = AttestedModel(base: base, account: "capture-\(UUID().uuidString)", record: write)
            for words in ["a tally counter with a plus button", "make it green"] {
                do {
                    _ = try await model.reply(to: ModelRequest(words: words))
                    log.info("capture: signed request answered")
                } catch {
                    log.error("capture failed: \(String(describing: error), privacy: .public)")
                    return
                }
            }
            log.info("capture: written to \(folder.path(), privacy: .public)")
        }
    }
#endif
