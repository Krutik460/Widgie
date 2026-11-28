import CryptoKit
import Foundation
import Synchronization
import Testing
import WidgetEngine
import WidgetHosting

/// `AccountClient` against a scripted Worker, an in-memory token, and defaults of its own, so no test touches the
/// network or the Keychain.
@Suite struct AccountPullTests {
    @Test func withNoTokenARenderPullsNothing() async throws {
        let rig = AccountRig(token: nil)
        await rig.client.pullBeforeRender()
        #expect(rig.server.requests.isEmpty)
        #expect(rig.state.lastPull == nil)
    }

    /// Before the app first runs after an install, a token an earlier install left is not this account's.
    @Test func beforeTheAppClaimsTheInstallARenderPullsNothingAndKeepsTheToken() async throws {
        let rig = AccountRig(token: "left-behind", installed: false)
        await rig.client.pullBeforeRender()
        #expect(rig.server.requests.isEmpty)
        #expect(rig.tokens.load() == "left-behind", "only the app discards it")
    }

    @Test func aDuePullMergesThePageAndRecordsTheRation() async throws {
        let rig = AccountRig()
        let id = try await rig.scratch.build(try fixture("wotd"))
        let next = rig.clock.now.addingTimeInterval(3600)
        rig.server.pages = [try rig.page(for: id, ids: 1, nextWrite: next)]

        await rig.client.pullBeforeRender()
        #expect(rig.server.paths == ["/v1/changes?after=0"])
        #expect(rig.server.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
        #expect(try rig.scratch.engine.watermark() == 5)
        #expect(rig.state.lastPull == rig.clock.now)
        #expect(rig.state.nextWrite == next)
    }

    @Test func aRenderPullsAtMostEveryThirtyMinutes() async throws {
        let rig = AccountRig()
        await rig.client.pullBeforeRender()
        rig.clock.advance(29 * 60)
        await rig.client.pullBeforeRender()
        #expect(rig.server.requests.count == 1)
        rig.clock.advance(2 * 60)
        await rig.client.pullBeforeRender()
        #expect(rig.server.requests.count == 2)
    }

    @Test func aRenderPullsOnceTheServersNextWriteHasPassed() async throws {
        let rig = AccountRig()
        rig.server.pages = [try AccountRig.body([], nextWrite: rig.clock.now.addingTimeInterval(10 * 60))]
        await rig.client.pullBeforeRender()
        rig.clock.advance(9 * 60)
        await rig.client.pullBeforeRender()
        #expect(rig.server.requests.count == 1)
        rig.clock.advance(2 * 60)
        await rig.client.pullBeforeRender()
        #expect(rig.server.requests.count == 2, "eleven minutes on, the write the server expected is due")
    }

    @Test @MainActor func aFailedPullStillRendersWhatIsStored() async throws {
        let rig = AccountRig()
        let id = try await rig.scratch.build(try fixture("wotd"))
        rig.server.pages = [try rig.page(for: id, ids: 1)]
        await rig.client.pullBeforeRender()
        let stored = await rig.scratch.face(id, .medium, at: rig.clock.now)

        for failure in [Failure.status(500), .offline, .notAPage, .status(401)] {
            rig.clock.advance(31 * 60)
            rig.server.failure = failure
            await rig.client.pullBeforeRender()
            #expect(try rig.scratch.engine.watermark() == 5)
            let face = await rig.scratch.face(id, .medium, at: rig.clock.now)
            #expect(!face.isFallback && picture(face, .medium).looksLike(picture(stored, .medium)))
        }
        #expect(rig.server.requests.count == 5)
    }

    @Test func theRenderLimitIsFourSeconds() {
        #expect(AccountClient.renderLimit == .seconds(4))
    }

    /// The limit is a deadline on the whole pull: a request that never answers, even one that ignores
    /// cancellation, cannot hold the render past it.
    @Test func aPullThatNeverAnswersEndsAtTheDeadlineAndTheWidgetStillRenders() async throws {
        let rig = AccountRig()
        let id = try await rig.scratch.build(try fixture("wotd"))
        rig.server.hangs = true
        let started = ContinuousClock.now
        await rig.client.pullBeforeRender(within: .milliseconds(200))
        let waited = ContinuousClock.now - started
        #expect(waited >= .milliseconds(200) && waited < .seconds(2))
        #expect(!(await rig.scratch.face(id, .medium)).isFallback)
        rig.server.release()
    }

