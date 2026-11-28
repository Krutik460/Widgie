import CryptoKit
import DeviceCheck
import Foundation
import Synchronization
import Testing
import WidgetBuilder
import WidgetHosting

@testable import Widgie

/// `AttestedModel` against an in-memory key store, a scripted attestor, and a scripted service, so no test touches
/// the Keychain, App Attest, or the network.
@Suite struct AttestedModelTests {
    let base = URL(string: "https://worker.test")!
    let request = ModelRequest(words: "a tap counter")

    @Test func theFirstCallAttestsAKeyThenSignsTheRequest() async throws {
        let (model, store, attestor, service) = make()
        #expect(try await model.reply(to: request) == "reply 1")
        #expect(service.paths == ["/v1/attest/challenge", "/v1/attest", "/v1/reply"])
        #expect(store.load("dev") == StoredKey(keyId: "key-1", attested: true))

        let attest = try #require(service.requests.first { $0.url?.path() == "/v1/attest" })
        let fields = try JSONDecoder().decode([String: String].self, from: try #require(attest.httpBody))
        #expect(fields["challenge"] == "challenge-1")
        #expect(attestor.attested == [Data(SHA256.hash(data: Data("challenge-1".utf8)))])

        let reply = try #require(service.requests.last)
        let body = try #require(reply.httpBody)
        #expect(reply.value(forHTTPHeaderField: "X-Widgie-Key") == "key-1")
        #expect(reply.value(forHTTPHeaderField: "X-Widgie-Assertion") == Data("assertion-1".utf8).base64EncodedString())
        #expect(attestor.asserted == [AttestedModel.clientDataHash(body: body)])
    }

    @Test func theClientDataIsTheMethodThePathAndTheBodysHexDigest() {
        let body = Data("{}".utf8)
        let digest = "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"
        #expect(SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined() == digest)
        #expect(
            AttestedModel.clientDataHash(body: body) == Data(SHA256.hash(data: Data("POST\n/v1/reply\n\(digest)".utf8)))
        )
    }

    @Test func aLaterCallSignsWithTheSameKeyAndAttestsNothing() async throws {
        let (model, _, attestor, service) = make()
        _ = try await model.reply(to: request)
        _ = try await model.reply(to: request)
        #expect(service.paths.filter { $0 == "/v1/attest" }.count == 1)
        #expect(attestor.generated == 1)
    }

    @Test func aKeyThePhoneNoLongerHoldsIsReplacedAndTheCallSucceeds() async throws {
        let (model, store, attestor, _) = make()
        _ = try await model.reply(to: request)
        attestor.failNextAssertion(with: DCError(.invalidKey))
        #expect(try await model.reply(to: request) == "reply 2")
        #expect(attestor.generated == 2)
        #expect(store.load("dev") == StoredKey(keyId: "key-2", attested: true))
    }

