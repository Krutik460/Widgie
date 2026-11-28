import Foundation
import OSLog
import UIKit
import WidgetHosting

private let log = Logger(subsystem: "dev.krutikpatel.widgie", category: "account")

/// Keeps the server's copy of the account's automations current and takes in what the server wrote, while the app is
/// open (tasks/phase-3-ai-block.md, P4).
///
/// - Uploads after every write the shared store commits (`Hosting.didCommit`), so every change that moves the
///   payload is sent, whichever it was: a save, a refinement, a template added, a delete, a restore, a roll back, a
///   bind. Also on foreground, and when the time zone or the clock changes. `AccountClient.upload` sends only when
///   the digest differs from the last one the server acknowledged, so a tap's commit sends nothing. One upload runs
///   at a time, and a change during one uploads again after it.
/// - Pulls on foreground, and every 5 seconds for a minute after an upload that names an automation. Every such
///   upload changed an automation the server runs, and the server writes its next row at once (a new schedule task
///   is due at once, since every lead is longer than its period), so the row lands within that minute.
@MainActor final class AccountSync {
    static let pollEvery: Duration = .seconds(5)
    static let pollFor: Duration = .seconds(60)

    private let account: AccountClient
    private let register: (@Sendable () async throws -> String)?
    private let sleep: @Sendable (Duration) async throws -> Void
    /// Runs after a pull took something in, so the feed draws it.
    private let pulled: @MainActor () -> Void
    private var uploading: Task<Void, Never>?
    private var again = false
    private var polling: Task<Void, Never>?
    /// Counts polls, so one that ends never clears the one that replaced it.
    private var polls = 0
    private var observers: [any NSObjectProtocol] = []
    private let center: NotificationCenter

    init(
        account: AccountClient = Hosting.account,
        register: (@Sendable () async throws -> String)? = Registration.configuredRegister,
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
        polling?.cancel()
    }

    /// The app came to the foreground: send what the server lacks, and take in what it wrote.
    func foreground() {
        changed()
        Task {
            if await account.pull() { pulled() }
        }
    }

    /// The app went to the background, where it writes nothing, so it stops asking.
    func background() {
        polling?.cancel()
        polls += 1
        polling = nil
    }

    /// Something may have moved the payload: uploads it when it differs from what the server acknowledged.
    func changed() {
        guard uploading == nil else {
            again = true
            return
        }
        uploading = Task {
            repeat {
                again = false
                await upload()
            } while again
            uploading = nil
        }
    }

    /// Returns once no upload or pull after one is running. Tests wait on it.
    func settled() async {
        while let running = uploading ?? polling { await running.value }
    }

    private func upload() async {
        do {
            if case .uploaded(let automations) = try await account.upload(register: register), automations > 0 {
                poll()
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
