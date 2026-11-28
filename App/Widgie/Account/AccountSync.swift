import Foundation
import OSLog
import UIKit
import WidgetHosting

private let log = Logger(subsystem: "dev.krutikpatel.widgie", category: "account")

/// Keeps the server's copy of the account's automations current and takes in what the server wrote, while the app is
/// open (tasks/phase-3-ai-block.md, P4). With the app closed, the extension uploads after its pull instead.
///
/// - Uploads after every write the shared store commits (`Hosting.didCommit`), so every change that moves the
///   payload is sent, whichever it was: a save, a refinement, a template added, a delete, a restore, a roll back, a
///   bind. Also on foreground, and when the time zone or the clock changes. `AccountClient.upload` sends only when
///   the digest differs from the last one the server acknowledged for this token, and never sends again a payload
///   the server refused, so a tap's commit sends nothing. One upload runs at a time, and a change during one uploads
///   again after it. After a failed registration only a foreground registers, once its wait has passed, so a
///   failing `/v1/account` never makes a new App Attest key at every change.
/// - Pulls on foreground, and every 5 seconds for a minute after an upload that names an automation. Every such
///   upload changed an automation the server runs, and the server writes its next row at once (a new schedule task
///   is due at once, since every lead is longer than its period), so the row lands within that minute.
@MainActor final class AccountSync {
    static let pollEvery: Duration = .seconds(5)
    static let pollFor: Duration = .seconds(60)

    /// Whether the app runs as the host of its unit tests, which make syncs of their own against a scripted Worker:
    /// the app's own would reach the dev Worker with the simulator's account. Xcode names the test bundle in the
    /// host's environment.
    static func hostedByTests(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    }

    private let account: AccountClient
    private let register: AccountClient.Register?
    private let sleep: @Sendable (Duration) async throws -> Void
    /// Runs after a pull took something in, so the feed draws it.
    private let pulled: @MainActor () -> Void
    private var uploading: Task<Void, Never>?
    private var again = false
    /// A foreground asked for an upload that has not started yet.
    private var foregrounded = false
    /// The foreground's pull.
    private var pulling: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    /// Counts polls, so one that ends never clears the one that replaced it.
    private var polls = 0
    private var observers: [any NSObjectProtocol] = []
    private let center: NotificationCenter

    init(
        account: AccountClient = Hosting.account,
        register: AccountClient.Register? = Registration.configuredRegister,
        center: NotificationCenter = .default,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        pulled: @escaping @MainActor () -> Void = {}
    ) {
        self.account = account
        self.register = register
        self.center = center
        self.sleep = sleep
        self.pulled = pulled
        let moves: [Notification.Name] = [
            Hosting.didCommit, .NSSystemTimeZoneDidChange, UIApplication.significantTimeChangeNotification,
        ]
        // A post waits for a block on another queue to finish, so by the time a commit returns, its upload started.
        observers = moves.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let zone = notification.name != Hosting.didCommit
                MainActor.assumeIsolated {
                    // The engine reads the current zone, which Foundation caches until told it moved.
                    if zone { NSTimeZone.resetSystemTimeZone() }
                    self?.changed()
                }
            }
        }
    }

    isolated deinit {
        for observer in observers { center.removeObserver(observer) }
        uploading?.cancel()
        pulling?.cancel()
        polling?.cancel()
    }

    /// The app came to the foreground: send what the server lacks, registering again if the last attempt failed
    /// and its wait has passed, and take in what it wrote.
    func foreground() {
        changed(foreground: true)
        guard pulling == nil else { return }
        pulling = Task {
            if await account.pull() { pulled() }
            pulling = nil
        }
    }

    /// The app went to the background, where it writes nothing, so it stops asking.
    func background() {
        polling?.cancel()
        polls += 1
        polling = nil
    }

    /// Something may have moved the payload: uploads it when it differs from what the server acknowledged.
    /// `foreground` says the app just came to the foreground, which lets a failed registration run again.
    func changed(foreground: Bool = false) {
        if foreground { foregrounded = true }
        guard uploading == nil else {
            again = true
            return
        }
        uploading = Task {
            repeat {
                again = false
                let foreground = foregrounded
                foregrounded = false
                await upload(foreground: foreground)
            } while again
            uploading = nil
        }
    }

    /// Returns once no upload, foreground pull, or pull after an upload is running. Tests wait on it.
    func settled() async {
        while let running = uploading ?? pulling ?? polling { await running.value }
    }

    private func upload(foreground: Bool) async {
        do {
            switch try await account.upload(register: register, foreground: foreground) {
            case .uploaded(let automations) where automations > 0:
                poll()
            case .registrationWaits(let until):
                log.info("registering waits for a foreground from \(until, privacy: .public)")
            default:
                break
            }
        } catch {
            log.error("upload failed, sent again on the next change or foreground: \(error, privacy: .public)")
        }
    }

    private func poll() {
        polling?.cancel()
        polls += 1
        let poll = polls
        polling = Task {
            defer { if polls == poll { polling = nil } }
            var waited = Duration.zero
            while waited < Self.pollFor {
                do {
                    try await sleep(Self.pollEvery)
                } catch {
                    return
                }
                waited += Self.pollEvery
                if await account.pull() { pulled() }
            }
        }
    }
}
