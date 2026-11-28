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
/// The extension pulls before a render when one is due, waiting at most 4 seconds; the app pulls on foreground and
/// after an upload. One pull runs at a time in a process, and a second caller joins it. Any failure leaves the store
/// as it was, so the widget draws what it holds.
public actor AccountClient {
    /// What `upload` did.
    public enum Upload: Equatable, Sendable {
        /// The server already holds this payload, or there is nothing to tell it yet: no automation and no account.
        case unchanged
        /// The server acknowledged the payload, which names this many automations.
        case uploaded(automations: Int)
        /// The server refused the payload as over one of the document's limits (422), with its code. Logged, and
        /// sent again after the next change, since the digest still differs.
        case refused(code: String)
        /// There is no account and this build has no way to register one.
        case noAccount
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

    /// How long a pull before a render may take. `getTimeline` has no published limit, so the pull holds to its own,
    /// as a deadline on the whole pull, not an idle timer on the request.
    public static let renderLimit: Duration = .seconds(4)
    /// How long a pull in the app may take.
    public static let appLimit: Duration = .seconds(30)
    /// The extension pulls before a render at most this often, unless the server's `nextWrite` has passed.
    public static let ration: TimeInterval = 30 * 60
    /// A conflicting upload (409) is sent again this many times.
    static let conflictRetries = 3

    private let base: URL?
    private let engine: Engine
    private let tokens: any TokenStore
    private let state: AccountState
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    /// The pull running in this process, which a second caller joins.
    private var flight: Task<Bool, Never>?

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
    public var token: String? { state.installed ? tokens.load() : nil }

    /// Discards a token an earlier install left in the Keychain, which outlives the app while the App Group does
    /// not, and marks this install, the first time it runs. Only the app claims, from `upload`, which runs while the
    /// person uses it: so the extension never races the app's first registration, and a phone locked since its
    /// restart, whose App Group reads as empty, never loses its token.
    public func claimInstall() {
        guard !state.installed else { return }
        tokens.delete()
        state.installed = true
    }

    // MARK: The pull

    /// The extension's pull before a render. Pulls only when this install has a token and a pull is due: the last
    /// one started more than 30 minutes ago, or the time the server said it would next write has passed. Waits at
    /// most `limit`. Never fails: whatever happens, the widget then draws what the store holds.
    public func pullBeforeRender(within limit: Duration = renderLimit) async {
        // A render while a pull runs joins it, so it draws what the pull brings.
        guard base != nil, token != nil, flight != nil || isDue else { return }
        await pull(within: limit)
    }

    /// Whether the extension's ration lets a pull run now.
    package var isDue: Bool {
        let now = now()
        if let nextWrite = state.nextWrite, nextWrite <= now { return true }
        guard let last = state.lastPull else { return true }
        return now.timeIntervalSince(last) > Self.ration
    }

    /// Takes in every page of the account's changes after the watermark, or joins the pull already running in this
    /// process. Past `limit` it gives up at once and cancels the requests. Returns whether the watermark moved, and
    /// false on any failure, which it logs.
    @discardableResult public func pull(within limit: Duration = appLimit) async -> Bool {
        if let flight { return await flight.value }
        let flight = Task { await self.fly(within: limit) }
        self.flight = flight
        return await flight.value
    }

    private func fly(within limit: Duration) async -> Bool {
        defer { flight = nil }
        // Counted from the start, success or not, so a phone that cannot reach the server does not try at every render.
        state.lastPull = now()
        let work = Task { try await self.pages() }
        switch await Deadline.result(of: work, within: limit) {
        case nil:
            log.error("pull: no answer within \(limit, privacy: .public); drawing what is stored")
            return false
        case .failure(let error):
            log.error("pull failed: \(String(describing: error), privacy: .public)")
            return false
        case .success(let moved):
            return moved
        }
    }

    /// Pages from the watermark on, merged one at a time, while full pages arrive and the watermark moves (a page
    /// that stops at a held change does not move it).
    private func pages() async throws -> Bool {
        guard let base, let token else { return false }
        let start = try engine.watermark()
        var after = start
        while true {
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
            guard page.count >= RemotePage.limit, moved > after else { return moved > start }
            after = moved
        }
    }

    // MARK: The upload

    /// Sends the account's automations (`PUT /v1/automations`) when they differ from what the server last
    /// acknowledged. With no account yet, registers one with `register` first, but only once there is an automation
    /// to run. A conflict (409: another upload of the account landed meanwhile) is sent again, up to three times. A
    /// token the server no longer knows (401) is forgotten and the account registered again, once. Throws when the
    /// payload cannot be read, the server cannot be reached, or it refuses otherwise; the digest still differs, so
    /// the next change or foreground sends it again. The app makes one upload at a time.
    public func upload(register: (@Sendable () async throws -> String)?) async throws -> Upload {
        claimInstall()
        let payload = try engine.automationPayload()
        guard let base, payload.digest != state.acknowledged else { return .unchanged }
        var token = self.token
        if token == nil && payload.automations == 0 { return .unchanged }
        var registered = false
        var conflicts = 0
        while true {
            let current: String
            if let token {
                current = token
            } else {
                guard let register else {
                    log.error("upload: no account, and this build cannot register one")
                    return .noAccount
                }
                current = try await register()
                tokens.save(current)
                // A new account holds no automations, whatever the last one acknowledged.
                state.acknowledged = nil
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
                state.acknowledged = digest
                log.info("uploaded \(payload.automations, privacy: .public) automations")
                return .uploaded(automations: payload.automations)
            case 409 where conflicts < Self.conflictRetries:
                conflicts += 1
                log.info("upload conflicted with another; sending it again")
            case 401 where !registered:
                forget(current)
                token = nil
            case 422:
                let refused = Refused(data, status: 422)
                log.error("upload refused: \(refused.description, privacy: .public)")
                return .refused(code: refused.code ?? "-")
            default:
                throw Refused(data, status: response.statusCode)
            }
        }
    }

    /// Drops a token the server no longer knows, such as after the account was deleted for being idle, unless the
    /// app has saved another meanwhile. The app then registers again and uploads to the new account.
    private func forget(_ token: String) {
        guard tokens.load() == token else { return }
        log.error("the server no longer knows this account; it is registered again on the next upload")
        tokens.delete()
        state.acknowledged = nil
    }
}

// MARK: Where things are kept

/// Where the account token is kept.
public protocol TokenStore: Sendable {
    func load() -> String?
    func save(_ token: String)
    func delete()
}

/// The token in the Keychain access group the app and the extension share (`WidgieKeychainGroup`), readable from
/// the first unlock after a restart on, so the extension can pull while the phone is locked.
public struct KeychainTokens: TokenStore {
    private let group: String?
    private let service: String

    public init(group: String?, service: String = "dev.krutikpatel.widgie.account") {
        self.group = group
        self.service = service
    }

    public func load() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound { log.error("the token could not be read: \(status, privacy: .public)") }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ token: String) {
        delete()
        var item = base
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { log.error("the token could not be saved: \(status, privacy: .public)") }
    }

    public func delete() {
        SecItemDelete(base as CFDictionary)
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
/// write (the extension's ration), and the digest of the last payload the server acknowledged. Unchecked because
/// `UserDefaults` is documented as thread-safe but not marked `Sendable`.
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

    public package(set) var acknowledged: String? {
        get { defaults.string(forKey: "account.acknowledged") }
        nonmutating set { defaults.set(newValue, forKey: "account.acknowledged") }
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
    /// without waiting for it to stop, so a request that ignores cancellation cannot hold the caller.
    static func result<T: Sendable>(
        of work: Task<T, any Error>, within limit: Duration
    ) async -> Result<T, any Error>? {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let timer = Task {
                guard (try? await Task.sleep(for: limit)) != nil else { return }
                work.cancel()
                once.resume(nil)
            }
            Task {
                let result = await work.result
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
