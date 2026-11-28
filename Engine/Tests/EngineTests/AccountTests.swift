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
        #expect(try rig.tokens.load() == "left-behind", "only the app discards it")
    }

    @Test func aDuePullMergesThePageAndRecordsTheRation() async throws {
        let rig = AccountRig()
        let id = try await rig.scratch.build(try fixture("wotd"))
        let next = rig.clock.now.addingTimeInterval(3600)
        rig.server.pages = [try rig.page(for: id, ids: 1, nextWrite: next), try AccountRig.body([], nextWrite: next)]

        await rig.client.pullBeforeRender()
        #expect(rig.server.pulls == ["/v1/changes?after=0", "/v1/changes?after=5"], "until a page comes back empty")
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
        #expect(rig.server.pulls.count == 1)
        rig.clock.advance(2 * 60)
        await rig.client.pullBeforeRender()
        #expect(rig.server.pulls.count == 2)
    }

    @Test func aRenderPullsOnceTheServersNextWriteHasPassed() async throws {
        let rig = AccountRig()
        rig.server.pages = [try AccountRig.body([], nextWrite: rig.clock.now.addingTimeInterval(10 * 60))]
        await rig.client.pullBeforeRender()
        rig.clock.advance(9 * 60)
        await rig.client.pullBeforeRender()
        #expect(rig.server.pulls.count == 1)
        rig.clock.advance(2 * 60)
        await rig.client.pullBeforeRender()
        #expect(rig.server.pulls.count == 2, "eleven minutes on, the write the server expected is due")
    }

    /// A pull that fails after `nextWrite` leaves `nextWrite` before its start, so the renders after it wait for
    /// the ration instead of each trying again.
    @Test func aFailingPullAfterTheServersNextWriteWaitsForTheRation() async throws {
        let rig = AccountRig()
        rig.server.pages = [try AccountRig.body([], nextWrite: rig.clock.now.addingTimeInterval(10 * 60))]
        await rig.client.pullBeforeRender()
        rig.clock.advance(11 * 60)
        rig.server.failure = .status(500)
        await rig.client.pullBeforeRender()
        #expect(rig.server.pulls.count == 2)
        for _ in 0..<3 {
            rig.clock.advance(5 * 60)
            await rig.client.pullBeforeRender()
        }
        #expect(rig.server.pulls.count == 2, "fifteen minutes of renders after the failure pull nothing")
        rig.clock.advance(16 * 60)
        await rig.client.pullBeforeRender()
        #expect(rig.server.pulls.count == 3, "31 minutes after the failure, the ration lets one run")
    }

    /// A last pull later than now means the clock moved back; waiting for it to catch up could hold every pull
    /// for as long as it moved.
    @Test func aClockMovedBackMakesAPullDue() async throws {
        let rig = AccountRig()
        await rig.client.pullBeforeRender()
        rig.clock.advance(-3600)
        await rig.client.pullBeforeRender()
        #expect(rig.server.pulls.count == 2)
        await rig.client.pullBeforeRender()
        #expect(rig.server.pulls.count == 2, "the ration counts again from the pull at the new time")
    }

    @Test @MainActor func aFailedPullStillRendersWhatIsStored() async throws {
        let rig = AccountRig()
        let id = try await rig.scratch.build(try fixture("wotd"))
        rig.server.pages = [try rig.page(for: id, ids: 1)]
        await rig.client.pullBeforeRender()
        let stored = await rig.scratch.face(id, .medium, at: rig.clock.now)
        let before = rig.server.pulls.count

        for failure in [Failure.status(500), .offline, .notAPage, .status(401)] {
            rig.clock.advance(31 * 60)
            rig.server.failure = failure
            await rig.client.pullBeforeRender()
            #expect(try rig.scratch.engine.watermark() == 5)
            let face = await rig.scratch.face(id, .medium, at: rig.clock.now)
            #expect(!face.isFallback && picture(face, .medium).looksLike(picture(stored, .medium)))
        }
        #expect(rig.server.pulls.count == before + 4)
    }

    /// The limit is a deadline on the whole flight: a request that never answers, even one that ignores
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

    /// A second render while a flight runs waits for it, so it draws the rows the pull brings, and sends nothing.
    @Test func rendersAtOnceShareOneFlight() async throws {
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
        while await rig.client.joiners < 1 { await Task.yield() }
        rig.server.release()
        #expect(try await second.value == 5, "the second render waited for the pull")
        await first.value
        #expect(rig.server.pulls.count == 2 && rig.server.puts.count == 1, "one flight: two pages and one upload")
    }

    @Test func pagesArePulledUntilOneIsEmpty() async throws {
        let rig = AccountRig()
        let id = try await rig.scratch.build(try fixture("wotd"))
        let dataset = try dataset(of: id, in: rig.scratch.engine)
        let runs = (0..<3).map { day in
            Run(
                dataset: dataset, at: rig.clock.now.addingTimeInterval(Double(day - 3) * 86_400),
                written: rig.clock.now.addingTimeInterval(-60),
                cells: ["word": "w\(day)", "kind": "noun", "definition": "d", "example": "e"])
        }
        let first = runs.enumerated().flatMap { index, run in run.changes(from: 1 + index * 5) }
        rig.server.pages = [try AccountRig.body(first, nextWrite: nil), try rig.page(for: id, ids: 16)]

        #expect(await rig.client.pull())
        #expect(rig.server.pulls == ["/v1/changes?after=0", "/v1/changes?after=15", "/v1/changes?after=20"])
        #expect(try rig.scratch.engine.watermark() == 20)
    }

    /// A page that stops at a change stamped ahead of this clock leaves the watermark, so asking again would bring
    /// the same page.
    @Test func aPageThatStopsAtAHeldChangeEndsThePull() async throws {
        let rig = AccountRig()
        let id = try await rig.scratch.build(try fixture("wotd"))
        let ahead = Run(
            dataset: try dataset(of: id, in: rig.scratch.engine), at: rig.clock.now,
            written: rig.clock.now.addingTimeInterval(3600), cells: ["word": "w"])
        rig.server.pages = [try AccountRig.body(ahead.changes(from: 1), nextWrite: nil)]
        #expect(!(await rig.client.pull()))
        #expect(rig.server.pulls == ["/v1/changes?after=0"])
    }

    @Test func aTokenTheServerForgotIsDroppedUnlessANewerOneWasSaved() async throws {
        let rig = AccountRig()
        rig.server.failure = .status(401)
        #expect(!(await rig.client.pull()))
        #expect(try rig.tokens.load() == nil)

        try rig.tokens.save("token-2")
        rig.server.onRequest = { try? rig.tokens.save("token-3") }
        #expect(!(await rig.client.pull()))
        #expect(try rig.tokens.load() == "token-3", "the app registered again while the old token was refused")
    }
}