    /// A second render while a pull runs waits for it, so it draws the rows the pull brings, and sends nothing.
    @Test func rendersAtOnceShareOnePull() async throws {
        let rig = AccountRig()
        let id = try await rig.scratch.build(try fixture("wotd"))
        rig.server.pages = [try rig.page(for: id, ids: 1)]
        rig.server.hangs = true
        let first = Task { await rig.client.pullBeforeRender() }
        try await rig.server.waitForRequests(1)
        let second = Task {
            await rig.client.pullBeforeRender()
            return try rig.scratch.engine.watermark()
        }
        try await Task.sleep(for: .milliseconds(50))
        rig.server.release()
        #expect(try await second.value == 5, "the second render waited for the pull")
        await first.value
        #expect(rig.server.requests.count == 1)
    }

    @Test func fullPagesArePulledUntilOneIsShort() async throws {
        let rig = AccountRig()
        let id = try await rig.scratch.build(try fixture("wotd"))
        let dataset = try dataset(of: id, in: rig.scratch.engine)
        let runs = (0..<100).map { day in
            Run(
                dataset: dataset, at: rig.clock.now.addingTimeInterval(Double(day - 100) * 86_400),
                written: rig.clock.now.addingTimeInterval(-60),
                cells: ["word": "w\(day)", "kind": "noun", "definition": "d", "example": "e"])
        }
        let full = runs.enumerated().flatMap { index, run in run.changes(from: 1 + index * 5) }
        #expect(full.count == RemotePage.limit)
        rig.server.pages = [try AccountRig.body(full, nextWrite: nil), try rig.page(for: id, ids: 501)]

        #expect(await rig.client.pull())
        #expect(rig.server.paths == ["/v1/changes?after=0", "/v1/changes?after=500"])
        #expect(try rig.scratch.engine.watermark() == 505)
    }

    @Test func aTokenTheServerForgotIsDroppedUnlessANewerOneWasSaved() async throws {
        let rig = AccountRig()
        rig.server.failure = .status(401)
        rig.state.acknowledged = "old"
        #expect(!(await rig.client.pull()))
        #expect(rig.tokens.load() == nil && rig.state.acknowledged == nil)

        rig.tokens.save("token-2")
        rig.server.onRequest = { rig.tokens.save("token-3") }
        #expect(!(await rig.client.pull()))
        #expect(rig.tokens.load() == "token-3", "the app registered again while the old token was refused")
    }
}

@Suite struct AccountUploadTests {
    @Test func withNoAutomationAndNoAccountNothingIsSentOrRegistered() async throws {
        let rig = AccountRig(token: nil)
        _ = try await rig.scratch.build(try fixture("water"))
        #expect(try await rig.client.upload(register: rig.register) == .unchanged)
        #expect(rig.registered == 0 && rig.server.requests.isEmpty)
    }

    @Test func theFirstAutomationRegistersAndUploads() async throws {
        let rig = AccountRig(token: nil)
        _ = try await rig.scratch.build(try fixture("wotd"))
        #expect(try await rig.client.upload(register: rig.register) == .uploaded(automations: 1))
        #expect(rig.registered == 1 && rig.tokens.load() == "registered-1")
        let put = try #require(rig.server.requests.first)
        #expect(put.httpMethod == "PUT" && put.url?.path() == "/v1/automations")
        #expect(put.value(forHTTPHeaderField: "Authorization") == "Bearer registered-1")
        #expect(put.httpBody == (try rig.scratch.engine.automationPayload().json))
        #expect(rig.state.acknowledged == (try rig.scratch.engine.automationPayload().digest))

        #expect(try await rig.client.upload(register: rig.register) == .unchanged, "the server holds this payload")
        #expect(rig.server.requests.count == 1)
    }

    @Test func aBuildThatCannotRegisterSaysSo() async throws {
        let rig = AccountRig(token: nil)
        _ = try await rig.scratch.build(try fixture("wotd"))
        #expect(try await rig.client.upload(register: nil) == .noAccount)
        #expect(rig.server.requests.isEmpty)
    }

    @Test func removingTheLastAutomationIsSentToo() async throws {
        let rig = AccountRig()
        let id = try await rig.scratch.build(try fixture("wotd"))
        _ = try await rig.client.upload(register: rig.register)
        try rig.scratch.engine.delete(id)
        #expect(try await rig.client.upload(register: rig.register) == .uploaded(automations: 0))
        #expect(rig.server.requests.count == 2)
    }

