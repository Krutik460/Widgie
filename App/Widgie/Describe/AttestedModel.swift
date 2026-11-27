import CryptoKit
import DeviceCheck
import Foundation
import OSLog
import Security
import WidgetBuilder

private let log = Logger(subsystem: "dev.krutikpatel.widgie", category: "model")

/// The backend's model service, `POST <base>/v1/reply`, with each request signed by this install's App Attest key.
/// The wire protocol is "B2 wire protocol" in tasks/phase-2b-backend.md; the Worker in Backend/ checks the same bytes.
///
/// One key per environment. The first call creates and attests it, and every call after signs with it. A key
/// the phone no longer holds (`DCError.invalidKey`, after a restore or on a pending key) or the server no longer
/// knows (`unknown-key`) is replaced once per call. A request the server calls `bad-assertion` fails without
/// touching the key. As Apple's guidance says, a key that failed attestation is kept only when Apple's service was
/// unavailable; any other failure discards it, and the next attempt makes a new one.
actor AttestedModel: WidgetModel {
    /// The service answered with an error. `code` is the Worker's, such as `bad-assertion`, when it sent one.
    struct Refused: Error, CustomStringConvertible {
        let status: Int
        let code: String?
        let line: String
        var description: String { "HTTP \(status) \(code ?? "-"): \(line)" }
    }

    /// The service or Apple's attestation service could not be reached. The build can be tried again.
    struct Unreachable: Error, CustomStringConvertible {
        let description: String
    }

    let base: URL
    private let account: String
    private let store: any KeyStore
    private let attestor: any Attestor
    private let transport: any Transport
    private let record: (@Sendable (String, Data) -> Void)?
    /// The attestation in flight, so two calls never attest twice.
    private var attesting: Task<String, any Error>?
    /// The last signed call, so the next one waits for it: assertions must reach the server in counter order.
    private var tail: Task<Void, Never>?

    /// `account` names the key in the store; use one per environment. `record` receives each byte string a Debug
    /// capture writes as a test fixture.
    init(
        base: URL, account: String, store: any KeyStore = KeychainStore(), attestor: any Attestor = AppAttestor(),
        transport: any Transport = URLSessionTransport(), record: (@Sendable (String, Data) -> Void)? = nil
    ) {
        self.base = base
        self.account = account
        self.store = store
        self.attestor = attestor
        self.transport = transport
        self.record = record
    }

    func reply(to request: ModelRequest) async throws -> String {
        let body = try JSONEncoder().encode(request)
        let previous = tail
        let call = Task { () throws -> String in
            await previous?.value
            return try await signedReply(body: body)
        }
        tail = Task { _ = try? await call.value }
        // A cancelled build cancels its call, as URLSession does for the bridge.
        return try await withTaskCancellationHandler {
            try await call.value
        } onCancel: {
            call.cancel()
        }
    }

    private func signedReply(body: Data) async throws -> String {
        var replaced = false
        while true {
            let keyId: String
            do {
                keyId = try await attestedKey()
            } catch let error as Refused where error.code == Self.invalidKey && !replaced {
                log.info("App Attest no longer holds the pending key; attesting a new one")
                replaced = true
                continue
            }
            let assertion: Data
            do {
                assertion = try await attestor.generateAssertion(keyId, clientDataHash: Self.clientDataHash(body: body))
            } catch let error as DCError where error.code == .invalidKey && !replaced {
                log.info("the phone no longer holds the key; attesting a new one")
                store.delete(account)
                replaced = true
                continue
            }
            var post = URLRequest(url: base.appending(path: "v1/reply"), timeoutInterval: 120)
            post.httpMethod = "POST"
            post.setValue("application/json", forHTTPHeaderField: "Content-Type")
            post.setValue(keyId, forHTTPHeaderField: "X-Widgie-Key")
            post.setValue(assertion.base64EncodedString(), forHTTPHeaderField: "X-Widgie-Assertion")
            post.httpBody = body
            record?("request.body", body)
            record?("request.assertion", Data(assertion.base64EncodedString().utf8))
            let (data, response) = try await send(post)
            if response.statusCode == 200, let answer = try? JSONDecoder().decode(Answer.self, from: data) {
                log.info(
                    "model \(answer.model ?? "-", privacy: .public) in \(answer.seconds ?? 0, privacy: .public) s, \(answer.usage?.summary ?? "no usage", privacy: .public)"
                )
                return answer.reply
            }
            let refused = Self.refusal(data, status: response.statusCode)
            if refused.code == "unknown-key" && !replaced {
                log.info("the server does not know the key; attesting a new one")
                store.delete(account)
                replaced = true
                continue
            }
            throw refused
        }
    }

    /// This environment's attested key id, attesting one first when there is none.
    private func attestedKey() async throws -> String {
        if let saved = store.load(account), saved.attested { return saved.keyId }
        if let attesting { return try await attesting.value }
        let task = Task { try await attest() }
        attesting = task
        defer { attesting = nil }
        return try await task.value
    }

    /// The code `attest` throws when App Attest refuses the key itself, after discarding it.
    private static let invalidKey = "invalid-key"

    /// Attests the pending key, kept only when Apple's service was unavailable for it, or else a new one. From
    /// `attestKey` on, any failure but `serverUnavailable` discards the key, so the next attempt makes a new one.
    private func attest() async throws -> String {
        let keyId: String
        if let pending = store.load(account) {
            keyId = pending.keyId
        } else {
            keyId = try await attestor.generateKey()
            store.save(StoredKey(keyId: keyId, attested: false), account)
        }
        let (challengeData, challengeResponse) = try await send(
            post("v1/attest/challenge", json: ["keyId": keyId], timeout: 30))
        if challengeResponse.statusCode == 409 {
            store.save(StoredKey(keyId: keyId, attested: true), account)
            return keyId
        }
        guard challengeResponse.statusCode == 200,
            let challenge = (try? JSONDecoder().decode([String: String].self, from: challengeData))?["challenge"]
        else { throw Self.refusal(challengeData, status: challengeResponse.statusCode) }

        let attestation: Data
        do {
            attestation = try await attestor.attestKey(
                keyId, clientDataHash: Data(SHA256.hash(data: Data(challenge.utf8))))
        } catch let error as DCError where error.code == .serverUnavailable {
            throw Unreachable(description: "Apple's attestation service is unavailable; the key is kept for later")
        } catch let error as DCError where error.code == .invalidKey {
            store.delete(account)
            throw Refused(status: 0, code: Self.invalidKey, line: "App Attest does not hold this key")
        } catch {
            store.delete(account)
            throw error
        }
        record?("key-id", Data(keyId.utf8))
        record?("challenge", Data(challenge.utf8))
        record?("attestation", attestation)

        do {
            let (data, response) = try await send(
                post(
                    "v1/attest",
                    json: ["keyId": keyId, "challenge": challenge, "attestation": attestation.base64EncodedString()],
                    timeout: 30))
            guard response.statusCode == 204 || response.statusCode == 409 else {
                throw Self.refusal(data, status: response.statusCode)
            }
        } catch {
            // The server did not take the attestation, such as `bad-attestation`, and Apple attested this key
            // already, so it is not attested again.
            store.delete(account)
            throw error
        }
        store.save(StoredKey(keyId: keyId, attested: true), account)
        log.info("attested a new key")
        return keyId
    }

    private func post(_ path: String, json: [String: String], timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: base.appending(path: path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(json)
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch let error as URLError {
            throw Unreachable(description: error.localizedDescription)
        }
    }

    /// `SHA256` of the client data `POST\n/v1/reply\n<lowercase hex SHA256 of the body>`.
    static func clientDataHash(body: Data, method: String = "POST", path: String = "/v1/reply") -> Data {
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return Data(SHA256.hash(data: Data("\(method)\n\(path)\n\(digest)".utf8)))
    }

    private static func refusal(_ data: Data, status: Int) -> Refused {
        let body = try? JSONDecoder().decode([String: String].self, from: data)
        return Refused(status: status, code: body?["code"], line: body?["error"] ?? "no reply")
    }

    private struct Answer: Decodable {
        let reply: String
        let seconds: Double?
        let model: String?
        let usage: Usage?
    }

    private struct Usage: Decodable {
        let inputTokens: Int?
        let cachedTokens: Int?
        let outputTokens: Int?
        let costUSD: Double?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case cachedTokens = "cached_tokens"
            case outputTokens = "output_tokens"
            case costUSD = "cost_usd"
        }

        var summary: String {
            "in \(inputTokens ?? 0), cached \(cachedTokens ?? 0), out \(outputTokens ?? 0), cost \(costUSD.map { String($0) } ?? "-")"
        }
    }
}

/// A key id and whether the server holds its attestation.
struct StoredKey: Codable, Equatable, Sendable {
    let keyId: String
    let attested: Bool
}

protocol KeyStore: Sendable {
    func load(_ account: String) -> StoredKey?
    func save(_ key: StoredKey, _ account: String)
    func delete(_ account: String)
}

protocol Attestor: Sendable {
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The key id in the Keychain, on this device only, so a restore to another phone never carries a key it lacks.
struct KeychainStore: KeyStore {
    private let service = "dev.krutikpatel.widgie.attest"

    func load(_ account: String) -> StoredKey? {
        var query = base(account)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(StoredKey.self, from: data)
    }

    func save(_ key: StoredKey, _ account: String) {
        delete(account)
        var item = base(account)
        item[kSecValueData as String] = try? JSONEncoder().encode(key)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { log.error("the key id could not be saved: \(status, privacy: .public)") }
    }

    func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }

    private func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

struct AppAttestor: Attestor {
    func generateKey() async throws -> String { try await DCAppAttestService.shared.generateKey() }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash)
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash)
    }
}

struct URLSessionTransport: Transport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
