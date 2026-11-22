import Foundation
import WidgetBuilder

/// The model service in a Debug build: the dev bridge on the Mac (`Engine/Evals/bridge.py`), at the URL in
/// the Debug-only `WidgieModelBridge` Info.plist key.
struct BridgeModel: WidgetModel {
    /// The bridge answered without a reply: an HTTP error such as 400, 413, or 502, or a body with no reply.
    /// A bridge that cannot be reached throws `URLError` instead.
    struct Refused: Error, CustomStringConvertible {
        let detail: String
        var description: String { detail }
    }

    let base: URL

    /// The bridge this build names, or nil in a build without one.
    static let configured: BridgeModel? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "WidgieModelBridge") as? String,
            let base = URL(string: value)
        else { return nil }
        return BridgeModel(base: base)
    }()

    func reply(to request: ModelRequest) async throws -> String {
        var post = URLRequest(url: base.appending(path: "v1/reply"), timeoutInterval: 120)
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.httpBody = try JSONEncoder().encode(request)
        let (data, response) = try await URLSession.shared.data(for: post)
        struct Answer: Decodable {
            let reply: String?
            let error: String?
        }
        let answer = try? JSONDecoder().decode(Answer.self, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let reply = answer?.reply else {
            throw Refused(detail: "HTTP \(status): \(answer?.error ?? "no reply")")
        }
        return reply
    }
}