/// The extension uploads after its pull when the server lacks the payload, so a zone the phone moved to with the
/// app closed reaches the server. It never registers.
@Suite struct AccountRenderUploadTests {
    @Test func aRenderUploadsTheZoneThePhoneMovedToWithTheAppClosed() async throws {
        let rig = AccountRig()
        _ = try await rig.scratch.build(try fixture("wotd"))
        #expect(try await rig.client.upload(register: rig.register) == .uploaded(automations: 1))

        let tokyo = rig.extensionClient(zone: "Asia/Tokyo")
        await tokyo.pullBeforeRender()
        #expect(rig.server.paths == ["/v1/automations", "/v1/changes?after=0", "/v1/automations"])
        let body = try #require(rig.server.puts.last?.httpBody)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["timeZone"] as? String == "Asia/Tokyo")
        #expect(rig.state.acknowledged?.digest == SHA256.hex(body))

        rig.clock.advance(31 * 60)
        await tokyo.pullBeforeRender()
        #expect(rig.server.pulls.count == 2 && rig.server.puts.count == 2, "acknowledged: the render only pulls")
    }

    @Test func aRenderWithThePayloadAcknowledgedOnlyPulls() async throws {
        let rig = AccountRig()
        _ = try await rig.scratch.build(try fixture("wotd"))
        _ = try await rig.client.upload(register: rig.register)
        await rig.client.pullBeforeRender()
        #expect(rig.server.paths == ["/v1/automations", "/v1/changes?after=0"])
    }

