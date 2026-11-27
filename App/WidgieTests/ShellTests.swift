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

    @Test func aTemplateAddedFromTemplatesBadgesAndLandsOnlyWhenWidgetsOpens() {
        var arrivals = Arrivals()
        arrivals.arrive(a, onWidgets: true)
        arrivals.arrive(b, onWidgets: false)
        #expect(arrivals.badge == 1)
        #expect(arrivals.landing == a, "the earlier landing stays; the template waits")
        arrivals.openWidgets()
        #expect(arrivals.badge == 0)
        #expect(arrivals.landing == b)
    }

    @Test func theNewTagMovesToTheNextWidgetThatArrives() {
        var arrivals = Arrivals()
        arrivals.arrive(a, onWidgets: true)
        arrivals.arrive(b, onWidgets: false)
        #expect(arrivals.fresh == b)
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
