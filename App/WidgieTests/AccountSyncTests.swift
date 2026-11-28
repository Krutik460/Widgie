import CryptoKit
import Foundation
import Security
import Synchronization
import Testing
import UIKit
import WidgetBuilder
import WidgetEngine
import WidgetHosting

@testable import Widgie

/// `AccountSync` on a temporary store whose commits post `Hosting.didCommit` on a center of its own, against a
/// scripted Worker, so no test touches the network, the Keychain, or the App Group.
@MainActor @Suite struct AccountSyncTests {
    @Test func everyChangeThatMovesThePayloadUploadsIt() async throws {
        let rig = SyncRig()
        let library = Library(engine: rig.engine)
        guard case .success(let id) = await library.add(try Template.bundled("word-of-the-day").source()) else {
            throw Unexpected()
        }
        try await rig.uploads(1, "a template added")
        #expect(rig.registered == 1, "the first automation registers the account")

        _ = try await rig.engine.saved(try rig.refined(id, prompt: "Pick a useful French word."), replacing: id)
        try await rig.uploads(2, "a refinement")

        let other = try await rig.engine.saved(try Template.bundled("word-of-the-day").source())
        try await rig.uploads(3, "a save")

        try rig.engine.restore(id, to: try rig.engine.history(of: id)[1])
        try await rig.uploads(4, "a restore")

        library.delete(other)
        try await rig.uploads(5, "a delete")

        rig.center.post(name: Hosting.didCommit, object: nil)
        await rig.sync.settled()
        #expect(rig.server.puts.count == 5, "a commit that moves nothing, such as a tap, sends nothing")
        #expect(rig.server.puts.last?.httpBody == (try rig.engine.automationPayload().json))
        #expect(rig.registered == 1)
    }

    /// The payload names the phone's zone, so a move changes it; here the server lacks it because the save's upload
    /// failed, which a move cannot be staged without.
    @Test(arguments: [Notification.Name.NSSystemTimeZoneDidChange, UIApplication.significantTimeChangeNotification])
    func aTimeZoneOrClockChangeUploadsWhenThePayloadDiffers(_ name: Notification.Name) async throws {
        let rig = SyncRig()
        rig.server.offline = true
        _ = try await rig.engine.saved(try Template.bundled("word-of-the-day").source())
        await rig.sync.settled()
        #expect(rig.server.puts.count == 1, "the save tried to upload")
        rig.server.offline = false
        rig.center.post(name: name, object: nil)
        try await rig.uploads(2, "the change")
    }

    @Test func anUploadThatFailedIsSentAgainOnForeground() async throws {
        let rig = SyncRig()
        rig.server.offline = true
        _ = try await rig.engine.saved(try Template.bundled("word-of-the-day").source())
        await rig.sync.settled()
        #expect(rig.server.puts.count == 1, "the save tried to upload")
        #expect(rig.state.acknowledged == nil)

        rig.server.offline = false
        rig.sync.foreground()
        try await rig.uploads(2, "the foreground")
        #expect(rig.server.pulls == 1)

        rig.sync.foreground()
        await rig.sync.settled()
        #expect(rig.server.puts.count == 2, "a foreground with the digest acknowledged sends nothing")
        #expect(rig.server.pulls == 2, "each foreground pulls")
    }

    /// After a failed registration, a change does not register again, and a foreground does only once the wait
    /// has passed, so a failing `/v1/account` never makes a new App Attest key at every commit.
    @Test func aFailedRegistrationIsTriedAgainOnlyOnAForegroundAfterItsWait() async throws {
        let rig = SyncRig()
        rig.registrationFails = true
        _ = try await rig.engine.saved(try Template.bundled("word-of-the-day").source())
        await rig.sync.settled()
        #expect(rig.registered == 1)

        _ = try await rig.engine.saved(try Template.bundled("word-of-the-day").source())
        rig.sync.foreground()
        await rig.sync.settled()
        #expect(rig.registered == 1, "a change and a foreground within the wait")

        rig.clock.move(to: rig.clock.now.addingTimeInterval(61))
        rig.registrationFails = false
        rig.center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        await rig.sync.settled()
        #expect(rig.registered == 1, "a change after the wait")

        rig.sync.foreground()
        try await rig.uploads(1, "the foreground after the wait")
        #expect(rig.registered == 2)
    }

    @Test func anUploadThatNamesAnAutomationPullsEveryFiveSecondsForAMinute() async throws {
        let rig = SyncRig(polls: true)
        let id = try await rig.engine.saved(try Template.bundled("word-of-the-day").source())
        try await rig.uploads(1, "the save")
        #expect(rig.server.pulls == 12)
        #expect(rig.sleeps == Array(repeating: .seconds(5), count: 12))

        try rig.engine.delete(id)
        try await rig.uploads(2, "the delete")
        #expect(rig.server.pulls == 12, "an upload with no automation starts no run")
    }

