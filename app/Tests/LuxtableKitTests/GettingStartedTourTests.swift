import CoreGraphics
import Foundation
import Testing
@testable import LuxtableCore
@testable import LuxtableMac
@testable import LuxtableUI

/// Help ▸ Getting Started: the coach-mark tour of the main window.
@MainActor @Suite struct GettingStartedTourTests {
    @Test func simpleModeDescribesItsPanelAndDropsTheCropStep() {
        #expect(TourModel.steps(simple: false) == [.browse, .viewer, .tools, .crop, .bringIn, .export, .ready])
        #expect(TourModel.steps(simple: true) == [.browse, .viewer, .tools, .bringIn, .export, .ready])
        let settings = makeSettings()
        let tour = TourModel(settings: settings)
        tour.start()
        #expect(tour.steps.count == 7 && !tour.simple)
        #expect(tour.step?.title(simple: tour.simple) == "Browse and cull")
        settings.simpleMode = true
        #expect(tour.steps.count == 7, "a running tour keeps its steps")
        tour.start()
        #expect(tour.simple && tour.steps.count == 6)
        let b = settings.keyBindings
        #expect(TourModel.Step.tools.title(simple: true) == "Simple editing")
        #expect(TourModel.Step.tools.title(simple: false) == "Adjust the photo")
        #expect(TourModel.Step.tools.message(simple: true, bindings: b).contains("Auto"))
        #expect(TourModel.Step.tools.message(simple: true, bindings: b).contains("six sliders"))
        #expect(TourModel.Step.tools.message(simple: false, bindings: b).contains("tool tabs"))
        for simple in [true, false] {
            #expect(TourModel.Step.tools.message(simple: simple, bindings: b).contains("View ▸ Simple Mode (⌃⌘S)"))
        }
        for s in TourModel.Step.allCases {
            #expect(!s.title(simple: false).isEmpty && !s.message(simple: false, bindings: b).isEmpty)
        }
    }

    @Test func navigationStaysInBoundsAndNextOnTheLastCardFinishes() {
        let settings = makeSettings()
        let tour = TourModel(settings: settings)
        #expect(tour.step == nil && !tour.isActive)
        tour.next()
        tour.back()
        #expect(!tour.isActive && !settings.tourShown, "nothing to move while it isn't running")
        tour.start()
        #expect(tour.isFirst && tour.step == .browse && tour.progress == "Step 1 of 7")
        tour.back()
        #expect(tour.index == 0, "Back on the first card does nothing")
        for _ in 0..<6 { tour.next() }
        #expect(tour.isLast && tour.step == .ready && tour.progress == "Step 7 of 7" && tour.isActive)
        tour.back()
        #expect(tour.step == .export)
        tour.next()
        tour.next()
        #expect(!tour.isActive && tour.step == nil && settings.tourShown, "Done on the last card")
    }

    @Test func skipAndFinishRememberTheTourWasShown() {
        let settings = makeSettings()
        let tour = TourModel(settings: settings)
        #expect(tour.autoStart())
        tour.next()
        tour.skip()
        #expect(!tour.isActive && settings.tourShown)
        #expect(AppSettings(defaults: settings.userDefaults).tourShown, "kept in the preferences")
        #expect(!tour.autoStart() && !tour.isActive, "never by itself again")

        let other = makeSettings()
        let t2 = TourModel(settings: other)
        t2.start()
        #expect(!t2.autoStart(), "already running")
        t2.finish()
        #expect(other.tourShown)
    }

    @Test func helpGettingStartedReplaysItAnyTime() async {
        let m = makeModel()
        await m.start()
        m.settings.tourShown = true
        #expect(CommandCatalog.title(.gettingStarted, model: m) == "Getting Started")
        #expect(CommandCatalog.isEnabled(.gettingStarted, model: m))
        #expect(MenuCommand.gettingStarted.shortcut == nil)
        m.tour.start()
        m.tour.next()
        #expect(CommandCatalog.perform(.gettingStarted, model: m) == .none)
        #expect(m.tour.isActive && m.tour.index == 0, "from the first card, even after it was shown")
    }

