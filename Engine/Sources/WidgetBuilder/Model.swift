import Foundation
import WidgetEngine

/// What the app asks the model service for. Semantic on purpose: the service owns the system prompt and the
/// message wording, so a prompt change never needs an app release. Encoded as JSON, it is the body the dev
/// bridge (`Engine/Evals/bridge.py`) and the real backend both accept.
public struct ModelRequest: Codable, Sendable, Equatable {
    /// The person's latest message.
    public var words: String
    /// A picture the person attached with this message.
    public var image: Attachment?
    /// The document being refined, nil for a new widget.
    public var current: String?
    /// Set only on a repair.
    public var repair: Repair?

    public init(words: String, image: Attachment? = nil, current: String? = nil, repair: Repair? = nil) {
        self.words = words
        self.image = image
        self.current = current
        self.repair = repair
    }
}

/// A picture as the person attached it. On the wire its bytes travel as base64 under `base64`.
public struct Attachment: Codable, Sendable, Equatable {
    public var mime: String
    public var bytes: Data

    public init(mime: String, bytes: Data) {
        self.mime = mime
        self.bytes = bytes
    }

    enum CodingKeys: String, CodingKey {
        case mime
        case bytes = "base64"
    }
}

/// A rejected document and the line `build` rejected it with.
public struct Repair: Codable, Sendable, Equatable {
    public var document: String
    public var line: String

    public init(document: String, line: String) {
        self.document = document
        self.line = line
    }
}

/// The model service. The app's conformance posts to the dev bridge or the backend; tests script one.
public protocol WidgetModel: Sendable {
    /// The model's raw reply text. Throws only when the service could not answer, never for a bad document.
    func reply(to request: ModelRequest) async throws -> String
}

/// The dev bridge on the Mac (`Engine/Evals/bridge.py`): `POST <base>/v1/reply` with a `ModelRequest`, then
/// `{"reply": text}` back, or `{"error": line}` with a status other than 200.
public struct BridgeModel: WidgetModel {
    /// The bridge answered without a reply: an HTTP error such as 400, 413, or 502, or a body with no reply.
    /// A bridge that cannot be reached throws `URLError` instead.
    public struct Refused: Error, CustomStringConvertible {
        public let description: String
    }

    public let base: URL
    /// Sent as `Authorization: Bearer <token>`. Only the Mac's `render-tool loop` sets it, to reach the dev Worker
    /// while its operator gate stands (phase 2b, B1). B2 removes the gate and this property.
    public let token: String?

    public init(base: URL, token: String? = nil) {
        self.base = base
        self.token = token
    }

    public func reply(to request: ModelRequest) async throws -> String {
        // Longer than bridge.py's 110 s model timeout, so a slow model comes back as the bridge's error line
        // instead of a request timeout.
        var post = URLRequest(url: base.appending(path: "v1/reply"), timeoutInterval: 120)
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { post.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        post.httpBody = try JSONEncoder().encode(request)
        let (data, response) = try await URLSession.shared.data(for: post)
        let body = try? JSONDecoder().decode(Body.self, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let reply = body?.reply else {
            throw Refused(description: "HTTP \(status): \(body?.error ?? "no reply")")
        }
        return reply
    }

    private struct Body: Decodable {
        let reply: String?
        let error: String?
    }
}

/// Where `Engine.build(_:image:replacing:repairing:model:isolation:progress:)` is, for a progress line.
public enum BuildStep: Sendable, Equatable {
    /// Waiting on the model for a new document.
    case writing(attempt: Int)
    /// Proving the model's reply.
    case checking(attempt: Int)
    /// Waiting on the model to fix a document `build` rejected with this line.
    case repairing(attempt: Int, line: String)
}

public enum LoopOutcome: Sendable, Equatable {
    /// The widget `build` saved, in the engine the loop ran on.
    case accepted(WidgetID, attempts: Int)
    /// Every attempt was rejected. Nothing was saved.
    case gaveUp(lastLine: String, attempts: Int)
}