    @Test func goingToTheBackgroundStopsThePulls() async throws {
        let gate = Latch()
        let rig = SyncRig(polls: true, sleep: { await gate.wait() })
        _ = try await rig.engine.saved(try Template.bundled("word-of-the-day").source())
        try await until({ gate.waiting }, "the poll never started")
        rig.sync.background()
        gate.open()
        await rig.sync.settled()
        #expect(rig.server.pulls == 0)
    }

    /// The app hosting these tests makes no sync of its own, which would reach the dev Worker.
    @Test func theAppHostingTheTestsKnowsItAndStartsNoSync() {
        #expect(AccountSync.hostedByTests())
        #expect(!AccountSync.hostedByTests([:]))
        #expect(!AccountSync.hostedByTests(["HOME": "/"]))
    }
}

@Suite struct RegistrationTests {
    let base = URL(string: "https://worker.test")!

    @Test func aPhoneRegistersWithAppAttestAndNeverTheDevSecret() throws {
        let model = AttestedModel(base: base, account: "dev")
        guard case .attested = Registration.path(simulator: false, base: base, devSecret: "s", attested: model) else {
            Issue.record("a phone uses App Attest")
            return
        }
        #expect(Registration.path(simulator: false, base: base, devSecret: "s", attested: nil) == nil)
    }

    @Test func theSimulatorRegistersWithTheDevSecretWhenTheBuildCarriesOne() throws {
        guard
            case .dev(_, let secret, _) = Registration.path(simulator: true, base: base, devSecret: "s", attested: nil)
        else {
            Issue.record("the simulator uses the dev secret")
            return
        }
        #expect(secret == "s")
        #expect(Registration.path(simulator: true, base: base, devSecret: nil, attested: nil) == nil)
        #expect(Registration.path(simulator: true, base: base, devSecret: "", attested: nil) == nil)
        #expect(Registration.path(simulator: true, base: nil, devSecret: "s", attested: nil) == nil)
    }

    @Test func theDevPathPostsTheSecretWithAnEmptyBody() async throws {
        let worker = FakeWorker()
        let path = try #require(
            Registration.path(simulator: true, base: base, devSecret: "s3cret", attested: nil, transport: worker))
        #expect(try await path.register() == "dev-token")
        let request = try #require(worker.requests.first)
        #expect(request.httpMethod == "POST" && request.url?.path() == "/v1/account")
        #expect(request.value(forHTTPHeaderField: "X-Widgie-Dev-Secret") == "s3cret")
        #expect(request.httpBody == nil)

        worker.refuseRegistration = true
        let error = await #expect(throws: AccountClient.Refused.self) { try await path.register() }
        #expect(error?.code == "bad-dev-secret")
    }

    /// The real Keychain of the simulator, in the group both targets' entitlements list.
    @Test func theTokenIsKeptInTheSharedGroupFromTheFirstUnlock() throws {
        let group = try #require(Bundle.main.object(forInfoDictionaryKey: "WidgieKeychainGroup") as? String)
        #expect(group.hasSuffix(".dev.krutikpatel.widgie.shared"))
        let service = "dev.krutikpatel.widgie.tests.\(UUID().uuidString)"
        let tokens = KeychainTokens(group: group, service: service)
        defer { tokens.delete() }
        #expect(try tokens.load() == nil)
        try tokens.save("token-1")
        try tokens.save("token-2")
        #expect(try tokens.load() == "token-2", "a save updates the one item")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess)
        let found = try #require(items as? [[String: Any]])
        #expect(found.count == 1)
        let attributes = try #require(found.first)
        #expect(attributes[kSecAttrAccessGroup as String] as? String == group)
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlock as String)
        let fingerprint = try #require(attributes[kSecAttrGeneric as String] as? Data)
        let hex = SHA256.hash(data: Data("token-2".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(fingerprint == Data(hex.utf8), "the token's fingerprint")

        tokens.delete("token-1")
        #expect(try tokens.load() == "token-2", "forgetting a token another save replaced leaves the newer one")
        tokens.delete("token-2")
        #expect(try tokens.load() == nil)

        try tokens.save("token-3")
        tokens.delete()
        #expect(try tokens.load() == nil)
    }

    /// An item an earlier build saved, with no fingerprint, is still forgotten, and only for its own token.
    @Test func aTokenSavedWithoutAFingerprintIsForgottenByComparing() throws {
        let group = try #require(Bundle.main.object(forInfoDictionaryKey: "WidgieKeychainGroup") as? String)
        let service = "dev.krutikpatel.widgie.tests.\(UUID().uuidString)"
        let tokens = KeychainTokens(group: group, service: service)
        defer { tokens.delete() }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "token", kSecAttrAccessGroup as String: group,
            kSecValueData as String: Data("old".utf8),
        ]
        #expect(SecItemAdd(item as CFDictionary, nil) == errSecSuccess)
        tokens.delete("other")
        #expect(try tokens.load() == "old")
        tokens.delete("old")
        #expect(try tokens.load() == nil)
    }
}

// MARK: The rig

