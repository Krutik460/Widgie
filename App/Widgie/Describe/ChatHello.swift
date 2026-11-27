import SwiftUI

/// Make with nothing in it yet: what to do, Widgie asking, and three ideas from the templates to start from.
struct Hello: View {
    let ideas: [Template.Suggestion]
    /// Widgie leans toward the composer while you type.
    let leaning: Bool
    let send: (String) -> Void

    @State private var risen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.pageHidden) private var pageHidden
    @Environment(\.colorScheme) private var scheme

    private static let greeting = "Hi! What should we make today?"

    private func widgie(size: CGFloat, grounded: Bool = true) -> some View {
        Caret(pose: .lean(.left), size: size, grounded: grounded)
            .rotationEffect(.degrees(leaning && !reduceMotion ? -6 : 0), anchor: Caret.foot(.lean(.left)))
            .animation(.easeOut(duration: 0.22), value: leaning)
            .accessibilityHidden(true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Say it in your own words")
                    .font(size: 14, weight: .semibold, relativeTo: .subheadline)
                    .foregroundStyle(Palette.secondary)
                Text("Make")
                    .display(size: 40)
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.top, 6)
            Spacer(minLength: 8).frame(maxHeight: 40)
            // At the accessibility text sizes the bubble takes the row, so its words have room, and Widgie stands under it.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .trailing, spacing: 0) {
                    Bubble(words: Self.greeting, tail: .down, voice: pageHidden ? .silent : .low)
                    widgie(size: 140).padding(.trailing, 24)
                }
                .padding(.top, 12)
            } else {
                stage
            }
            Spacer(minLength: 12)
            if !ideas.isEmpty {
                Text("Or start from one of these")
                    .font(size: 14, weight: .semibold, relativeTo: .subheadline)
                    .foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 12)
                VStack(spacing: 10) {
                    ForEach(Array(ideas.enumerated()), id: \.element.title) { index, idea in
                        IdeaCard(idea: idea) { send(idea.title) }
                            .opacity(risen || reduceMotion ? 1 : 0)
                            .offset(y: risen || reduceMotion ? 0 : 14)
                            .animation(
                                .spring(duration: 0.42, bounce: 0.2).delay(0.08 + Double(index) * 0.05), value: risen)
                    }
                }
            }
        }
        .onAppear { risen = true }
    }
}

extension Hello {
    /// The prototype's stage, measured from the column's trailing edge: Widgie's foot 72 points in and 206 down on a
    /// soft shadow, and the bubble ending 138 points in, at most 212 wide, so the greeting breaks after "make".
    fileprivate var stage: some View {
        let foot = Caret.sole(.lean(.left))
        let size: CGFloat = 192
        return ZStack(alignment: .topTrailing) {
            Ellipse()
                .fill(
                    EllipticalGradient(
                        colors: [Self.shadow(scheme), .clear], startRadiusFraction: 0, endRadiusFraction: 0.5)
                )
                .frame(width: 100, height: 13)
                .padding(.trailing, 22)
                .padding(.top, 200)
            widgie(size: size, grounded: false)
                .offset(x: (1 - foot.x) * size - 72, y: 206 - foot.y * size)
            // iOS moves a word down rather than leave one alone on the last line, which the prototype's browser does
            // not, so the greeting breaks after "make" by hand while that line fits.
            ViewThatFits(in: .horizontal) {
                Bubble(words: "Hi! What should we make\ntoday?", tail: .right, voice: pageHidden ? .silent : .low)
                    .fixedSize()
                Bubble(words: Self.greeting, tail: .right, voice: pageHidden ? .silent : .low)
            }
            .frame(maxWidth: 212, alignment: .trailing)
            .padding(.trailing, 138)
            .padding(.top, 38)
        }
        .frame(maxWidth: .infinity, minHeight: 224, alignment: .topTrailing)
    }

    private static func shadow(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0, green: 6 / 255, blue: 20 / 255, opacity: 0.5)
            : Color(red: 18 / 255, green: 26 / 255, blue: 46 / 255, opacity: 0.3)
    }
}

private struct IdeaCard: View {
    let idea: Template.Suggestion
    let send: () -> Void

    var body: some View {
        Button(action: send) {
            HStack(spacing: 12) {
                Image(systemName: idea.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(idea.tint.foreground)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(idea.tint.background))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(idea.title)
                        .font(size: 16, weight: .semibold)
                        .tracking(-0.2)
                    Text(idea.subtitle)
                        .font(size: 13, weight: .medium, relativeTo: .footnote)
                        .foregroundStyle(Palette.secondary)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.secondary.opacity(0.7))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Palette.text)
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.surface).restShadow())
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(SquishStyle(scale: 0.97))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Sends it to Widgie")
    }
}

extension Template.Suggestion.Tint {
    var background: Color {
        switch self {
        case .amber: Color(.widgieIdeaAmber)
        case .coral: Color(.widgieIdeaCoral)
        case .pink: Color(.widgieIdeaPink)
        case .mint: Color(.widgieIdeaMint)
        case .sky: Color(.widgieIdeaSky)
        case .lilac: Color(.widgieIdeaLilac)
        }
    }

    var foreground: Color {
        switch self {
        case .amber: Color(.widgieIdeaAmberInk)
        case .coral: Color(.widgieIdeaCoralInk)
        case .pink: Color(.widgieIdeaPinkInk)
        case .mint: Color(.widgieIdeaMintInk)
        case .sky: Color(.widgieIdeaSkyInk)
        case .lilac: Color(.widgieIdeaLilacInk)
        }
    }
}