    @Test func itStartsByItselfOnlyAfterFirstRunSetup() async {
        // An existing user (setup finished before): the launch doesn't start it.
        let existing = makeModel()
        await existing.start()
        #expect(!existing.tour.isActive && existing.sheet == nil)

        // First run: setup's sheet is up; closing it starts the tour, once.
        let first = makeModel(counts: [], onboarded: false)
        #expect(first.sheet == .onboarding && !first.tour.isActive)
        await first.start()
        #expect(!first.tour.isActive, "not under the setup sheet")
        first.settings.onboardingComplete = true
        first.endOnboarding()
        #expect(first.sheet == nil && first.tour.isActive && first.tour.step == .browse)
        first.tour.skip()
        first.endOnboarding()
        #expect(!first.tour.isActive, "shown once")
    }

    @Test func itStartsByItselfOnceInTheSampleWindow() async {
        let m = makeModel() // demo mode, like the sample window
        await m.start()
        SampleLauncher.startTour(m, arguments: ["Luxtable", "--demo"])
        #expect(!m.tour.isActive, "a plain demo launch isn't the sample window")
        SampleLauncher.startTour(m, arguments: ["Luxtable", "--demo", SampleLauncher.flag])
        #expect(m.tour.isActive)
        m.tour.finish()
        SampleLauncher.startTour(m, arguments: ["Luxtable", "--demo", SampleLauncher.flag])
        #expect(!m.tour.isActive, "its preferences remember it")
    }

    @Test func theLastCardOffersTheFirstRunActions() async {
        let m = makeModel(counts: [], onboarded: false)
        await m.start()
        m.endOnboarding()
        #expect(m.emptyState == .firstRun)
        #expect(m.tourActions == m.emptyStateActions && m.tourActions.contains(.importCard) && m.tourActions.contains(.openFolder))
        let b = m.settings.keyBindings
        #expect(TourModel.Step.ready.title(simple: false) == "You’re ready")
        #expect(TourModel.Step.ready.message(simple: false, bindings: b, offersActions: true).contains("Bring in some photos"))
        #expect(!TourModel.Step.ready.message(simple: false, bindings: b).contains("Bring in some photos"))
        #expect(m.performTourAction(.importCard))
        #expect(m.sheet == .importCard(nil) && !m.tour.isActive && m.settings.tourShown)

        let open = makeModel(counts: [], onboarded: false)
        await open.start()
        open.endOnboarding()
        #expect(!open.performTourAction(.openFolder), "the view runs the folder panel")
        #expect(!open.tour.isActive)

        let session = makeModel()
        await session.start()
        #expect(session.tourActions.isEmpty, "a session is open: Done alone")
    }

    @Test func theCardsUseTheUsersKeys() {
        var b = KeyBindings.defaults
        #expect(TourModel.Step.browse.message(simple: false, bindings: b).contains("Press 1–5 to rate, P to pick and X to reject"))
        #expect(TourModel.Step.viewer.message(simple: false, bindings: b).contains("Before/After (Y)"))
        #expect(TourModel.Step.crop.message(simple: false, bindings: b).hasPrefix("Crop (C)"))
        b.bind(.pick, to: "q")
        b.bind(.cropTool, to: "z")
        #expect(TourModel.Step.browse.message(simple: false, bindings: b).contains("Q to pick"))
        #expect(TourModel.Step.crop.message(simple: false, bindings: b).hasPrefix("Crop (Z)"))
        b.unbind(.reject)
        let unbound = TourModel.Step.browse.message(simple: false, bindings: b)
        #expect(unbound.contains("Photo menu") && !unbound.contains("to reject."))
        #expect(TourModel.Step.bringIn.message(simple: false, bindings: b).contains("Import from Photos Library…"))
        #expect(TourModel.Step.bringIn.message(simple: false, bindings: b).contains("iPhone"))
        #expect(TourModel.Step.export.message(simple: false, bindings: b).contains("Share… (⌥⌘E)"))
    }