    @Test func aKeyTheServerDoesNotKnowIsReplacedOnceAndThenTheCallFails() async throws {
        let (model, _, attestor, service) = make()
        _ = try await model.reply(to: request)
        service.answerReplies(with: [(401, #"{"error":"unknown key","code":"unknown-key"}"#)], times: 2)
        await #expect(throws: AttestedModel.Refused.self) { try await model.reply(to: request) }
        #expect(attestor.generated == 2)
    }

    @Test func aBadAssertionFailsTheCallAndKeepsTheKey() async throws {
        let (model, store, attestor, service) = make()
        _ = try await model.reply(to: request)
        service.answerReplies(with: [(401, #"{"error":"bad assertion","code":"bad-assertion"}"#)], times: 1)
        let error = await #expect(throws: AttestedModel.Refused.self) { try await model.reply(to: request) }
        #expect(error?.code == "bad-assertion")
        #expect(attestor.generated == 1)
        #expect(store.load("dev") == StoredKey(keyId: "key-1", attested: true))
    }

    @Test func anUnavailableAttestationServiceKeepsThePendingKeyForTheNextCall() async throws {
        let (model, store, attestor, _) = make()
        attestor.failNextAttestation(with: DCError(.serverUnavailable))
        await #expect(throws: AttestedModel.Unreachable.self) { try await model.reply(to: request) }
        #expect(store.load("dev") == StoredKey(keyId: "key-1", attested: false))

        #expect(try await model.reply(to: request) == "reply 1")
        #expect(attestor.generated == 1)
        #expect(store.load("dev") == StoredKey(keyId: "key-1", attested: true))
    }

    @Test func anyOtherAttestationErrorDiscardsTheKeyAndTheNextCallMakesANewOne() async throws {
        let (model, store, attestor, _) = make()
        attestor.failNextAttestation(with: DCError(.unknownSystemFailure))
        await #expect(throws: DCError.self) { try await model.reply(to: request) }
        #expect(store.load("dev") == nil)

        #expect(try await model.reply(to: request) == "reply 1")
        #expect(attestor.generated == 2)
        #expect(store.load("dev") == StoredKey(keyId: "key-2", attested: true))
    }

    @Test func anAttestationTheServerDoesNotTakeDiscardsTheKey() async throws {
        for (status, body) in [(401, #"{"error":"bad","code":"bad-attestation"}"#), (503, "")] {
            let (model, store, attestor, service) = make()
            service.answerAttestations(with: [(status, body)])
            let error = await #expect(throws: AttestedModel.Refused.self) { try await model.reply(to: request) }
            #expect(error?.status == status)
            #expect(store.load("dev") == nil)

            #expect(try await model.reply(to: request) == "reply 1")
            #expect(attestor.generated == 2)
            #expect(store.load("dev") == StoredKey(keyId: "key-2", attested: true))
        }
    }

    @Test func aKeyAppAttestRefusesIsReplacedOnceWithinTheCall() async throws {
        let (model, store, attestor, service) = make()
        attestor.failNextAttestation(with: DCError(.invalidKey))
        #expect(try await model.reply(to: request) == "reply 1")
        #expect(attestor.generated == 2)
        #expect(store.load("dev") == StoredKey(keyId: "key-2", attested: true))
        #expect(service.paths == ["/v1/attest/challenge", "/v1/attest/challenge", "/v1/attest", "/v1/reply"])
    }

    @Test func aPendingKeyAppAttestNoLongerHoldsIsReplacedWithinTheCall() async throws {
        let (model, store, attestor, _) = make()
        attestor.failNextAttestation(with: DCError(.serverUnavailable))
        await #expect(throws: AttestedModel.Unreachable.self) { try await model.reply(to: request) }
        attestor.failNextAttestation(with: DCError(.invalidKey))
        #expect(try await model.reply(to: request) == "reply 1")
        #expect(attestor.generated == 2)
        #expect(store.load("dev") == StoredKey(keyId: "key-2", attested: true))
    }

    @Test func aSecondRefusedKeyInOneCallFailsTheCallAndKeepsNoKey() async throws {
        let (model, store, attestor, service) = make()
        attestor.failNextAttestation(with: DCError(.invalidKey))
        attestor.failNextAttestation(with: DCError(.invalidKey))
        let error = await #expect(throws: AttestedModel.Refused.self) { try await model.reply(to: request) }
        #expect(error?.code == "invalid-key")
        #expect(attestor.generated == 2)
        #expect(store.load("dev") == nil)
        #expect(!service.paths.contains("/v1/reply"))
    }

    @Test func registeringSignsAnEmptyBodyForTheAccountRouteWithTheSameKey() async throws {
        let (model, _, attestor, service) = make()
        _ = try await model.reply(to: request)
        #expect(try await model.registerAccount() == "token-1")
        let register = try #require(service.requests.last)
        #expect(register.url?.path() == "/v1/account" && register.httpMethod == "POST")
        #expect(register.httpBody == Data())
        #expect(register.value(forHTTPHeaderField: "X-Widgie-Key") == "key-1")
        #expect(attestor.asserted.last == AttestedModel.clientDataHash(body: Data(), path: "/v1/account"))
        #expect(attestor.generated == 1, "building and registering share one key")
    }

    @Test func aKeyTheServerDoesNotKnowIsReplacedWhenRegistering() async throws {
        let (model, store, attestor, service) = make()
        _ = try await model.reply(to: request)
        service.answerReplies(with: [(401, #"{"error":"unknown key","code":"unknown-key"}"#)], times: 1)
        #expect(try await model.registerAccount() == "token-1")
        #expect(attestor.generated == 2)
        #expect(store.load("dev") == StoredKey(keyId: "key-2", attested: true))
    }

    @Test func twoCallsAtOnceAttestOnceAndReachTheServerOneAtATime() async throws {
        let (model, _, attestor, service) = make()
        async let first = model.reply(to: request)
        async let second = model.reply(to: request)
        _ = try await (first, second)
        #expect(attestor.generated == 1)
        #expect(service.paths.filter { $0 == "/v1/attest" }.count == 1)
        #expect(service.maxInFlight == 1)
    }

    private func make() -> (AttestedModel, MemoryStore, FakeAttestor, FakeService) {
        let store = MemoryStore()
        let attestor = FakeAttestor()
        let service = FakeService()
        return (
            AttestedModel(base: base, account: "dev", store: store, attestor: attestor, transport: service), store,
            attestor, service
        )
    }
}

private final class MemoryStore: KeyStore {
    private let keys = Mutex<[String: StoredKey]>([:])
    func load(_ account: String) -> StoredKey? { keys.withLock { $0[account] } }
    func save(_ key: StoredKey, _ account: String) { keys.withLock { $0[account] = key } }
    func delete(_ account: String) { _ = keys.withLock { $0.removeValue(forKey: account) } }
}

private final class FakeAttestor: Attestor {
    private struct State {
        var generated = 0
        var attested: [Data] = []
        var asserted: [Data] = []
        var nextAssertionError: (any Error)?
        var attestationErrors: [any Error] = []
    }

    private let state = Mutex(State())
    var generated: Int { state.withLock { $0.generated } }
    var attested: [Data] { state.withLock { $0.attested } }
    var asserted: [Data] { state.withLock { $0.asserted } }

    func failNextAssertion(with error: any Error) { state.withLock { $0.nextAssertionError = error } }
    /// Queues an error for the next `attestKey` call that has none queued before it.
    func failNextAttestation(with error: any Error) { state.withLock { $0.attestationErrors.append(error) } }

    func generateKey() async throws -> String {
        state.withLock { state in
            state.generated += 1
            return "key-\(state.generated)"
        }
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try state.withLock { state in
            if !state.attestationErrors.isEmpty { throw state.attestationErrors.removeFirst() }
            state.attested.append(clientDataHash)
            return Data("attestation of \(keyId)".utf8)
        }
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try state.withLock { state in
            if let error = state.nextAssertionError {
                state.nextAssertionError = nil
                throw error
            }
            state.asserted.append(clientDataHash)
            return Data("assertion-\(state.asserted.count)".utf8)
        }
    }
}

/// The Worker's attest, reply, and account routes. Challenges count up, an attestation is taken unless a scripted
/// answer comes first, each reply is "reply <n>" and each registration "token-1" unless a scripted answer comes first.
private final class FakeService: HTTPTransport {
    private struct State {
        var requests: [URLRequest] = []
        var challenges = 0
        var replies = 0
        var scripted: [(Int, String)] = []
        var attestations: [(Int, String)] = []
        var inFlight = 0
        var maxInFlight = 0
    }

    private let state = Mutex(State())
    var requests: [URLRequest] { state.withLock { $0.requests } }
    var paths: [String] { requests.compactMap { $0.url?.path() } }
    var maxInFlight: Int { state.withLock { $0.maxInFlight } }

    func answerReplies(with answers: [(Int, String)], times: Int) {
        state.withLock { $0.scripted = Array(repeating: answers, count: times).flatMap { $0 } }
    }

    func answerAttestations(with answers: [(Int, String)]) { state.withLock { $0.attestations = answers } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path() ?? ""
        let (status, body): (Int, String) = state.withLock { state in
            state.requests.append(request)
            switch path {
            case "/v1/attest/challenge":
                state.challenges += 1
                return (200, #"{"challenge":"challenge-\#(state.challenges)"}"#)
            case "/v1/attest":
                return state.attestations.isEmpty ? (204, "") : state.attestations.removeFirst()
            case "/v1/account":
                if !state.scripted.isEmpty { return state.scripted.removeFirst() }
                return (200, #"{"token":"token-1"}"#)
            default:
                if !state.scripted.isEmpty { return state.scripted.removeFirst() }
                state.inFlight += 1
                state.maxInFlight = max(state.maxInFlight, state.inFlight)
                state.replies += 1
                return (200, #"{"reply":"reply \#(state.replies)","seconds":1.5,"model":"m"}"#)
            }
        }
        if path == "/v1/reply" && status == 200 {
            try await Task.sleep(for: .milliseconds(20))
            state.withLock { $0.inFlight -= 1 }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}
