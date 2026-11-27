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
