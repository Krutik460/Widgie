import CryptoKit
import Foundation
import Security
import Synchronization
import WidgetEngine
import os

private let log = Logger(subsystem: "dev.krutikpatel.widgie", category: "account")

/// The account the server runs this phone's automations under (tasks/phase-3-ai-block.md, "Account and credential"):
/// its token, the pull of what the server wrote, and the upload of the automations. The app and the extension each
/// use one (`Hosting.account`). Registering stays in the app, which hands `upload` a way to register, since only the
/// app holds the App Attest key.
///
/// The extension pulls before a render when one is due, then uploads the automations when the server lacks them,
/// such as after the phone moved to another time zone while the app stayed closed: both in one flight, within 4
/// seconds. The app pulls on foreground and after an upload, and uploads after every change. One flight runs at a
/// time in a process, and a second caller joins it. Any failure leaves the store as it was, so the widget draws what
/// it holds.
public actor AccountClient {
    /// Gets a new account token. The app's, on its registration path.
    public typealias Register = @Sendable () async throws -> String

    /// What `upload` did.
    public enum Upload: Equatable, Sendable {
        /// The server already holds this payload, or there is nothing to tell it yet: no automation and no account.
        case unchanged
        /// The server acknowledged the payload, which names this many automations.
        case uploaded(automations: Int)
        /// The server refused the payload itself (400, 413, 415, or 422), with its code. Remembered with the
        /// payload's digest, so the same payload is not sent again; the next change that moves it is.
        case refused(code: String)
        /// There is no account and this build has no way to register one.
        case noAccount
        /// There is no account, and registering waits because the last attempt failed: until the first foreground
        /// at or after this time.
        case registrationWaits(until: Date)
    }

    /// The server refused a call, or answered with what this build cannot read.
    public struct Refused: Error, CustomStringConvertible {
        public let status: Int
        /// The Worker's code, such as `conflict` or `too-many-on-widget`, when it sent one.
        public let code: String?
        public let line: String
        public var description: String { "HTTP \(status) \(code ?? "-"): \(line)" }

        public init(status: Int, code: String?, line: String) {
            self.status = status
            self.code = code
            self.line = line
        }

        /// The Worker's `{error, code}` body.
        public init(_ body: Data, status: Int) {
            let fields = try? JSONDecoder().decode([String: String].self, from: body)
            self.init(status: status, code: fields?["code"], line: fields?["error"] ?? "no reply")
        }
    }

    /// How long the extension's flight before a render may take. `getTimeline` has no published limit, so the
    /// flight holds to its own. It is hard for the network: past it the requests are cancelled and the render goes
    /// on without waiting for them to notice. It is not hard for a merge already running: `Engine.receive` runs on
    /// this actor, which the flight must enter again to return, so a merge in progress at the deadline finishes
    /// first. A merge is one short transaction, and returning in the middle of it could let iOS suspend the
    /// extension while it holds the shared database's write lock.
    public static let renderLimit: Duration = .seconds(4)
    /// How long a pull in the app may take.
    public static let appLimit: Duration = .seconds(30)
    /// The extension pulls before a render at most this often, unless the server's `nextWrite` has passed since
    /// the last pull started.
    public static let ration: TimeInterval = 30 * 60
    /// A conflicting upload (409) is sent again this many times.
    static let conflictRetries = 3
    /// What the server answers a payload it refuses for what it holds, which sending it again cannot change.
    static let payloadRefusals: Set<Int> = [400, 413, 415, 422]
    /// After a failed registration the next one waits this long, doubling with each failure in a row up to
    /// `registrationWaitMost`, and then for a foreground: a failing `/v1/account` never makes a new App Attest key
    /// at every change.
    public static let registrationWait: TimeInterval = 60
    public static let registrationWaitMost: TimeInterval = 6 * 3600

    private let base: URL?
    private let engine: Engine
    private let tokens: any TokenStore
    private let state: AccountState
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    /// The flight running in this process, which a second caller joins.
    private var flight: Task<Bool, Never>?
    /// How many callers wait on `flight` beside the one that started it. Tests wait on it.
    package private(set) var joiners = 0

    /// `base` is the Worker; with none, nothing is pulled or uploaded.
    public init(
        base: URL?, engine: Engine, tokens: any TokenStore, state: AccountState,
        transport: any HTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.base = base
        self.engine = engine
        self.tokens = tokens
        self.state = state
        self.transport = transport
        self.now = now
    }

    /// This install's account token. Nil before the app registered one, before the app first ran after an install
    /// (`claimInstall`), and before the phone's first unlock since a restart, when neither the Keychain item nor the
    /// App Group can be read.
    public var token: String? {
        guard state.installed else { return nil }
        return try? tokens.load()
    }

    /// Discards a token an earlier install left in the Keychain, which outlives the app while the App Group does
    /// not, and marks this install, the first time it runs. Only the app claims, from `upload`, which runs while the
    /// person uses it: so the extension never races the app's first registration, and a phone locked since its
    /// restart, whose App Group reads as empty, never loses its token.
    public func claimInstall() {
        guard !state.installed else { return }
        tokens.delete()
        state.installed = true
    }

    // MARK: The flight

    /// The extension's flight before a render. Runs only when this install has a token and a pull is due (`isDue`):
    /// pulls, then uploads the automations when the server lacks them, never registering. Waits at most `limit`.
    /// Never fails: whatever happens, the widget then draws what the store holds. The app never calls this, so a
    /// render never joins one of the app's pulls.
    public func pullBeforeRender(within limit: Duration = renderLimit) async {
        // A render while a flight runs joins it, so it draws what the pull brings.
        guard base != nil, token != nil, flight != nil || isDue else { return }
        _ = await join(within: limit, upload: true)
    }

    /// Whether the extension's ration lets a pull run now: the last pull started more than 30 minutes ago, or the
    /// time the server said it would next write has passed since then.
    package var isDue: Bool {
        let now = now()
        // Never pulled, or the clock moved back past the last pull, which would otherwise hold every pull until the
        // clock caught up with it.
        guard let last = state.lastPull, last <= now else { return true }
        if now.timeIntervalSince(last) > Self.ration { return true }
        // A pull that succeeds moves `nextWrite` past its own start (the server keeps it at least five minutes ahead),
        // and one that fails leaves it before, so a failing pull after `nextWrite` waits for the ration instead of
        // running at every render.
        guard let nextWrite = state.nextWrite else { return false }
        return last < nextWrite && nextWrite <= now
    }

    /// Takes in every page of the account's changes after the watermark, or joins the flight already running in
    /// this process. Past `limit` it gives up and cancels the requests. Returns whether the watermark moved; a
    /// failure, which it logs, leaves it where it was.
    @discardableResult public func pull(within limit: Duration = appLimit) async -> Bool {
        await join(within: limit, upload: false)
    }

    private func join(within limit: Duration, upload: Bool) async -> Bool {
        if let flight {
            joiners += 1
            defer { joiners -= 1 }
            return await flight.value
        }
        let flight = Task { await self.fly(within: limit, upload: upload) }
        self.flight = flight
        return await flight.value
    }

    private func fly(within limit: Duration, upload: Bool) async -> Bool {
        defer { flight = nil }
        // Counted from the start, success or not, so a phone that cannot reach the server tries at most once each
        // 30 minutes, and once after each `nextWrite` (`isDue`).
        state.lastPull = now()
        let start = try? engine.watermark()
        let work = Task {
            do {
                try await self.pages()
            } catch {
                log.error("pull failed: \(String(describing: error), privacy: .public)")
            }
            if upload && !Task.isCancelled { await self.uploadFromExtension() }
        }
        if await Deadline.result(of: work, within: limit) == nil {
            log.error("no answer within \(limit, privacy: .public); drawing what is stored")
        }
        guard let start, let end = try? engine.watermark() else { return false }
        return end > start
    }

    /// Pages from the watermark on, each merged as it arrives, until one comes back empty or leaves the watermark
    /// where it was (it stopped at a held change). The phone never assumes the server's page size.
    private func pages() async throws {
        guard let base, let token else { return }
        var after = try engine.watermark()
        while true {
            try Task.checkCancellation()
            var request = URLRequest(
                url: base.appending(path: "v1/changes").appending(queryItems: [
                    URLQueryItem(name: "after", value: String(after))
                ]))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await transport.send(request)
            try Task.checkCancellation()
            guard response.statusCode == 200 else {
                let refused = Refused(data, status: response.statusCode)
                if refused.code == "bad-token" { forget(token) }
                throw refused
            }
            let page = try RemotePage(json: data)
            try engine.receive(page, at: now())
            state.nextWrite = page.nextWrite
            let moved = try engine.watermark()
            guard page.count > 0, moved > after else { return }
            after = moved
        }
    }

    /// The extension's upload after its pull: only with a token, and never registering, which App Attest keeps to
    /// the app. Logs what it did.
    private func uploadFromExtension() async {
        guard token != nil else { return }
        do {
            let result = try await upload(try engine.automationPayload(), register: nil, foreground: false)
            if case .uploaded(let automations) = result {
                log.info("the extension uploaded \(automations, privacy: .public) automations")
            }
        } catch {
            log.error("the extension's upload failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: The upload

    /// The app's upload: sends the account's automations (`PUT /v1/automations`) unless the server acknowledged
    /// this payload for this token or refused it. With no account yet, registers one with `register` first, but
    /// only once there is an automation to run, and after a failed registration only on a foreground once its wait
    /// has passed (`foreground` says this upload is one). A conflict (409: another upload of the account landed
    /// meanwhile) is sent again, up to three times. A token the server no longer knows (401) is forgotten and the
    /// account registered again, once. After a 200 the payload is read again, and sent too when a commit moved it
    /// meanwhile. Throws when the payload or the token cannot be read, the token cannot be saved, the server cannot
    /// be reached, or it refuses otherwise; the next change or foreground sends it again. The app makes one upload
    /// at a time.
    public func upload(register: Register?, foreground: Bool = false) async throws -> Upload {
        claimInstall()
        return try await upload(try engine.automationPayload(), register: register, foreground: foreground)
    }

    private func upload(_ payload: AutomationPayload, register: Register?, foreground: Bool) async throws -> Upload {
        guard let base else { return .unchanged }
        if let refused = state.refused, refused.digest == payload.digest { return .refused(code: refused.code) }
        // Throws when the Keychain cannot be read, so a token that is there but unreadable is never replaced.
        var token = try tokens.load()
        if let token, state.acknowledged == Acknowledgement(digest: payload.digest, token: token) { return .unchanged }
        if token == nil && payload.automations == 0 { return .unchanged }
        var registered = false
        var conflicts = 0
        while true {
            let current: String
            if let token {
                current = token
            } else {
                guard let register else {
                    log.error("upload: no account, and this process cannot register one")
                    return .noAccount
                }
                if let until = registrationWait(foreground: foreground) {
                    log.info(
                        "upload: registering waits after a failure, for a foreground from \(until, privacy: .public)")
                    return .registrationWaits(until: until)
                }
                // A token that could not be saved would leave the server an account nobody can reach, so it fails
                // the registration, and the next one waits like any other.
                do {
                    current = try await register()
                    try tokens.save(current)
                } catch {
                    let failures = (state.registrationFailure?.count ?? 0) + 1
                    state.registrationFailure = (failures, now())
                    log.error("registering failed (\(failures, privacy: .public) in a row)")
                    throw error
                }
                state.registrationFailure = nil
                registered = true
                log.info("registered an account")
            }
            token = current
            var request = URLRequest(url: base.appending(path: "v1/automations"), timeoutInterval: 30)
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(current)", forHTTPHeaderField: "Authorization")
            request.httpBody = payload.json
            let (data, response) = try await transport.send(request)
            switch response.statusCode {
            case 200:
                let digest = (try? JSONDecoder().decode([String: String].self, from: data))?["digest"]
                guard digest == payload.digest else {
                    throw Refused(status: 200, code: nil, line: "the server acknowledged another payload")
                }
                state.acknowledged = Acknowledgement(digest: payload.digest, token: current)
                log.info("uploaded \(payload.automations, privacy: .public) automations")
                let sent = Upload.uploaded(automations: payload.automations)
                // The server keeps the last upload it took, and the other process may have read its payload before
                // a commit that this one's landed after: whichever process lands last sends the newest payload.
                let latest = try engine.automationPayload()
                guard latest.digest != payload.digest else { return sent }
                let next = try await upload(latest, register: register, foreground: foreground)
                return next == .unchanged ? sent : next
            case 409 where conflicts < Self.conflictRetries:
                conflicts += 1
                log.info("upload conflicted with another; sending it again")
            case 401 where !registered:
                forget(current)
                token = nil
            case let status where Self.payloadRefusals.contains(status):
                let refused = Refused(data, status: status)
                let code = refused.code ?? "http-\(status)"
                state.refused = (payload.digest, code)
                log.error("upload refused, not sent again until it changes: \(refused.description, privacy: .public)")
                return .refused(code: code)
            default:
                throw Refused(data, status: response.statusCode)
            }
        }
    }

    /// When registering may run again after the last failure, or nil when it may run now: on a foreground once the
    /// wait has passed. A clock moved back before the failure does not hold registering for the time it moved.
    private func registrationWait(foreground: Bool) -> Date? {
        guard let failure = state.registrationFailure else { return nil }
        let doublings = Double(min(max(failure.count - 1, 0), 30))
        let until = failure.at.addingTimeInterval(
            min(Self.registrationWaitMost, Self.registrationWait * pow(2, doublings)))
        let now = now()
        if foreground && (until <= now || failure.at > now) { return nil }
        return until
    }

    /// Drops a token the server no longer knows, such as after the account was deleted for being idle, unless the
    /// app has saved another meanwhile. The app then registers again and uploads to the new account.
    private func forget(_ token: String) {
        log.error("the server no longer knows this account; it is registered again on the next upload")
        tokens.delete(token)
    }
}

/// The last payload the server acknowledged: its digest, and which token it was sent with, so a payload one
/// account holds is never taken as held by another, and a lost token is replaced whatever the server holds.
public struct Acknowledgement: Equatable, Sendable {
    public let digest: String
    /// The SHA-256 of the token it was sent with, as lowercase hex.
    public let fingerprint: String

    init(digest: String, token: String) {
        self.init(digest: digest, fingerprint: tokenFingerprint(token))
    }

    fileprivate init(digest: String, fingerprint: String) {
        self.digest = digest
        self.fingerprint = fingerprint
    }
}

/// A token's SHA-256 as lowercase hex: what the Keychain item and the acknowledgement keep to tell tokens apart
/// without keeping the token.
func tokenFingerprint(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
}

// MARK: Where things are kept

/// Where the account token is kept.
public protocol TokenStore: Sendable {
    /// The token, or nil when there is none. Throws when the store cannot be read, such as before the first unlock.
    func load() throws -> String?
    /// Keeps `token` in place of any other. Throws when it could not.
    func save(_ token: String) throws
    /// Deletes the token, whichever it is.
    func delete()
    /// Deletes `token` only if it is still the one kept.
    func delete(_ token: String)
}

/// The token in the Keychain access group the app and the extension share (`WidgieKeychainGroup`), readable from
/// the first unlock after a restart on, so the extension can pull while the phone is locked. The item also keeps
/// the token's fingerprint (`kSecAttrGeneric`), so `delete(_:)` deletes it only while it holds that token, in one
/// Keychain call: the Keychain cannot match an item by its data. An item an earlier build saved without one is
/// compared, then deleted.
public struct KeychainTokens: TokenStore {
    /// A Keychain call failed with this status.
    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { "Keychain status \(status)" }
    }

    private let group: String?
    private let service: String

    public init(group: String?, service: String = "dev.krutikpatel.widgie.account") {
        self.group = group
        self.service = service
    }

    public func load() throws -> String? {
        var query = base
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            log.error("the token could not be read: \(status, privacy: .public)")
            throw Failure(status: status)
        }
        return token
    }

    /// Updates the item, or adds it when there is none, so there is never a moment without one.
    public func save(_ token: String) throws {
        let fields: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrGeneric as String: Data(tokenFingerprint(token).utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(base as CFDictionary, fields as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(base.merging(fields) { $1 } as CFDictionary, nil)
            // The other process added one meanwhile: this one is the newer.
            if status == errSecDuplicateItem { status = SecItemUpdate(base as CFDictionary, fields as CFDictionary) }
        }
        guard status == errSecSuccess else {
            log.error("the token could not be saved: \(status, privacy: .public)")
            throw Failure(status: status)
        }
    }

    public func delete() {
        SecItemDelete(base as CFDictionary)
    }

    public func delete(_ token: String) {
        var query = base
        query[kSecAttrGeneric as String] = Data(tokenFingerprint(token).utf8)
        guard SecItemDelete(query as CFDictionary) == errSecItemNotFound else { return }
        // An item saved before it kept a fingerprint can only be compared, then deleted.
        if (try? load()) == token { delete() }
    }

    private var base: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "token",
        ]
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }
}