/// A store whose commits post `Hosting.didCommit`, an account client on it with an in-memory token, defaults of its
/// own, and a clock the test moves, and the sync under test. Polls are off unless asked for; when on, each wait
/// returns at once.
@MainActor final class SyncRig {
    let directory = FileManager.default.temporaryDirectory.appending(path: "sync-tests-\(UUID().uuidString)")
    let center = NotificationCenter()
    let server = FakeWorker()
    let clock = TestClock(Date())
    let engine: Engine
    let state: AccountState
    let sync: AccountSync
    private let suite = "sync-tests-\(UUID().uuidString)"
    private let counts = Counts()

    init(polls: Bool = false, sleep: (@Sendable () async -> Void)? = nil) {
        let center = center
        engine = Engine(directory: directory, onCommit: { center.post(name: Hosting.didCommit, object: nil) })
        state = AccountState(defaults: UserDefaults(suiteName: suite)!)
        let clock = clock
        let client = AccountClient(
            base: URL(string: "https://worker.test")!, engine: engine, tokens: MemoryTokens(), state: state,
            transport: server, now: { clock.now })
        let counts = counts
        sync = AccountSync(
            account: client,
            register: {
                let fails = counts.value.withLock { counts in
                    counts.registered += 1
                    return counts.registrationFails
                }
                if fails { throw URLError(.cannotConnectToHost) }
                return "token-1"
            }, center: center,
            sleep: { duration in
                guard polls else { throw CancellationError() }
                counts.value.withLock { $0.sleeps.append(duration) }
                await sleep?()
                try Task.checkCancellation()
            })
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    var registered: Int { counts.value.withLock { $0.registered } }
    var sleeps: [Duration] { counts.value.withLock { $0.sleeps } }
    var registrationFails: Bool {
        get { counts.value.withLock { $0.registrationFails } }
        set { counts.value.withLock { $0.registrationFails = newValue } }
    }

    private final class Counts: Sendable {
        let value = Mutex((registered: 0, sleeps: [Duration](), registrationFails: false))
    }

    /// Waits for the sync to settle after the `count`th upload. A post waits for the observers on the main queue,
    /// so by the time a commit or a post returns, the upload it started is running.
    func uploads(_ count: Int, _ change: String) async throws {
        await sync.settled()
        #expect(server.puts.count == count, "\(change) uploaded once")
        #expect(state.acknowledged?.digest == (try engine.automationPayload().digest), "\(change) was acknowledged")
    }

    /// `id`'s source with another prompt for its automation.
    func refined(_ id: WidgetID, prompt: String) throws -> WidgetSource {
        let source = try #require(try engine.source(of: id))
        var document = try #require(try JSONSerialization.jsonObject(with: source.json) as? [String: Any])
        var automations = try #require(document["automations"] as? [String: [String: Any]])
        automations["daily"]?["prompt"] = prompt
        document["automations"] = automations
        return WidgetSource(json: try JSONSerialization.data(withJSONObject: document), images: source.images)
    }
}

private final class MemoryTokens: TokenStore {
    private let token = Mutex<String?>(nil)
    func load() -> String? { token.withLock { $0 } }
    func save(_ token: String) { self.token.withLock { $0 = token } }
    func delete() { token.withLock { $0 = nil } }
    func delete(_ token: String) { self.token.withLock { if $0 == token { $0 = nil } } }
}

/// The Worker's account routes: registration answers `dev-token`, an upload answers the digest of what it received,
/// and a pull answers an empty page.
final class FakeWorker: HTTPTransport {
    private struct State {
        var requests: [URLRequest] = []
        var offline = false
        var refuseRegistration = false
    }

    private let state = Mutex(State())
    var requests: [URLRequest] { state.withLock { $0.requests } }
    var puts: [URLRequest] { requests.filter { $0.httpMethod == "PUT" } }
    var pulls: Int { requests.count { $0.url?.path() == "/v1/changes" } }
    var offline: Bool {
        get { state.withLock { $0.offline } }
        set { state.withLock { $0.offline = newValue } }
    }
    var refuseRegistration: Bool {
        get { state.withLock { $0.refuseRegistration } }
        set { state.withLock { $0.refuseRegistration = newValue } }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (offline, refuse) = state.withLock { state in
            state.requests.append(request)
            return (state.offline, state.refuseRegistration)
        }
        if offline { throw URLError(.notConnectedToInternet) }
        let (status, body): (Int, String)
        switch request.url?.path() {
        case "/v1/account":
            (status, body) =
                refuse ? (401, #"{"error":"no","code":"bad-dev-secret"}"#) : (200, #"{"token":"dev-token"}"#)
        case "/v1/automations":
            let digest = SHA256.hash(data: request.httpBody ?? Data()).map { String(format: "%02x", $0) }.joined()
            (status, body) = (200, #"{"digest":"\#(digest)"}"#)
        default:
            (status, body) = (200, #"{"changes":[],"nextWrite":null,"replica":"7d9e4c1a-2b3f-4a5d-8e6f-1c2d3e4f5a6b"}"#)
        }
        return (
            Data(body.utf8),
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }
}
