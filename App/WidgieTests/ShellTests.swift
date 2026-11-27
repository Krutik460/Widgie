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

    @Test func aToastOnMakeSitsBelowItsBarAndLeavesWithMake() async {
        let tabs = Tabs()
        tabs.go(.make)
        await tabs.take(a, named: "Counter") {}
        #expect(tabs.toast?.words == "Counter is in your widgets." && tabs.toast?.low == true)
        tabs.go(.templates)
        #expect(tabs.toast == nil, "it leaves with Make")

        await tabs.take(b, named: "Water") {}
        #expect(tabs.toast?.low == false)
        tabs.go(.make)
        #expect(tabs.toast?.words == "Water is in your widgets.", "a toast from another tab stays up on Make")
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

@MainActor @Suite struct FlightsTests {
    @Test func settlingEndsTheConfettiAndLeavesTheTileFlying() async {
        let flights = Flights()
        flights.burst(from: CGRect(x: 20, y: 300, width: 170, height: 170))
        let flying = Task {
            await flights.fly(Launch(name: "Water", face: nil, from: CGRect(x: 20, y: 300, width: 170, height: 170)))
        }
        await Task.yield()
        #expect(flights.bursts.count == 1 && flights.flight != nil)
        flights.settle()
        #expect(flights.bursts.isEmpty, "the confetti leaves with the page")
        #expect(flights.flight != nil, "the tile still lands in the tab bar")
        await flying.value
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
