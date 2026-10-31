import Foundation
import Testing
@testable import LuxtableCore
@testable import LuxtableMac
@testable import LuxtableUI

@MainActor
@Suite struct SimpleModeTests {
    private let camera = WhiteBalanceValue(kelvin: 5000, tint: 4.27)

    @Test func everySliderIsPlainAndCentred() {
        for a in SimpleAdjustment.allCases {
            #expect(a.spec.range == -100...100 && a.spec.defaultValue == 0 && !a.spec.help.isEmpty)
            #expect(a.value(in: EditState(), asShot: camera) == 0, "an untouched photo has every slider at 0")
            #expect(!a.isAdjusted(EditState(), asShot: camera))
            #expect(a.id == a.rawValue)
        }
        #expect(SimpleAdjustment.allCases.map(\.spec.label) == ["Brightness", "Contrast", "Color", "Warmth", "Highlights", "Shadows"])
    }

    @Test func slidersAreTheOrdinaryAdjustments() {
        var e = EditState()
        SimpleAdjustment.contrast.apply(30, to: &e, asShot: nil)
        SimpleAdjustment.color.apply(-100, to: &e, asShot: nil)
        SimpleAdjustment.highlights.apply(-40, to: &e, asShot: nil)
        SimpleAdjustment.shadows.apply(25, to: &e, asShot: nil)
        SimpleAdjustment.light.apply(50, to: &e, asShot: nil)
        #expect(e.exposure.contrast == 30 && e.exposure.saturation == -100)
        #expect(e.hdr.highlights == -40 && e.hdr.shadows == 25)
        #expect(e.exposure.ev == 1, "Light +50 is one stop")
        SimpleAdjustment.light.apply(-100, to: &e, asShot: nil)
        #expect(e.exposure.ev == -2)
        // Out of range values clamp; the reading follows the stored value.
        SimpleAdjustment.contrast.apply(500, to: &e, asShot: nil)
        #expect(e.exposure.contrast == 100)
        e.exposure.ev = 0.37 // set in Full mode
        #expect(SimpleAdjustment.light.value(in: e, asShot: nil) == 19)
        e.exposure.ev = 4
        #expect(SimpleAdjustment.light.value(in: e, asShot: nil) == 100, "beyond ±2 EV the slider sits at its end")
        // Only the named adjustment changes.
        var only = EditState()
        SimpleAdjustment.shadows.apply(10, to: &only, asShot: nil)
        var expected = EditState()
        expected.hdr.shadows = 10
        #expect(only == expected)
    }

    @Test func warmthMovesTheWhiteBalanceFromAsShot() {
        var e = EditState()
        SimpleAdjustment.warmth.apply(50, to: &e, asShot: camera)
        #expect(!e.whiteBalance.asShot)
        #expect(e.whiteBalance.temperature > 5000, "warmer is a higher Kelvin setting")
        #expect(e.whiteBalance.tint == 4.3, "leaving As Shot keeps the camera's tint")
        #expect(abs(SimpleAdjustment.warmth.value(in: e, asShot: camera) - 50) <= 1, "the reading round-trips")
        let warm = e.whiteBalance.temperature
        SimpleAdjustment.warmth.apply(-50, to: &e, asShot: camera)
        #expect(e.whiteBalance.temperature < 5000)
        #expect(e.whiteBalance.tint == 4.3, "a second move keeps the tint it had")
        SimpleAdjustment.warmth.apply(100, to: &e, asShot: camera)
        #expect(e.whiteBalance.temperature > warm)
        #expect(Specs.temperature.range.contains(e.whiteBalance.temperature))
        SimpleAdjustment.warmth.apply(0, to: &e, asShot: camera)
        #expect(e.whiteBalance.asShot, "0 is the camera's own white balance again")
        #expect(SimpleAdjustment.warmth.value(in: e, asShot: camera) == 0)
    }

