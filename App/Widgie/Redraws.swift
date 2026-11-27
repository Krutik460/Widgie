import Foundation
import UIKit

/// The wall clock faces are drawn at, and a wait for a moment on it. Tests pass a clock they move by hand.
struct FaceClock: Sendable {
    var now: @Sendable () -> Date
    /// Returns at `date`, or throws when the task is cancelled first.
    var sleep: @Sendable (_ until: Date) async throws -> Void

    static let system = FaceClock(
        now: { .now }, sleep: { date in try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow))) })
}

/// Draws faces again at the moment they next change, which the engine tells with each face, while the app is in
/// the foreground. Entering the background stops the wait, and coming back starts it again, drawing at once when
/// the moment passed meanwhile. A significant time change (midnight, a new time zone, the clock set by hand)
/// draws at once.
@MainActor final class Redraws {
    let clock: FaceClock
    /// What draws the faces again. The owner sets it once it can refer to itself.
    var redraw: @MainActor () -> Void = {}

    private let center: NotificationCenter
    private var due: Date?
    private var waiting: Task<Void, Never>?
    private var foreground: Bool
    private var observers: [any NSObjectProtocol] = []

    init(clock: FaceClock = .system, center: NotificationCenter = .default) {
        self.clock = clock
        self.center = center
        foreground = UIApplication.shared.applicationState != .background
        observe(UIApplication.didEnterBackgroundNotification) { redraws in
            redraws.foreground = false
            redraws.wait()
        }
        observe(UIApplication.willEnterForegroundNotification) { redraws in
            redraws.foreground = true
            redraws.wait()
        }
        observe(UIApplication.significantTimeChangeNotification) { redraws in
            redraws.redraw()
        }
    }

    isolated deinit {
        waiting?.cancel()
        for observer in observers { center.removeObserver(observer) }
    }

    /// Draws again at `date`, in place of any moment set before, or never when it is nil.
    func schedule(_ date: Date?) {
        due = date
        wait()
    }

    private func wait() {
        waiting?.cancel()
        waiting = nil
        guard foreground, let date = due else { return }
        let clock = clock
        waiting = Task { [weak self] in
            do {
                try await clock.sleep(date)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            waiting = nil
            due = nil
            redraw()
        }
    }

    private func observe(_ name: Notification.Name, _ act: @escaping @MainActor (Redraws) -> Void) {
        observers.append(
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    act(self)
                }
            })
    }
}