    /// Only the app registers, since App Attest is the app's: a 401 drops the token and the render stops there.
    @Test func aRenderNeverRegisters() async throws {
        let rig = AccountRig()
        _ = try await rig.scratch.build(try fixture("wotd"))
        rig.server.uploads = [401]
        await rig.client.pullBeforeRender()
        #expect(rig.server.puts.count == 1 && rig.registered == 0)
        #expect(try rig.tokens.load() == nil)
    }

    @Test func aRenderDoesNotSendAPayloadTheServerRefused() async throws {
        let rig = AccountRig()
        _ = try await rig.scratch.build(try fixture("wotd"))
        rig.server.uploads = [422]
        #expect(try await rig.client.upload(register: rig.register) == .refused(code: "too-many-on-widget"))
        await rig.client.pullBeforeRender()
        #expect(rig.server.puts.count == 1)
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
        #expect(try rig.registered == 1 && rig.tokens.load() == "registered-1")
        let put = try #require(rig.server.requests.first)
        #expect(put.httpMethod == "PUT" && put.url?.path() == "/v1/automations")
        #expect(put.value(forHTTPHeaderField: "Authorization") == "Bearer registered-1")
        #expect(put.httpBody == (try rig.scratch.engine.automationPayload().json))
        #expect(rig.state.acknowledged?.digest == (try rig.scratch.engine.automationPayload().digest))

        #expect(try await rig.client.upload(register: rig.register) == .unchanged, "the server holds this payload")
        #expect(rig.server.requests.count == 1)
    }

    /// The acknowledgement names the token it was sent with, so a token lost from the Keychain is replaced and the
    /// payload sent to the new account, though the digest has not moved.
    @Test func aLostTokenIsReplacedThoughTheDigestWasAcknowledged() async throws {
        let rig = AccountRig(token: nil)
        _ = try await rig.scratch.build(try fixture("wotd"))
        _ = try await rig.client.upload(register: rig.register)
        rig.tokens.delete()

        #expect(try await rig.client.upload(register: rig.register) == .uploaded(automations: 1))
        #expect(try rig.registered == 2 && rig.tokens.load() == "registered-2")
        #expect(rig.server.puts.last?.value(forHTTPHeaderField: "Authorization") == "Bearer registered-2")
    }

    /// A token that is there but cannot be read is never replaced, which would leave its account unreachable.
    @Test func aTokenThatCannotBeReadFailsTheUploadWithoutRegistering() async throws {
        let rig = AccountRig()
        _ = try await rig.scratch.build(try fixture("wotd"))
        rig.tokens.unreadable = true
        await #expect(throws: MemoryTokens.Unreadable.self) { try await rig.client.upload(register: rig.register) }
        #expect(rig.registered == 0 && rig.server.requests.isEmpty)
    }

    @Test func aTokenThatCannotBeSavedFailsBeforeTheUpload() async throws {
        let rig = AccountRig(token: nil)
        _ = try await rig.scratch.build(try fixture("wotd"))
        rig.tokens.refusesSave = true
        await #expect(throws: MemoryTokens.Unsaved.self) { try await rig.client.upload(register: rig.register) }
        #expect(rig.registered == 1 && rig.server.requests.isEmpty && rig.state.acknowledged == nil)
        let next = try await rig.client.upload(register: rig.register)
        #expect(next == .registrationWaits(until: rig.clock.now.addingTimeInterval(60)), "it counts as a failure")
        #expect(rig.registered == 1)
    }

