import SwiftUI
import WidgetBuilder
import WidgetEngine

/// The Templates tab: ready-made widgets by category, under a banner where Widgie acts the category out, in a
/// pile laid out like the feed with each card tilted a little. A card opens the template to try, fill in and add.
struct TemplatesView: View {
    let gallery: TemplateGallery
    let library: Library
    /// Whether the page is scrolled past the moon, which then steps aside.
    @Binding var pastMoon: Bool
    /// A template was added to the library as this widget, and its tile is leaving the sheet.
    let added: (WidgetID, Launch) -> Void
    /// Change in chat: the filled template and its name.
    let chat: (WidgetSource, String) -> Void

    @State private var chosen = Template.Category.forTwo
    /// The category the banner and the pile show, which follows `chosen` once the pile has scattered.
    @State private var shown = Template.Category.forTwo
    @State private var leaving = false
    @State private var switched = false
    /// A template opening: its sheet's content is measured first, then the sheet opens at that height.
    @State private var measuring: TemplateTrial?
    @State private var opened: Opened?
    @State private var width: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let margin: CGFloat = 20

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                CategoryRow(chosen: chosen, pick: pick)
                    .padding(.top, 16)
                    .padding(.bottom, 16)
                TemplateBanner(chosen: chosen, shown: shown, leaving: leaving, acting: switched)
                    .padding(.bottom, 22)
                Pile(gallery: gallery, templates: gallery.templates(in: shown)) { template in
                    measuring = TemplateTrial(template: template, sizes: TemplateSheet.sizes(width: sheetWidth))
                }
                .id(shown)
                .opacity(leaving ? 0 : 1)
                .offset(y: leaving && !reduceMotion ? 10 : 0)
                .scaleEffect(leaving && !reduceMotion ? 0.97 : 1)
                .allowsHitTesting(!leaving)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(shown.title)
            }
            .padding(.horizontal, Self.margin)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: Bool.self) {
            !Sky.moonShown(scrolled: $0.contentOffset.y + $0.contentInsets.top)
        } action: { _, past in
            pastMoon = past
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Palette.text)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: { width in
            self.width = width
        }
        .background {
            if let measuring {
                TemplateSheet.Content(
                    trial: measuring, library: library, message: .constant(nil), adding: .constant(false),
                    added: { _, _ in }, chat: { _, _ in }
                )
                .frame(width: sheetWidth)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .accessibilityHidden(true)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: { height in
                    opened = Opened(trial: measuring, height: height)
                    self.measuring = nil
                }
            }
        }
        .sheet(item: $opened) { opened in
            TemplateSheet(trial: opened.trial, library: library, height: opened.height) { id, launch in
                self.opened = nil
                added(id, launch)
            } chat: { source, name in
                self.opened = nil
                chat(source, name)
            }
        }
    }

    private struct Opened: Identifiable {
        let trial: TemplateTrial
        let height: CGFloat
        var id: ObjectIdentifier { ObjectIdentifier(trial) }
    }

    /// The sheet's width: below its largest detent it floats 7 points in from each side of the screen.
    private var sheetWidth: CGFloat { width - 14 }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ready in a tap, yours in a word")
                .font(size: 14, weight: .semibold, relativeTo: .subheadline)
                .foregroundStyle(Palette.secondary)
            Text("Templates")
                .display(size: 40)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.top, 6)
    }

    /// Chooses a category: the chip turns at once, the pile and the banner's cast scatter out, and the new ones
    /// come in.
    private func pick(_ category: Template.Category) {
        guard category != chosen else { return }
        chosen = category
        gallery.show(category)
        switched = true
        guard !reduceMotion else {
            shown = category
            return
        }
        withAnimation(.easeOut(duration: 0.16)) { leaving = true }
        Task {
            try? await Task.sleep(for: .milliseconds(160))
            guard chosen == category else { return }
            shown = category
            withAnimation(.easeOut(duration: 0.2)) { leaving = false }
        }
    }
}

/// The categories as a row of soft chips, the chosen one in ink. A tab group to VoiceOver. When the row does not
/// fit, at the largest text sizes, it scrolls sideways.
private struct CategoryRow: View {
    let chosen: Template.Category
    let pick: (Template.Category) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            FillRow(spacing: 7) { chips }
            ScrollView(.horizontal) {
                HStack(spacing: 7) { chips }
                    .padding(.horizontal, TemplatesView.margin)
                    .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            .padding(.horizontal, -TemplatesView.margin)
            .padding(.vertical, -12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
        .accessibilityLabel("Template categories")
    }

    private var chips: some View {
        ForEach(Template.Category.allCases, id: \.self) { category in
            let on = category == chosen
            Button {
                pick(category)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: category.symbol)
                        .font(size: 13, weight: .bold, relativeTo: .subheadline)
                        .accessibilityHidden(true)
                    Text(category.title)
                        .font(size: 13.5, weight: .semibold, relativeTo: .subheadline)
                        .tracking(-0.15)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(category.title)
                .foregroundStyle(on ? Palette.chosenLabel : Palette.text)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background {
                    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                    if on {
                        shape.fill(Palette.chosenFill).shadow(color: Palette.widgetShadow, radius: 9, y: 8)
                    } else {
                        shape.fill(Palette.surface).restShadow()
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .animation(.easeOut(duration: 0.2), value: on)
            }
            .buttonStyle(SquishStyle(scale: 0.94))
            .accessibilityAddTraits(on ? .isSelected : [])
            .sensoryFeedback(.selection, trigger: on) { _, now in now }
        }
    }
}

/// Lays its children in one row, each at its ideal width plus an equal share of the room left over. It never
/// claims less than the sum of their ideal widths, so `ViewThatFits` can tell when the row does not fit.
private struct FillRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = ideal.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1))
        return CGSize(width: max(proposal.width ?? 0, width), height: ideal.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        let used = ideal.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1))
        let extra = max(0, bounds.width - used) / CGFloat(max(1, subviews.count))
        var x = bounds.minX
        for (subview, width) in zip(subviews, ideal) {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                proposal: ProposedViewSize(width: width + extra, height: bounds.height))
            x += width + extra + spacing
        }
    }
}

