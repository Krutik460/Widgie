import CoreGraphics
import Foundation
import Testing
import WidgetBuilder
import WidgetEngine
import WidgetHosting

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

@MainActor @Suite struct FeedWidgieTests {
    private let greeting = "Morning! Here’s Water."

    @Test func widgieIsQuietUntilItWakesThenGreets() {
        let widgie = FeedWidgie()
        #expect(widgie.words(greeting: greeting) == nil)
        widgie.wake()
        #expect(widgie.words(greeting: greeting) == greeting)
    }

    @Test func widgieHopsOnlyBetweenTwoDifferentPerchesAndNotWithReduceMotion() {
        let widgie = FeedWidgie()
        #expect(!widgie.hop(to: nil, reduceMotion: false))
        #expect(!widgie.hop(to: CGPoint(x: 100, y: 102), reduceMotion: false), "the first perch is where it starts")
        #expect(!widgie.hop(to: CGPoint(x: 100, y: 102), reduceMotion: false))
        #expect(!widgie.hop(to: CGPoint(x: 200, y: 124), reduceMotion: true))
        #expect(widgie.hop(to: CGPoint(x: 100, y: 102), reduceMotion: false))
        #expect(widgie.act.kind == .move(CGSize(width: 100, height: 22)), "it hops from where it last stood")
    }

    @Test func widgieIsQuietWhileItHopsAndSpeaksOnceItLands() async throws {
        let widgie = FeedWidgie()
        widgie.wake()
        widgie.hop(to: CGPoint(x: 100, y: 102), reduceMotion: false)
        widgie.hop(to: CGPoint(x: 200, y: 102), reduceMotion: false)
        #expect(widgie.words(greeting: greeting) == nil)
        try await until({ widgie.words(greeting: greeting) == greeting }, "Widgie says the greeting")
    }

    @Test func wakingDuringAHopLeavesTheVoiceToTheHop() async throws {
        let widgie = FeedWidgie()
        widgie.hop(to: CGPoint(x: 100, y: 102), reduceMotion: false)
        widgie.hop(to: CGPoint(x: 200, y: 102), reduceMotion: false)
        widgie.wake()
        #expect(widgie.words(greeting: greeting) == nil)
        try await until({ widgie.words(greeting: greeting) == greeting }, "Widgie says the greeting")
    }

    @Test func aLineTakesTheGreetingsPlaceForAWhile() async throws {
        let widgie = FeedWidgie()
        widgie.wake()
        widgie.say("Water, updated.", for: 0.05)
        #expect(widgie.words(greeting: greeting) == "Water, updated.")
        try await until({ widgie.words(greeting: greeting) == greeting }, "Widgie says the greeting")
    }

    @Test func voiceOverHearsNothingFromAHiddenPageTheGreetingPolitelyAndAReplyAtOnce() {
        let widgie = FeedWidgie()
        widgie.wake()
        #expect(widgie.voice(active: false) == .silent)
        #expect(widgie.voice(active: true) == .low)
        widgie.say("Water, updated.", for: 10)
        #expect(widgie.voice(active: true) == .normal)
        #expect(widgie.voice(active: false) == .silent)
    }
}

@Suite struct SpeechTests {
    @Test func theTitleAndGreetingFollowTheClock() {
        #expect(Daypart(hour: 5) == .morning)
        #expect(Daypart(hour: 11) == .morning)
        #expect(Daypart(hour: 12) == .afternoon)
        #expect(Daypart(hour: 16) == .afternoon)
        #expect(Daypart(hour: 17) == .evening)
        #expect(Daypart(hour: 2) == .evening)
        #expect(Daypart(hour: 9).title == "Good morning")
        #expect(Daypart(hour: 14).title == "Good afternoon")
        #expect(Daypart(hour: 21).title == "Good evening")
    }

    @Test func widgieGreetsTheWidgetItStandsOn() {
        #expect(Speech.greeting("Water", .morning) == "Morning! Here’s Water.")
        #expect(Speech.greeting("Water", .afternoon) == "Afternoon! Here’s Water.")
        #expect(Speech.greeting("Water", .evening) == "I’ll keep an eye on Water tonight.")
    }

    @Test func withNoWidgetsWidgieAsksForOne() {
        for part in [Daypart.morning, .afternoon, .evening] {
            #expect(Speech.greeting(nil, part) == "Tell me a widget.")
        }
    }

    @Test func aTapNamesTheWidget() {
        #expect(Speech.tapped("Water") == "Water, updated.")
    }

    @Test func aNewWidgetWithButtonsAsksForATap() {
        #expect(Speech.landed("Biscuit", buttons: true) == "Here’s Biscuit. Give it a tap.")
        #expect(Speech.landed("Biscuit", buttons: false) == "Here’s Biscuit, ready to go.")
    }
}

@Suite struct PerchTests {
    private let a = WidgetID(rawValue: "a")
    private let b = WidgetID(rawValue: "b")
    private let c = WidgetID(rawValue: "c")