    @Test func keysDriveTheTourAndNothingUnderTheDim() async {
        let m = makeModel()
        await m.start()
        let focused = m.focusedID
        let pickedBefore = m.focusedPhoto?.pick
        func key(_ k: KeyInput) -> Bool { m.handleKey(k, focus: .none, sheetOpen: false, isMainWindow: true) }
        m.tour.start()
        #expect(key(KeyInput(special: .right)) && m.tour.index == 1)
        #expect(key(KeyInput(special: .returnKey)) && m.tour.index == 2)
        #expect(key(KeyInput(special: .left)) && m.tour.index == 1)
        #expect(m.focusedID == focused, "the arrows move the tour, not the photo")
        #expect(key(KeyInput("p")) && m.focusedPhoto?.pick == pickedBefore, "culling keys are swallowed")
        #expect(!key(KeyInput(special: .tab)) && !key(KeyInput(special: .space)), "for the card's buttons")
        #expect(!key(KeyInput("e", command: true)), "menu shortcuts still work")
        _ = m.handleKey(KeyInput(special: .escape), focus: .text, sheetOpen: false, isMainWindow: true)
        #expect(m.tour.isActive, "typing in a field isn't the tour's")
        #expect(key(KeyInput(special: .escape)) && !m.tour.isActive && m.settings.tourShown)
        #expect(!m.tour.handle(KeyInput(special: .right)), "no tour, no keys")
    }

    @Test func theCardSitsBesideTheLitPart() {
        let bounds = CGSize(width: 1600, height: 1000)
        let card = CGSize(width: 360, height: 200)
        let m = TourLayout.margin
        // Nothing lit: centred; the toolbar steps: under the toolbar's left end.
        #expect(TourLayout.cardOrigin(spot: nil, card: card, in: bounds) == CGPoint(x: 620, y: 400))
        #expect(TourLayout.cardOrigin(spot: nil, card: card, in: bounds, toolbar: true) == CGPoint(x: m, y: m))
        // A small button at the top: below it, centred on it.
        let crop = CGRect(x: 600, y: 10, width: 100, height: 30)
        #expect(TourLayout.cardOrigin(spot: crop, card: card, in: bounds) == CGPoint(x: 470, y: 40 + m))
        // The filmstrip at the bottom: above it.
        let strip = CGRect(x: 0, y: 860, width: 1280, height: 140)
        #expect(TourLayout.cardOrigin(spot: strip, card: card, in: bounds) == CGPoint(x: 460, y: 860 - m - 200))
        // The tools on the left, full height: to their right.
        let toolsLeft = CGRect(x: 0, y: 0, width: 320, height: 1000)
        #expect(TourLayout.cardOrigin(spot: toolsLeft, card: card, in: bounds) == CGPoint(x: 320 + m, y: 400))
        // On the right: to their left.
        let toolsRight = CGRect(x: 1280, y: 0, width: 320, height: 1000)
        #expect(TourLayout.cardOrigin(spot: toolsRight, card: card, in: bounds) == CGPoint(x: 1280 - m - 360, y: 400))
        // The viewer fills the window: inside it, at its foot.
        let viewer = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        #expect(TourLayout.cardOrigin(spot: viewer, card: card, in: bounds) == CGPoint(x: 620, y: 1000 - m - 200))
    }

    @Test func everyAnchorHasAStep() {
        let lit = Set(TourModel.Step.allCases.compactMap(\.anchor))
        #expect(lit == Set(TourAnchor.allCases))
        #expect(TourModel.Step.allCases.filter(\.pointsAtToolbar) == [.bringIn, .export])
    }
}
