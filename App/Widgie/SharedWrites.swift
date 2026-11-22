import WidgetEngine

/// The shared store takes no writes while the app is in the background, so iOS never finds the app holding
/// its lock while suspended (`Engine.suspend`). The app moves this with its scene phase, and a write that
/// meets the background waits here for the app to come back.
@MainActor enum SharedWrites {
    private static var suspended = false
    private static var waiting: [CheckedContinuation<Void, Never>] = []

    static func suspend() {
        suspended = true
        Engine.suspend()
    }

    static func resume() {
        Engine.resume()
        suspended = false
        let waiting = self.waiting
        self.waiting = []
        for continuation in waiting { continuation.resume() }
    }

    /// Returns once the shared store takes writes.
    static func open() async {
        guard suspended else { return }
        await withCheckedContinuation { waiting.append($0) }
    }
}
