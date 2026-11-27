import CoreGraphics
import Testing
import WidgetEngine

@testable import Widgie

@Suite struct FeedRowTests {
    private let a = WidgetID(rawValue: "a")
    private let b = WidgetID(rawValue: "b")
    private let c = WidgetID(rawValue: "c")
    private let d = WidgetID(rawValue: "d")

    @Test func theRhythmOfOneWideAndTwoSmallsKeepsItsOrder() {
        #expect(
            FeedRow.rows([(a, .medium), (b, .small), (c, .small), (d, .medium)]) == [
                .wide(a), .pair(b, c), .wide(d),
            ])
    }

    @Test func aSmallWaitsPastOneWideForItsPartner() {
        #expect(FeedRow.rows([(a, .small), (b, .medium), (c, .small)]) == [.wide(b), .pair(a, c)])
    }

    @Test func aSmallThatWouldWaitPastTwoWidesKeepsItsOwnPlaceAlone() {
        #expect(
            FeedRow.rows([(a, .small), (b, .medium), (c, .medium), (d, .small)]) == [
                .pair(a, nil), .wide(b), .wide(c), .pair(d, nil),
            ])
    }

    @Test func aLastSmallWithoutAPartnerStaysWhereItWouldHaveBeen() {
        #expect(FeedRow.rows([(a, .small), (b, .medium)]) == [.pair(a, nil), .wide(b)])
        #expect(FeedRow<WidgetID>.rows([]) == [])
    }

    @Test func aFreshSmallTakesTheFirstRowsRightSideWithTheNextSmall() {
        #expect(
            FeedRow.rows([(a, .small), (b, .medium), (c, .small), (d, .small)], fresh: a) == [
                .pair(c, a), .wide(b), .pair(d, nil),
            ])
    }

    @Test func aFreshSmallWithNoOtherSmallStandsAloneAtTheTop() {
        #expect(
            FeedRow.rows([(a, .small), (b, .medium), (c, .medium)], fresh: a) == [.pair(a, nil), .wide(b), .wide(c)])
    }

    @Test func atTheAccessibilityTextSizesEachWidgetTakesARowNewestFirst() {
        #expect(
            FeedRow.singles([(a, .small), (b, .medium), (c, .small), (d, .small)]) == [
                .pair(a, nil), .wide(b), .pair(c, nil), .pair(d, nil),
            ])
    }

    @Test func freshChangesNothingForAWideOrAWidgetBelowTheTop() {
        let shown: [(id: WidgetID, family: Family)] = [(a, .medium), (b, .small), (c, .small)]
        #expect(FeedRow.rows(shown, fresh: a) == FeedRow.rows(shown))
        #expect(FeedRow.rows([(a, .small), (b, .small), (c, .medium)], fresh: b) == [.pair(a, b), .wide(c)])
    }
}

@MainActor @Suite struct RhythmTests {
    @Test func unplacedWidgetsKeepARhythmOfOneWideAndTwoSmalls() {
        #expect(
            (0..<6).map { Library.family(placed: [], age: $0) } == [.medium, .small, .small, .medium, .small, .small])
    }

    @Test func theOldestUnplacedWidgetIsWideAndTheNewestTakesTheNextBeat() {
        let ids = ["d", "c", "b", "a"].map(WidgetID.init(rawValue:))
        let shown = Library.shown(ids, placed: [:])
        #expect(shown.map(\.id) == ids)
        #expect(shown.map(\.family) == [.medium, .small, .small, .medium])
    }

    @Test func aNewWidgetNeverChangesTheSizeOfTheOnesBeforeIt() {
        let before = Library.shown(["c", "b", "a"].map(WidgetID.init(rawValue:)), placed: [:])
        let after = Library.shown(["d", "c", "b", "a"].map(WidgetID.init(rawValue:)), placed: [:])
        #expect(after.dropFirst().map(\.family) == before.map(\.family))
        #expect(
            FeedRow.rows(after).dropFirst() == FeedRow.rows(before)[...],
            "the rows below the new wide widget stay as they were")
    }

    @Test func aPlacedWidgetKeepsItsSizeWhereverItSits() {
        let placed: [WidgetID: Set<Family>] = [WidgetID(rawValue: "b"): [.medium]]
        let shown = Library.shown(["c", "b", "a"].map(WidgetID.init(rawValue:)), placed: placed)
        #expect(shown.map(\.family) == [.small, .medium, .medium])
    }

    @Test func aPlacedWidgetShowsInTheSizeItIsPlacedIn() {
        #expect(Library.family(placed: [.small], age: 0) == .small)
        #expect(Library.family(placed: [.small, .medium], age: 1) == .medium)
    }
}

@MainActor @Suite struct PlacementTests {
    private let a = WidgetID(rawValue: "a")
    private let b = WidgetID(rawValue: "b")

    @Test func aHomeScreenWidgetNeverConfiguredCountsAsTheLatest() {
        let placed = Library.placements([(nil, .small), (b, .medium), (b, .small)], latest: a)
        #expect(placed == [a: [.small], b: [.medium, .small]])
    }

    @Test func withNoWidgetsAnUnconfiguredHomeScreenWidgetCountsAsNothing() {
        #expect(Library.placements([(nil, .medium)], latest: nil).isEmpty)
    }
}

@Suite struct FaceSizesTests {
    @Test func aColumnSplitsIntoTwoSmallsAndAGapLikeTheHomeScreen() {
        let sizes = FaceSizes(column: 370)
        #expect(sizes.small == CGSize(width: 178, height: 178))
        #expect(sizes.medium == CGSize(width: 370, height: 178))
    }

    @Test func aColumnNarrowerThanTheGapDrawsNothingRatherThanANegativeSize() {
        let sizes = FaceSizes(column: 0)
        #expect(sizes.small == .zero)
        #expect(sizes.medium.width == FaceSizes.gap)
    }
}