    /// The server keeps the last upload it took, so an upload that landed after a commit it did not carry sends
    /// the newest payload too: an older payload the other process read never stays on the server.
    @Test func anUploadOvertakenByACommitSendsTheNewestPayloadToo() async throws {
        let rig = AccountRig()
        let id = try await rig.scratch.build(try fixture("wotd"))
        let once = Mutex(false)
        rig.server.onRequest = {
            guard !once.withLock({ $0 }) else { return }
            once.withLock { $0 = true }
            try? rig.scratch.engine.delete(id)
        }
        #expect(try await rig.client.upload(register: rig.register) == .uploaded(automations: 0))
        #expect(rig.server.puts.count == 2)
        #expect(rig.state.acknowledged?.digest == (try rig.scratch.engine.automationPayload().digest))
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

    /// A payload the server refuses for what it holds is not sent again until it changes, whatever triggers the
    /// upload.
    @Test(arguments: [400, 413, 415, 422])
    func aPayloadTheServerRefusesIsNotSentAgainUntilItChanges(_ status: Int) async throws {
        let rig = AccountRig()
        _ = try await rig.scratch.build(try fixture("wotd"))
        rig.server.uploads = [status]
        #expect(try await rig.client.upload(register: rig.register) == .refused(code: "too-many-on-widget"))
        #expect(try await rig.client.upload(register: rig.register) == .refused(code: "too-many-on-widget"))
        #expect(rig.server.puts.count == 1 && rig.state.acknowledged == nil)

        _ = try await rig.scratch.build(try fixture("wotd"))
        #expect(try await rig.client.upload(register: rig.register) == .uploaded(automations: 2))
        #expect(rig.server.puts.count == 2)
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
        #expect(try rig.registered == 1 && rig.tokens.load() == "registered-1")

        _ = try await rig.scratch.build(try fixture("wotd"))
        rig.server.uploads = [401, 401]
        await #expect(throws: AccountClient.Refused.self) { try await rig.client.upload(register: rig.register) }
        #expect(rig.registered == 2, "a new account the server refuses is not registered again")
    }

    /// A failed registration is tried again only on a foreground once its wait has passed, the wait doubling with
    /// each failure in a row: a failing `/v1/account` never makes a new App Attest key at every change.
    @Test func aFailedRegistrationWaitsForAForegroundAndADoublingDelay() async throws {
        let rig = AccountRig(token: nil)
        _ = try await rig.scratch.build(try fixture("wotd"))
        rig.registrationFails = true
        await #expect(throws: AccountRig.Unregistered.self) { try await rig.client.upload(register: rig.register) }
        let first = rig.clock.now.addingTimeInterval(60)
        #expect(try await rig.client.upload(register: rig.register) == .registrationWaits(until: first))
        rig.clock.advance(61)
        let change = try await rig.client.upload(register: rig.register)
        #expect(change == .registrationWaits(until: first), "a change past the wait still waits for a foreground")
        #expect(rig.registered == 1)

        await #expect(throws: AccountRig.Unregistered.self) {
            try await rig.client.upload(register: rig.register, foreground: true)
        }
        #expect(rig.registered == 2)
        let second = rig.clock.now.addingTimeInterval(120)
        rig.clock.advance(61)
        let early = try await rig.client.upload(register: rig.register, foreground: true)
        #expect(early == .registrationWaits(until: second), "a foreground before the doubled wait")

        rig.clock.advance(60)
        rig.registrationFails = false
        #expect(try await rig.client.upload(register: rig.register, foreground: true) == .uploaded(automations: 1))
        #expect(rig.registered == 3 && rig.state.registrationFailure == nil)
    }

    @Test func theRegistrationWaitStopsGrowingAtSixHours() async throws {
        let rig = AccountRig(token: nil)
        _ = try await rig.scratch.build(try fixture("wotd"))
        rig.state.registrationFailure = (40, rig.clock.now)
        let waits = try await rig.client.upload(register: rig.register, foreground: true)
        #expect(waits == .registrationWaits(until: rig.clock.now.addingTimeInterval(6 * 3600)))
        #expect(rig.registered == 0)
    }