    @Test func widgieStandsOnTheFirstRowsWideOrRightOrLoneWidget() {
        #expect(Perch(.wide(a)) == .wide(a))
        #expect(Perch(.pair(a, b)) == .right(b))
        #expect(Perch(.pair(a, nil)) == .lone(a))
        #expect(Perch(nil) == nil)
    }

    @Test func aFreshSmallAtTheTopIsTheOneWidgieStandsOn() {
        let shown: [(id: WidgetID, family: Family)] = [(a, .small), (b, .medium), (c, .small)]
        #expect(Perch(FeedRow.rows(shown, fresh: a).first)?.id == a)
        #expect(Perch(FeedRow.singles(shown).first)?.id == a, "at the accessibility text sizes too")
    }

    @Test func widgieTalksTowardTheEmptyHalfOfALoneSmallAndAcrossTheOthers() {
        #expect(Perch.lone(a).bubble == .right)
        #expect(Perch.right(a).bubble == .left)
        #expect(Perch.wide(a).bubble == .left)
    }

    @Test func widgieStandsOverTheMiddleOfTheRightSmallAndClearOfTheCountLineOnAWide() {
        #expect(Perch.right(a).x(column: 362, small: 174, large: false) == 275)
        #expect(Perch.wide(a).x(column: 362, small: 174, large: false) == 214)
        #expect(Perch.lone(a).x(column: 362, small: 174, large: false) == 122)
        #expect(Perch.wide(a).room > Perch.right(a).room, "a wide perch sits under the count line")
    }

    @Test func atTheAccessibilityTextSizesWidgieStandsNearTheEdgeToLeaveItsBubbleRoom() {
        #expect(Perch.wide(a).x(column: 362, small: 174, large: true) == 318)
        #expect(Perch.lone(a).x(column: 362, small: 174, large: true) == 52)
        #expect(Perch.wide(a).bubbleWidth(column: 362, x: 318, large: true) == 287)
    }
}

@MainActor @Suite struct LibraryTests {
    @Test func aFirstLoadThatFailsStillCountsAsLoadedSoTheFeedShowsSomething() async throws {
        let blocker = FileManager.default.temporaryDirectory.appending(path: "app-tests-\(UUID().uuidString)")
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let library = Library(engine: Engine(directory: blocker.appending(path: "store")))

        await library.reload()
        #expect(library.message != nil, "the store could not be read")
        #expect(library.loaded)
        #expect(library.items.isEmpty)
    }

    @Test func aReloadThatFinishesAfterALaterOneNeverBringsBackADeletedWidget() async throws {
        let shared = SharedStore()
        let id = try await shared.build(counterDocument())
        let library = Library(engine: shared.engine)
        let older = Task { await library.reload() }
        await Task.yield()
        try shared.engine.delete(id)

        await library.reload()
        await older.value
        #expect(library.items.isEmpty)
    }

    @Test func addBuildsATemplateIntoTheLibraryAndDrawsItInTheFeed() async throws {
        let shared = SharedStore()
        let library = Library(engine: shared.engine)
        let template = try Template.bundled("pet-fed")

        guard case .success(let id) = await library.add(try template.source(filling: ["pet": "Mochi"])) else {
            Issue.record("expected the template to be added")
            return
        }
        #expect(try shared.engine.widgets().map(\.id) == [id])
        let item = try #require(library.items.first)
        #expect(library.items.count == 1 && item.id == id && item.summary.name == "Mochi fed")
        #expect(item.faces[.small] != nil && item.faces[.medium] != nil)
    }

    @Test func addReportsAWidgetTheLibraryRejectsAndKeepsItOut() async throws {
        let shared = SharedStore()
        let library = Library(engine: shared.engine)
        guard case .failure = await library.add(WidgetSource(json: Data(#"{"name": "Counter"}"#.utf8))) else {
            Issue.record("expected the widget to be rejected")
            return
        }
        #expect(try shared.engine.widgets().isEmpty)
        #expect(library.items.isEmpty)
    }

    /// The sheet is keyed by the shown form's id, so a new id is what makes SwiftUI start it over.
    @Test func everyFormLinkPublishesANewShownForm() async throws {
        let shared = SharedStore()
        let document = counterDocument(fields: ["note": "text"])
            .replacing(#"{"insert":"taps"}"#, with: #"{"form":"taps","fields":["note"]}"#)
        let id = try await shared.build(document)
        let revision = try #require(try shared.engine.history(of: id).first).id
        let link = Hosting.formURL(for: Tap(widget: id.rawValue, revision: revision, action: "add", row: nil))
        let library = Library(engine: shared.engine)

        library.open(link)
        let first = try #require(library.form)
        library.open(link)
        let second = try #require(library.form)
        #expect(first.form.fields.map(\.id) == ["note"] && second.form.fields.map(\.id) == ["note"])
        #expect(first.id != second.id)
    }
}