    @Test func aConflictIsSentAgainUpToThreeTimes() async throws {
        let rig = AccountRig()
        _ = try await rig.scratch.build(try fixture("wotd"))
        rig.server.uploads = [409, 409, 409]
        #expect(try await rig.client.upload(register: rig.register) == .uploaded(automations: 1))
        #expect(rig.server.requests.count == 4)

        _ = try await rig.scratch.build(try fixture("wotd"))
        rig.server.uploads = [409, 409, 409, 409]
        let error = await #expect(throws: AccountClient.Refused.self) {
            try await rig.client.upload(register: rig.register)
        }
        #expect(error?.code == "conflict")
        #expect(rig.server.requests.count == 8)
    }

    @Test func aPayloadOverALimitIsRefusedAndSentAgainNextTime() async throws {
        let rig = AccountRig()
        _ = try await rig.scratch.build(try fixture("wotd"))
        rig.server.uploads = [422]
        #expect(try await rig.client.upload(register: rig.register) == .refused(code: "too-many-on-widget"))
        #expect(rig.state.acknowledged == nil)
        #expect(try await rig.client.upload(register: rig.register) == .uploaded(automations: 1))
    }

    @Test func aFailedUploadIsSentAgainNextTime() async throws {
        let rig = AccountRig()
        _ = try await rig.scratch.build(try fixture("wotd"))
        rig.server.failure = .offline
        await #expect(throws: URLError.self) { try await rig.client.upload(register: rig.register) }
        rig.server.failure = nil
        #expect(try await rig.client.upload(register: rig.register) == .uploaded(automations: 1))
    }

    @Test func aTokenTheServerForgotRegistersAgainOnce() async throws {
        let rig = AccountRig()
        _ = try await rig.scratch.build(try fixture("wotd"))
        rig.server.uploads = [401]
        #expect(try await rig.client.upload(register: rig.register) == .uploaded(automations: 1))
        #expect(rig.registered == 1 && rig.tokens.load() == "registered-1")

        _ = try await rig.scratch.build(try fixture("wotd"))
        rig.server.uploads = [401, 401]
        await #expect(throws: AccountClient.Refused.self) { try await rig.client.upload(register: rig.register) }
        #expect(rig.registered == 2, "a new account the server refuses is not registered again")
    }

    /// The Keychain outlives the app and the App Group does not, so a reinstall finds the old install's token.
    @Test func theFirstUploadOfAnInstallDiscardsATokenAnEarlierInstallLeft() async throws {
        let rig = AccountRig(token: "left-behind", installed: false)
        _ = try await rig.scratch.build(try fixture("wotd"))
        _ = try await rig.client.upload(register: rig.register)
        #expect(rig.registered == 1 && rig.tokens.load() == "registered-1")
        #expect(rig.server.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer registered-1")

        await rig.client.claimInstall()
        #expect(rig.tokens.load() == "registered-1", "the install is claimed once")
    }
}

// MARK: The rig

/// A client on a scratch engine, with the scripted Worker, a token, defaults of its own, and a clock the test moves.
final class AccountRig: Sendable {
    let scratch = Scratch()
    let tokens = MemoryTokens()
    let server = ScriptedWorker()
    let clock = MovingClock(morning)
    let state: AccountState
    let client: AccountClient
    private let suite = "account-tests-\(UUID().uuidString)"
    private let registrations = Mutex(0)

    init(token: String? = "token-1", installed: Bool = true) {
        state = AccountState(defaults: UserDefaults(suiteName: suite)!)
        state.installed = installed
        if let token { tokens.save(token) }
        let clock = clock
        client = AccountClient(
            base: URL(string: "https://worker.test")!, engine: scratch.engine, tokens: tokens, state: state,
            transport: server, now: { clock.now })
    }

    deinit { UserDefaults.standard.removePersistentDomain(forName: suite) }

    var registered: Int { registrations.withLock { $0 } }

    /// Registers as the dev path would: a new account each time.
    var register: @Sendable () async throws -> String {
        { [self] in
            let count = registrations.withLock { count in
                count += 1
                return count
            }
            return "registered-\(count)"
        }
    }

    /// The body of a page with one run of `id`'s word automation, ids from `first`: five changes.
    func page(for id: WidgetID, ids first: Int, nextWrite: Date? = nil) throws -> Data {
        let run = Run(
            dataset: try dataset(of: id, in: scratch.engine), at: clock.now.addingTimeInterval(-3600),
            written: clock.now.addingTimeInterval(-7200),
            cells: [
                "word": "Petrichor", "kind": "noun", "definition": "The smell after rain.", "example": "Rain came.",
            ])
        return try Self.body(run.changes(from: first), nextWrite: nextWrite)
    }