    @Test func warmthWithoutCameraDataStartsFromDaylight() {
        var e = EditState()
        SimpleAdjustment.warmth.apply(-100, to: &e, asShot: nil)
        #expect(e.whiteBalance.tint == 0)
        #expect(abs(e.whiteBalance.temperature - 1_000_000 / (1_000_000 / 5500 + 80)) <= 10)
        #expect(SimpleAdjustment.warmth.value(in: e, asShot: WhiteBalanceValue(kelvin: 0, tint: 0)) <= -99,
                "a zero Kelvin reading counts as unknown")
        // A custom white balance from Full mode reads relative to as shot, clamped.
        var full = EditState()
        full.whiteBalance.asShot = false
        full.whiteBalance.temperature = 12000
        #expect(SimpleAdjustment.warmth.value(in: full, asShot: camera) == 100)
        #expect(SimpleAdjustment.warmth.isAdjusted(full, asShot: camera))
    }

    @Test func modelSlidersAreUndoableEditsOfTheFocusedPhoto() async {
        let m = makeModel()
        #expect(m.simpleValue(.light) == 0, "no photo: nothing to read")
        m.setSimple(.light, 50) // no photo: nothing happens
        #expect(!m.history.canUndo)
        await m.start()
        guard let f = m.focusedID else { Issue.record("no photo"); return }
        m.setSimple(.light, 20)
        m.setSimple(.light, 50) // the same drag
        m.endEditGesture()
        #expect(m.edit(for: f).exposure.ev == 1)
        #expect(m.simpleValue(.light) == 50)
        #expect(m.history.undoLabel == "Brightness")
        m.setSimple(.warmth, 30)
        #expect(!m.edit(for: f).whiteBalance.asShot)
        m.undo()
        #expect(m.edit(for: f).whiteBalance.asShot)
        m.undo()
        #expect(m.edit(for: f).exposure.ev == 0, "the whole drag was one undo step")
    }

    @Test func switchingPersistsAndSays() {
        let m = makeModel()
        let s = m.settings
        let d = s.userDefaults
        #expect(!s.simpleMode, "Full mode by default")
        #expect(CommandCatalog.title(.simpleMode, model: m) == "Simple Mode")
        #expect(CommandCatalog.isEnabled(.simpleMode, model: m))
        #expect(CommandCatalog.perform(.simpleMode, model: m) == .none)
        #expect(s.simpleMode)
        #expect(m.toast?.message == SimpleModeText.switched(toSimple: true))
        #expect(AppSettings(defaults: d).simpleMode, "the choice is remembered")
        m.toast = nil
        m.setSimpleMode(true) // already on: no toast
        #expect(m.toast == nil)
        CommandCatalog.perform(.simpleMode, model: m)
        #expect(!s.simpleMode && !AppSettings(defaults: d).simpleMode)
        #expect(m.toast?.message == SimpleModeText.switched(toSimple: false))
        #expect(MenuCommand.simpleMode.shortcut == .init(key: "s", modifiers: [.command, .control]))
        #expect(SimpleModeText.switchHelp.contains("⌃⌘S"))
    }

    @Test func showingAToolLeavesSimpleMode() {
        let m = makeModel()
        let layout = ToolLayout(defaults: UserDefaults(suiteName: testSuiteName())!)
        m.settings.simpleMode = true
        ToolWorkspaceCommands.reveal(.history, model: m, layout: layout)
        #expect(!m.settings.simpleMode, "View ▸ Show History and the Tools menu need the full tools")
    }

    @Test func onboardingNewcomerStartsSimple() throws {
        let s = makeSettings()
        s.layoutPreset = .captureOne
        let o = OnboardingModel(settings: s, fileExists: { _ in true }, createDirectory: { _ in })
        #expect(!o.newToEditing)
        o.chooseNewToEditing()
        #expect(o.newToEditing && o.familiar == .luxtable)
        o.archiveEnabled = false
        try o.finish()
        #expect(s.simpleMode && s.layoutPreset == .luxtable && s.onboardingComplete)

        // Choosing an app afterwards means Full mode.
        let again = OnboardingModel(settings: s, fileExists: { _ in true }, createDirectory: { _ in })
        #expect(again.newToEditing, "starts from the current choice")
        again.choose(.lightroomClassic)
        #expect(!again.newToEditing && again.familiar == .lightroomClassic)
        again.archiveEnabled = false
        try again.finish()
        #expect(!s.simpleMode && s.layoutPreset == .lightroomClassic)
    }

    @Test func familiarWording() {
        #expect(FamiliarText.choiceTitle(.luxtable, offersNewcomer: true) == "Luxtable")
        #expect(FamiliarText.choiceTitle(.luxtable) == "Luxtable, or nothing yet")
        #expect(FamiliarText.newcomerSummary.contains("Simple mode"))
        #expect(FamiliarText.newcomerTitle.contains("new to photo editing"))
    }
}