    /// The Keychain outlives the app and the App Group does not, so a reinstall finds the old install's token.
    @Test func theFirstUploadOfAnInstallDiscardsATokenAnEarlierInstallLeft() async throws {
        let rig = AccountRig(token: "left-behind", installed: false)
        _ = try await rig.scratch.build(try fixture("wotd"))
        _ = try await rig.client.upload(register: rig.register)
        #expect(try rig.registered == 1 && rig.tokens.load() == "registered-1")
        #expect(rig.server.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer registered-1")

        await rig.client.claimInstall()
        #expect(try rig.tokens.load() == "registered-1", "the install is claimed once")
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
    private let registrations = Mutex((count: 0, fails: false))

    init(token: String? = "token-1", installed: Bool = true) {
        state = AccountState(defaults: UserDefaults(suiteName: suite)!)
        state.installed = installed
        if let token { try! tokens.save(token) }
        let clock = clock
        client = AccountClient(
            base: URL(string: "https://worker.test")!, engine: scratch.engine, tokens: tokens, state: state,
            transport: server, now: { clock.now })
    }

    deinit { UserDefaults.standard.removePersistentDomain(forName: suite) }

    var registered: Int { registrations.withLock { $0.count } }
    var registrationFails: Bool {
        get { registrations.withLock { $0.fails } }
        set { registrations.withLock { $0.fails = newValue } }
    }

    struct Unregistered: Error {}

    /// Registers as the dev path would: a new account each time, or fails while `registrationFails`.
    var register: AccountClient.Register {
        { [self] in
            let (count, fails) = registrations.withLock { state in
                state.count += 1
                return (state.count, state.fails)
            }
            if fails { throw Unregistered() }
            return "registered-\(count)"
        }
    }

    /// The other process's client on the same store, token, state, and Worker, with an engine in `zone`: the
    /// extension after the phone moved.
    func extensionClient(zone: String) -> AccountClient {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        let clock = clock
        return AccountClient(
            base: URL(string: "https://worker.test")!, engine: Engine(directory: scratch.directory, calendar: calendar),
            tokens: tokens, state: state, transport: server, now: { clock.now })
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

/// A token in memory, which can be made unreadable or refuse a save.
final class MemoryTokens: TokenStore {
    struct Unreadable: Error {}
    struct Unsaved: Error {}

    private let state = Mutex((token: String?.none, unreadable: false, refusesSave: false))

    var unreadable: Bool {
        get { state.withLock { $0.unreadable } }
        set { state.withLock { $0.unreadable = newValue } }
    }
    var refusesSave: Bool {
        get { state.withLock { $0.refusesSave } }
        set { state.withLock { $0.refusesSave = newValue } }
    }

    func load() throws -> String? {
        try state.withLock { state in
            if state.unreadable { throw Unreadable() }
            return state.token
        }
    }

    func save(_ token: String) throws {
        try state.withLock { state in
            if state.refusesSave { throw Unsaved() }
            state.token = token
        }
    }

    func delete() { state.withLock { $0.token = nil } }

    func delete(_ token: String) {
        state.withLock { state in
            if state.token == token { state.token = nil }
        }
    }
}

extension SHA256 {
    /// The SHA-256 of `data` as lowercase hex, as the Worker answers an upload.
    static func hex(_ data: Data) -> String { hash(data: data).map { String(format: "%02x", $0) }.joined() }
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
/// scripted status, or 200 with the digest of what it received. `failure` answers every request. `hangs` holds every
/// request, ignoring cancellation, until `release`.
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
    /// The pulls' paths and queries.
    var pulls: [String] { paths.filter { $0.hasPrefix("/v1/changes") } }
    var puts: [URLRequest] { requests.filter { $0.httpMethod == "PUT" } }
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

    /// Waits until `count` requests are held: a request is held from the moment it is recorded.
    func waitForRequests(_ count: Int) async throws {
        while state.withLock({ $0.held.count < count }) { await Task.yield() }
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
                case 200: return (200, Data(#"{"digest":"\#(SHA256.hex(request.httpBody ?? Data()))"}"#.utf8))
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