    /// A page's body, as the Worker writes it.
    static func body(_ changes: [[String: Any]], nextWrite: Date?) throws -> Data {
        let object: [String: Any] = [
            "replica": "7d9e4c1a-2b3f-4a5d-8e6f-1c2d3e4f5a6b", "changes": changes,
            "nextWrite": nextWrite.map { Int64($0.timeIntervalSince1970 * 1000) } ?? NSNull(),
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }
}

final class MemoryTokens: TokenStore {
    private let token = Mutex<String?>(nil)
    func load() -> String? { token.withLock { $0 } }
    func save(_ token: String) { self.token.withLock { $0 = token } }
    func delete() { token.withLock { $0 = nil } }
}

final class MovingClock: Sendable {
    private let date: Mutex<Date>
    init(_ date: Date) { self.date = Mutex(date) }
    var now: Date { date.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { date.withLock { $0.addTimeInterval(seconds) } }
}

enum Failure: Sendable {
    case status(Int)
    case offline
    case notAPage
}

/// The Worker's pull and upload. A pull answers the next scripted page, or an empty page; an upload answers the next
/// scripted status, or 200 with the digest of what it received. `hangs` holds every request, ignoring cancellation,
/// until `release`.
final class ScriptedWorker: HTTPTransport {
    private struct State {
        var requests: [URLRequest] = []
        var pages: [Data] = []
        var uploads: [Int] = []
        var failure: Failure?
        var hangs = false
        var held: [CheckedContinuation<Void, Never>] = []
        var onRequest: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    var requests: [URLRequest] { state.withLock { $0.requests } }
    /// Each request's path and query.
    var paths: [String] {
        requests.compactMap { request in
            request.url.map { url in url.query().map { "\(url.path())?\($0)" } ?? url.path() }
        }
    }
    /// Page bodies, answered in turn.
    var pages: [Data] {
        get { state.withLock { $0.pages } }
        set { state.withLock { $0.pages = newValue } }
    }
    var uploads: [Int] {
        get { state.withLock { $0.uploads } }
        set { state.withLock { $0.uploads = newValue } }
    }
    var failure: Failure? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }
    var hangs: Bool {
        get { state.withLock { $0.hangs } }
        set { state.withLock { $0.hangs = newValue } }
    }
    var onRequest: (@Sendable () -> Void)? {
        get { state.withLock { $0.onRequest } }
        set { state.withLock { $0.onRequest = newValue } }
    }

    func release() {
        let held = state.withLock { state in
            state.hangs = false
            defer { state.held = [] }
            return state.held
        }
        for request in held { request.resume() }
    }

    func waitForRequests(_ count: Int) async throws {
        for _ in 0..<500 where requests.count < count { try await Task.sleep(for: .milliseconds(10)) }
        try #require(requests.count >= count)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (hangs, onRequest) = state.withLock { state in
            state.requests.append(request)
            return (state.hangs, state.onRequest)
        }
        onRequest?()
        if hangs { await withCheckedContinuation { held in state.withLock { $0.held.append(held) } } }
        let (status, body): (Int, Data) = try state.withLock { state in
            switch state.failure {
            case .status(401): return (401, Data(#"{"error":"who","code":"bad-token"}"#.utf8))
            case .status(let status): return (status, Data(#"{"error":"broken"}"#.utf8))
            case .offline: throw URLError(.notConnectedToInternet)
            case .notAPage: return (200, Data("{}".utf8))
            case nil: break
            }
            if request.httpMethod == "PUT" {
                let status = state.uploads.isEmpty ? 200 : state.uploads.removeFirst()
                switch status {
                case 200:
                    let digest = SHA256.hash(data: request.httpBody ?? Data()).map { String(format: "%02x", $0) }
                    return (200, Data(#"{"digest":"\#(digest.joined())"}"#.utf8))
                case 409: return (409, Data(#"{"error":"again","code":"conflict"}"#.utf8))
                case 401: return (401, Data(#"{"error":"who","code":"bad-token"}"#.utf8))
                default: return (status, Data(#"{"error":"over","code":"too-many-on-widget"}"#.utf8))
                }
            }
            if state.pages.isEmpty { return (200, try AccountRig.body([], nextWrite: nil)) }
            return (200, state.pages.removeFirst())
        }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