/// One category's templates: wide ones span the row and smalls pair up, as in the feed, and a small without a
/// partner sits in the middle. Each card leans a little, alternating, and rises in after the one before it.
private struct Pile: View {
    let gallery: TemplateGallery
    let templates: [Template]
    let open: (Template) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At the accessibility text sizes every card takes a row of its own, so its words have the column's width.
        let rows =
            typeSize.isAccessibilitySize
            ? templates.map { FeedRow.wide($0.id) } : FeedRow.rows(templates.map { ($0.id, $0.family) })
        LazyVStack(spacing: 28) {
            ForEach(rows) { row in
                switch row {
                case .wide(let id):
                    card(id)
                case .pair(let first, let second?):
                    HStack(alignment: .top, spacing: FaceSizes.gap) {
                        card(first)
                        card(second)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                case .pair(let only, nil):
                    card(only).frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder private func card(_ id: Template.ID) -> some View {
        if let index = templates.firstIndex(where: { $0.id == id }) {
            let template = templates[index]
            PileCard(
                template: template, card: gallery.card(id), size: gallery.sizes[template.family],
                tilt: Self.tilt(at: index, family: template.family)
            ) {
                open(template)
            }
            .rise(after: Double(index) * 0.05)
        }
    }

    /// Small cards lean up to 2.5 degrees and wide ones 1, alternating, so the pile looks handled but stays in
    /// its gutters.
    static func tilt(at index: Int, family: Family) -> Angle {
        let sign: Double = index % 2 == 1 ? 1 : -1
        return .degrees(sign * (family == .medium ? 1 : [2.5, 2, 1.5][index % 3]))
    }
}

/// A template's card: its sample face, inert and tilted, then its name, Try, and its line. The whole card is one
/// button; pressing it straightens the face and squishes it.
private struct PileCard: View {
    let template: Template
    let card: TemplateGallery.Card
    let size: CGSize
    let tilt: Angle
    let open: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    /// At the accessibility text sizes the words wrap across the column, under the face, instead of being cut off.
    private var large: Bool { typeSize.isAccessibilitySize }
    private var lines: Int? { large ? nil : 1 }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 12) {
                PileFace(card: card, size: size, tilt: tilt)
                    .frame(maxWidth: large ? .infinity : nil)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(template.name)
                            .font(size: 15, weight: .semibold, relativeTo: .subheadline)
                            .tracking(-0.2)
                            .lineLimit(lines)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        HStack(spacing: 4) {
                            Text("Try")
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                        }
                        .font(size: 13, weight: .semibold, relativeTo: .footnote)
                        .foregroundStyle(Palette.secondary)
                    }
                    Text(template.line)
                        .font(size: 13, weight: .medium, relativeTo: .footnote)
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(lines)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4)
                .frame(minHeight: 44)
            }
            .frame(width: large ? nil : size.width)
            .frame(maxWidth: large ? .infinity : nil)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(template.name). \(template.line)")
        }
        .buttonStyle(PileCardStyle())
        .accessibilityHint("Try it")
    }
}

/// The face in the pile: drawn at the column's size and never scaled up, tilted, and resting at 97 percent so a
/// press has somewhere to go. Drawn still, so its buttons are pictures and the card stays one control.
private struct PileFace: View {
    let card: TemplateGallery.Card
    let size: CGSize
    let tilt: Angle

    @Environment(\.pilePressed) private var pressed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let face = card.face {
                FaceView(face, host: .still)
            } else {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.disabled.opacity(0.4))
            }
        }
        .frame(width: size.width, height: size.height)
        .faceShadow()
        .rotationEffect(pressed ? .zero : tilt)
        .scaleEffect(pressed ? 0.96 : 0.97)
        .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.4), value: pressed)
    }
}

private struct PileCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.pilePressed, configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { _, now in now }
    }
}

extension EnvironmentValues {
    @Entry fileprivate var pilePressed = false
}

extension View {
    /// Rises in from a little below after `delay` seconds when it appears; shown at once with Reduce Motion.
    fileprivate func rise(after delay: Double) -> some View {
        modifier(Rise(delay: delay))
    }
}

private struct Rise: ViewModifier {
    let delay: Double

    @State private var risen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let shown = risen || reduceMotion
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 18)
            .scaleEffect(shown ? 1 : 0.98)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.spring(duration: 0.42, bounce: 0.25).delay(delay)) { risen = true }
            }
    }
}
