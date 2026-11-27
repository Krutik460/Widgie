import CoreGraphics
import Testing
import WidgetEngine

@testable import Widgie

@Suite struct ArrivalsTests {
    private let a = WidgetID(rawValue: "a")
    private let b = WidgetID(rawValue: "b")

    @Test func aSaveWhileAwayFromWidgetsCountsOnTheTab() {
        var arrivals = Arrivals()
        arrivals.arrive(a, onWidgets: false)
        arrivals.arrive(b, onWidgets: false)
        #expect(arrivals.badge == 2)
        #expect(arrivals.landing == nil)
        #expect(arrivals.fresh == b)
    }

    @Test func aSaveWhileOnWidgetsBadgesNothingAndLandsAtOnce() {
        var arrivals = Arrivals()
        arrivals.arrive(a, onWidgets: true)
        #expect(arrivals.badge == 0)
        #expect(arrivals.landing == a)
        #expect(arrivals.fresh == a)
    }

    @Test func openingWidgetsClearsTheCountAndLandsTheNewest() {
        var arrivals = Arrivals()
        arrivals.arrive(a, onWidgets: false)
        arrivals.arrive(b, onWidgets: false)
        arrivals.openWidgets()
        #expect(arrivals.badge == 0)
        #expect(arrivals.landing == b)
    }

    @Test func openingWidgetsWithNothingNewChangesNothing() {
        var arrivals = Arrivals()
        arrivals.arrive(a, onWidgets: true)
        let before = arrivals
        arrivals.openWidgets()
        #expect(arrivals == before)
    }

    @Test func aWidgetOnItsWayWearsTheNewTagBeforeItCountsOrLands() {
        var arrivals = Arrivals()
        arrivals.add(a)
        #expect(arrivals.fresh == a)
        #expect(arrivals.badge == 0)
        #expect(arrivals.landing == nil)
    }

    @Test func theNewTagMovesToTheNextWidgetThatArrives() {
        var arrivals = Arrivals()
        arrivals.arrive(a, onWidgets: true)
        arrivals.arrive(b, onWidgets: false)
        #expect(arrivals.fresh == b)
    }
}

@MainActor @Suite struct TabsTests {
    private let a = WidgetID(rawValue: "a")
    private let b = WidgetID(rawValue: "b")

    @Test func aTemplateAddedOnTemplatesWaitsHiddenThroughItsFlightThenCountsWithAToast() async {
        let tabs = Tabs()
        tabs.go(.templates)
        await tabs.take(a, named: "Water") {
            #expect(tabs.arrivals.fresh == a, "the card waits hidden with the New tag while it flies")
            #expect(tabs.caught == 0 && tabs.arrivals.badge == 0 && tabs.toast == nil)
        }
        #expect(tabs.caught == 1, "the glyph takes it in as the flight ends")
        #expect(tabs.arrivals.badge == 1 && tabs.arrivals.landing == nil)
        #expect(tabs.toast?.words == "Water is in your widgets.")
        #expect(tabs.page == .templates)

        tabs.go(.widgets)
        #expect(tabs.arrivals.landing == a && tabs.arrivals.badge == 0 && tabs.toast == nil)
    }

    @Test func switchingToWidgetsMidFlightLandsTheWidgetWhenTheFlightEndsWithNoCountOrToast() async {
        let tabs = Tabs()
        tabs.go(.templates)
        await tabs.take(a, named: "Water") {
            tabs.go(.widgets)
            #expect(tabs.arrivals.fresh == a, "the card stays hidden on Widgets until it lands")
            #expect(tabs.arrivals.landing == nil && tabs.caught == 0, "nothing lands before the flight ends")
        }
        #expect(tabs.caught == 1)
        #expect(tabs.arrivals.landing == a && tabs.arrivals.badge == 0 && tabs.toast == nil)
    }

    @Test func everyToastIsANewOneSoAnEarlierToastsTimerNeverDismissesIt() async {
        let tabs = Tabs()
        tabs.go(.templates)
        await tabs.take(a, named: "Water") {}
        let first = tabs.toast
        tabs.go(.widgets)
        tabs.go(.templates)
        await tabs.take(b, named: "Water") {}
        #expect(first != nil && tabs.toast != nil && tabs.toast != first)
    }

    @Test func aSaveLandsOnWidgetsAndCountsElsewhere() {
        let tabs = Tabs()
        tabs.arrive(a)
        #expect(tabs.arrivals.landing == a && tabs.arrivals.badge == 0)
        tabs.go(.make)
        tabs.arrive(b)
        #expect(tabs.arrivals.landing == a && tabs.arrivals.badge == 1 && tabs.caught == 0)
    }

    @Test func eachPageIsBuiltOnItsFirstVisitAndStays() {
        let tabs = Tabs()
        #expect(tabs.visited == [.widgets])
        tabs.go(.templates)
        tabs.go(.widgets)
        #expect(tabs.visited == [.widgets, .templates])
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

    @Test func widgieIsQuietWhileItHopsAndSpeaksOnceItLands() async {
        let widgie = FeedWidgie()
        widgie.wake()
        widgie.hop(to: CGPoint(x: 100, y: 102), reduceMotion: false)
        widgie.hop(to: CGPoint(x: 200, y: 102), reduceMotion: false)
        #expect(widgie.words(greeting: greeting) == nil)
        #expect(await eventually { widgie.words(greeting: greeting) == greeting })
    }

    @Test func wakingDuringAHopLeavesTheVoiceToTheHop() async {
        let widgie = FeedWidgie()
        widgie.hop(to: CGPoint(x: 100, y: 102), reduceMotion: false)
        widgie.hop(to: CGPoint(x: 200, y: 102), reduceMotion: false)
        widgie.wake()
        #expect(widgie.words(greeting: greeting) == nil)
        #expect(await eventually { widgie.words(greeting: greeting) == greeting })
    }

    @Test func aLineTakesTheGreetingsPlaceForAWhile() async {
        let widgie = FeedWidgie()
        widgie.wake()
        widgie.say("Water, updated.", for: 0.05)
        #expect(widgie.words(greeting: greeting) == "Water, updated.")
        #expect(await eventually { widgie.words(greeting: greeting) == greeting })
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

    /// Polls `condition` every 20 ms for up to two seconds.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
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

@Suite struct MoonTests {
    @Test func theMoonStepsAsideOnceThePageScrollsPast24Points() {
        #expect(Sky.moonShown(scrolled: -40))
        #expect(Sky.moonShown(scrolled: 0))
        #expect(Sky.moonShown(scrolled: 24))
        #expect(!Sky.moonShown(scrolled: 25))
        #expect(!Sky.moonShown(scrolled: 400))
    }
}
