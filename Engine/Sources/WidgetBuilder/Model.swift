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
