import SwiftUI

/// The ground of every screen: Widgie's sky. By day a soft blue gradient with two clouds drifting high up; at night
/// (dark mode) the dusk gradient with twinkling stars and a crescent moon top right. Clouds drift and stars twinkle
/// only without Reduce Motion.
struct Sky: View {
    /// Whether the moon shows. It steps out of the way while the page scrolls under it.
    var moon = true
    /// Whether it stops drifting and twinkling, as under a full screen cover with a sky of its own.
    var still = false

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func moonShown(scrolled offset: CGFloat) -> Bool { offset <= 24 }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    stops: [
                        .init(color: Palette.skyTop, location: 0),
                        .init(color: Palette.skyMiddle, location: night ? 0.5 : 0.45),
                        .init(color: Palette.skyBottom, location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion || still)) { timeline in
                    let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                    Canvas { context, size in
                        if night {
                            Self.stars(in: &context, size: size, time: time)
                        } else {
                            Self.clouds(in: &context, size: size, time: time)
                        }
                    }
                }
                if night {
                    Moon()
                        .frame(width: 22, height: 22)
                        .opacity(moon ? 0.85 : 0)
                        .animation(.easeOut(duration: 0.45), value: moon)
                        .padding(.top, proxy.safeAreaInsets.top + 4)
                        .padding(.trailing, 28)
                        .frame(maxWidth: .infinity, alignment: .topTrailing)
                }
            }
            .ignoresSafeArea()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var night: Bool { scheme == .dark }

    /// Two soft clouds crossing the top of the screen, 90 and 120 seconds a pass, already part way across.
    private static func clouds(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        context.opacity = 0.5
        context.addFilter(.blur(radius: 4))
        for (width, top, period, start) in [(150.0, 56.0, 90.0, 30.0), (110, 150, 120, 80)] {
            let progress = ((time + start) / period).truncatingRemainder(dividingBy: 1)
            let x = -180 + (size.width + 198) * progress
            let unit = width / 100
            for (cx, cy, rx, ry) in [(30.0, 30.0, 26.0, 12.0), (52, 22, 22, 17), (72, 30, 22, 11)] {
                let rect = CGRect(
                    x: x + (cx - rx) * unit, y: top + (cy - ry) * unit, width: 2 * rx * unit, height: 2 * ry * unit)
                context.fill(Path(ellipseIn: rect), with: .color(.white))
            }
        }
    }

    /// 26 stars over the top 40 percent of the screen, fading out over its lower half, each twinkling every 3.4
    /// seconds at its own phase.
    private static func stars(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let area = size.height * 0.4
        let across = size.width / 402
        for index in 0..<26 {
            let x = (Double((index * 47) % 392) + 5) * across
            let y = Double((index * 61) % 320) + 48
            let fade = y < area / 2 ? 1 : max(0, 1 - (y - area / 2) / (area / 2))
            guard fade > 0 else { continue }
            let phase = ((time + Double(index % 9) * 0.38) / 3.4).truncatingRemainder(dividingBy: 1)
            let dim = (1 - cos(2 * .pi * phase)) / 2
            let rest = 0.5 + Double(index % 4) * 0.15
            let side = 2.5 * (1 - 0.5 * dim)
            context.fill(
                Path(ellipseIn: CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side)),
                with: .color(Palette.moon.opacity((rest + (0.2 - rest) * dim) * fade)))
        }
    }
}

/// How many full screen covers hide the app's own sky, each with a sky of its own.
@MainActor @Observable
final class SkyCovers {
    var count = 0
}

extension View {
    /// Marks this view as hiding the app's own sky while it shows, as a full screen cover does, so the sky
    /// underneath stops animating. A cover keeps the presenting views alive and never tells them they disappeared.
    func coversSky() -> some View {
        modifier(SkyCover())
    }
}

private struct SkyCover: ViewModifier {
    @Environment(SkyCovers.self) private var skyCovers: SkyCovers?

    func body(content: Content) -> some View {
        content
            .onAppear { skyCovers?.count += 1 }
            .onDisappear { skyCovers?.count -= 1 }
    }
}

/// The crescent moon: one circle with another taken out of its upper right, glowing softly.
private struct Moon: View {
    var body: some View {
        Canvas { context, size in
            let unit = size.width / 24
            func circle(_ x: Double, _ y: Double, _ radius: Double) -> Path {
                Path(
                    ellipseIn: CGRect(
                        x: (x - radius) * unit, y: (y - radius) * unit, width: 2 * radius * unit,
                        height: 2 * radius * unit))
            }
            context.fill(circle(15.42, 12, 9.5).subtracting(circle(18.5, 10.9, 8.92)), with: .color(Palette.moon))
        }
        .shadow(color: Palette.moon.opacity(0.35), radius: 7)
    }
}
