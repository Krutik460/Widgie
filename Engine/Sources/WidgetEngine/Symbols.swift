import Foundation
import SwiftUI
import Synchronization

/// Whether an SF Symbol exists on this platform. SwiftUI cannot say, so this asks the image class that
/// SwiftUI re-exports. It loads no view, which is what a widget forbids. Answers are cached for the
/// process, since validation runs on every render.
enum Symbols {
    private static let known = Mutex<[String: Bool]>([:])

    static func exist(_ name: String) -> Bool {
        if let answer = known.withLock({ $0[name] }) { return answer }
        #if os(macOS)
            let answer = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #else
            let answer = UIImage(systemName: name) != nil
        #endif
        known.withLock { $0[name] = answer }
        return answer
    }
}
