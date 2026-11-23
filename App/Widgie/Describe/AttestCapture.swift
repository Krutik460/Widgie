#if DEBUG
    import Foundation
    import OSLog
    import Synchronization
    import WidgetBuilder

    private let log = Logger(subsystem: "dev.krutikpatel.widgie", category: "model")

    /// Debug only: attests a fresh key against the dev Worker and sends two signed requests, then writes
    /// `Documents/attest-capture.json` in the shape `Backend/test/fixtures.test.ts` reads. Copy it off with
    /// `xcrun devicectl device copy from --device <id> --domain-type appDataContainer
    /// --domain-identifier dev.krutikpatel.widgie --source Documents/attest-capture.json --destination <file>`.
    enum AttestCapture {
        private struct Request: Encodable {
            let method = "POST"
            let path = "/v1/reply"
            var body = ""
            var assertion = ""
        }

        private struct Capture: Encodable {
            let environment = "development"
            let appId = "Z23KXVBB26.dev.krutikpatel.widgie"
            let capturedAt: String
            var keyId = ""
            var challenge = ""
            var attestation = ""
            var requests: [Request] = []
        }

        static func run() async {
            guard let service = Bundle.main.object(forInfoDictionaryKey: "WidgieModelService") as? String,
                let base = URL(string: service)
            else { return log.error("capture: no WidgieModelService") }
            let capture = Mutex(Capture(capturedAt: ISO8601DateFormatter().string(from: .now)))
            let record: @Sendable (String, Data) -> Void = { name, data in
                capture.withLock { capture in
                    switch name {
                    case "key-id": capture.keyId = String(decoding: data, as: UTF8.self)
                    case "challenge": capture.challenge = String(decoding: data, as: UTF8.self)
                    case "attestation": capture.attestation = data.base64EncodedString()
                    case "request.body": capture.requests.append(Request(body: data.base64EncodedString()))
                    case "request.assertion":
                        capture.requests[capture.requests.count - 1].assertion = String(decoding: data, as: UTF8.self)
                    default: break
                    }
                }
            }
            // A fresh account, so the capture always attests a new key and never disturbs the app's own.
            let model = AttestedModel(base: base, account: "capture-\(UUID().uuidString)", record: record)
            for words in ["a tally counter with a plus button", "make it green"] {
                do {
                    _ = try await model.reply(to: ModelRequest(words: words))
                } catch {
                    return log.error("capture failed: \(String(describing: error), privacy: .public)")
                }
            }
            let file = URL.documentsDirectory.appending(path: "attest-capture.json")
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(capture.withLock { $0 }).write(to: file)
                log.info("capture: written to \(file.path(), privacy: .public)")
            } catch {
                log.error("capture: could not write \(file.path(), privacy: .public): \(error, privacy: .public)")
            }
        }
    }
#endif
