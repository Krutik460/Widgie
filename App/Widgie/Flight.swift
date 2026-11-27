import SwiftUI
import UIKit
import WidgetEngine

/// A new widget leaving a sheet for the Widgets tab: its name, the face it shows, and where it starts in the
/// window.
struct Launch {
    let name: String
    let face: Face?
    let from: CGRect
}

/// What flies over the app, sheets included: confetti thrown up from a tile, and a tile on one smooth arc into the
/// Widgets tab, shrinking into its glyph. It is drawn in a window of its own above the app's, because a sheet
/// covers everything in the app's window while it closes. That window takes no touches, is hidden from VoiceOver,
/// and exists only while something flies.
@MainActor @Observable
final class Flights {
    struct Burst: Identifiable {
        let id: Int
        let from: CGRect
    }

    struct Flight: Identifiable {
        let id: Int
        let launch: Launch
        let to: CGRect
    }

    private(set) var bursts: [Burst] = []
    private(set) var flight: Flight?
    /// The Widgets glyph in the tab bar, in the window. The tab bar keeps it current.
    @ObservationIgnored var target = CGRect.zero

    @ObservationIgnored private var serial = 0
    @ObservationIgnored private var window: UIWindow?

    static let burstTime = 1.15
    static let flightTime = 0.48

    /// Throws confetti up and out from the top edge of `tile`.
    func burst(from tile: CGRect) {
        serial += 1
        let burst = Burst(id: serial, from: tile)
        bursts.append(burst)
        show()
        Task {
            try? await Task.sleep(for: .seconds(Self.burstTime))
            bursts.removeAll { $0.id == burst.id }
            hideWhenStill()
        }
    }

    /// Fades out the confetti in the air, as the page it rose from leaves. A tile in flight keeps going, since it
    /// lands in the tab bar, which every page shares.
    func settle() {
        withAnimation(.linear(duration: 0.12)) { bursts.removeAll() }
    }

    /// Flies `launch` into the Widgets glyph, and returns once it is there.
    func fly(_ launch: Launch) async {
        serial += 1
        flight = Flight(id: serial, launch: launch, to: target)
        show()
        try? await Task.sleep(for: .seconds(Self.flightTime))
        flight = nil
        hideWhenStill()
    }

    private func show() {
        if window == nil { window = makeWindow() }
        window?.isHidden = false
    }

    /// Lets the window go once nothing flies, which also frees the hosting controller that holds this model.
    private func hideWhenStill() {
        guard bursts.isEmpty && flight == nil else { return }
        window?.isHidden = true
        window = nil
    }

    private func makeWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            return nil
        }
        let window = PassThroughWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.accessibilityElementsHidden = true
        let host = UIHostingController(rootView: FlightLayer(flights: self))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        return window
    }
}

private final class PassThroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

/// The flight window's content, in the window's own coordinates.
private struct FlightLayer: View {
    let flights: Flights

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(flights.bursts) { burst in
                    Confetti(from: burst.from).transition(.opacity)
                }
                if let flight = flights.flight {
                    Flyer(flight: flight, width: proxy.size.width).id(flight.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The tile on its way: an ease in and out toward the glyph, lifted on a 56 point arc, shrinking until it is the
/// glyph's 22 points, and fading over the last fifth. It never leaves the screen's 8 point margins.
private struct Flyer: View {
    let flight: Flights.Flight
    let width: CGFloat

    @State private var start = Date.now

    var body: some View {
        let from = flight.launch.from
        TimelineView(.animation) { timeline in
            let k = min(1, timeline.date.timeIntervalSince(start) / Flights.flightTime)
            let eased = k < 0.5 ? 2 * k * k : 1 - pow(-2 * k + 2, 2) / 2
            let scale = 1 - (1 - 22 / max(from.width, from.height)) * pow(k, 1.65)
            let half = from.width * scale / 2
            let y = from.midY + (flight.to.midY - from.midY) * eased - 56 * sin(.pi * k)
            let x = min(max(from.midX + (flight.to.midX - from.midX) * eased, 8 + half), width - 8 - half)
            FaceTile(face: flight.launch.face, size: from.size)
                .scaleEffect(scale)
                .opacity(k < 0.8 ? 1 : 1 - (k - 0.8) / 0.2 * 0.7)
                .position(x: x, y: y)
        }
    }
}

/// Eighteen caret-shaped bars thrown up and out from a tile's top edge, which then fall away and fade, over 1.15
/// seconds.
private struct Confetti: View {
    let from: CGRect

    @State private var start = Date.now

    private static let colors: [Color] = [0x3ECF8E, 0xFFD23C, 0xFF7F8E, 0xA78BFA, 0xFF9F5A, 0x5AC8FA].map { hex in
        Color(red: Double(hex >> 16) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    private static let rise = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.1, y: 0.7), endControlPoint: UnitPoint(x: 0.3, y: 1))
    private static let fall = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.4, y: 0), endControlPoint: UnitPoint(x: 1, y: 1))

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = min(1, timeline.date.timeIntervalSince(start) / Flights.burstTime)
            Canvas { context, _ in
                for index in 0..<18 {
                    let spread = Double(index) / 17
                    let dx = (spread - 0.5) * 220 + Double(index % 3 - 1) * 18
                    let dy = -120 - Double(index % 4) * 22
                    let turn = (index % 2 == 1 ? 1.0 : -1.0) * (160 + Double(index) * 14)
                    // Up to 45 percent of the way the bar flies up and out, then it falls 150 points.
                    let up = Self.rise.value(at: min(1, t / 0.45))
                    let down = Self.fall.value(at: max(0, (t - 0.45) / 0.55))
                    let x = dx * (0.7 * up + 0.3 * down)
                    let y = dy * up + 150 * down
                    var bar = context
                    bar.opacity = t < 0.7 ? 1 : 1 - (t - 0.7) / 0.3
                    bar.translateBy(x: from.minX + from.width * (0.15 + 0.7 * spread) + 2 + x, y: from.minY + 7.5 + y)
                    bar.rotate(by: .degrees(turn * (0.5 * up + 0.5 * down)))
                    bar.fill(
                        Path(roundedRect: CGRect(x: -2, y: -7.5, width: 4, height: 15), cornerRadius: 2),
                        with: .color(Self.colors[index % 6]))
                }
            }
        }
    }
}