/// What the app and the extension remember about the account, in the App Group's defaults, which both read and
/// write: whether this install claimed the Keychain, when the last pull started and when the server next expects to
/// write (the extension's ration), the last payload the server acknowledged and the last it refused, and the
/// registration failures in a row. Unchecked because `UserDefaults` is documented as thread-safe but not marked
/// `Sendable`.
public struct AccountState: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    package var installed: Bool {
        get { defaults.bool(forKey: "account.installed") }
        nonmutating set { defaults.set(newValue, forKey: "account.installed") }
    }

    package var lastPull: Date? {
        get { defaults.object(forKey: "account.lastPull") as? Date }
        nonmutating set { defaults.set(newValue, forKey: "account.lastPull") }
    }

    package var nextWrite: Date? {
        get { defaults.object(forKey: "account.nextWrite") as? Date }
        nonmutating set { defaults.set(newValue, forKey: "account.nextWrite") }
    }

    /// One dictionary, so the other process never reads a digest with another token's fingerprint.
    public package(set) var acknowledged: Acknowledgement? {
        get {
            guard let fields = defaults.dictionary(forKey: "account.acknowledgement") as? [String: String],
                let digest = fields["digest"], let fingerprint = fields["fingerprint"]
            else { return nil }
            return Acknowledgement(digest: digest, fingerprint: fingerprint)
        }
        nonmutating set {
            defaults.set(
                newValue.map { ["digest": $0.digest, "fingerprint": $0.fingerprint] }, forKey: "account.acknowledgement"
            )
        }
    }

    /// The digest of the last payload the server refused for what it holds, and its code.
    package var refused: (digest: String, code: String)? {
        get {
            guard let fields = defaults.dictionary(forKey: "account.refused") as? [String: String],
                let digest = fields["digest"], let code = fields["code"]
            else { return nil }
            return (digest, code)
        }
        nonmutating set {
            defaults.set(newValue.map { ["digest": $0.digest, "code": $0.code] }, forKey: "account.refused")
        }
    }

    /// How many registrations failed in a row, and when the last did.
    package var registrationFailure: (count: Int, at: Date)? {
        get {
            guard let fields = defaults.dictionary(forKey: "account.registrationFailure"),
                let count = fields["count"] as? Int, let at = fields["at"] as? Date
            else { return nil }
            return (count, at)
        }
        nonmutating set {
            let fields: [String: Any]? = newValue.map { ["count": $0.count, "at": $0.at] }
            defaults.set(fields, forKey: "account.registrationFailure")
        }
    }
}

// MARK: HTTP

/// Sends one request. The app and the extension use `URLSessionTransport`; tests script the server.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// A wait with a hard end.
enum Deadline {
    /// `work`'s result, or nil once `limit` passes first. Then the work is cancelled and this returns at once,
    /// without waiting for it to stop, so a request that ignores cancellation cannot hold the caller. (A caller
    /// isolated to the actor the work runs on still resumes only when the actor is free: see `renderLimit`.)
    static func result<T: Sendable>(of work: Task<T, Never>, within limit: Duration) async -> T? {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let timer = Task {
                guard (try? await Task.sleep(for: limit)) != nil else { return }
                work.cancel()
                once.resume(nil)
            }
            Task {
                let result = await work.value
                timer.cancel()
                once.resume(result)
            }
        }
    }

    /// A continuation the first of two racers resumes.
    private final class Once<Value: Sendable>: Sendable {
        private let waiting: Mutex<CheckedContinuation<Value, Never>?>

        init(_ continuation: CheckedContinuation<Value, Never>) { waiting = Mutex(continuation) }

        func resume(_ value: Value) {
            waiting.withLock { $0.take() }?.resume(returning: value)
        }
    }
}
