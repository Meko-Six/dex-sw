import CoreGraphics
import Testing
@testable import DexSlider

struct SpecTests {
    @Test func trimReadsSignedTenths() {
        #expect(SliderSpec.decibels(1.3) == "+1.3")
        #expect(SliderSpec.decibels(0.04) == "0")
        #expect(SliderSpec.decibels(-2.4) == "\u{2212}2.4")
    }

    @Test func eqReadsKillAtTheFoot() {
        let spec = SliderSpec.eq(deck: "A")
        #expect(spec.readout(0) == "KILL")
        #expect(spec.readout(0.62) == "62%")
        #expect(spec.readout(1) == "100%")
    }

    @Test func trimSnapsToTenthsWithoutNegativeZero() {
        let spec = SliderSpec.trim(deck: "A", auto: -3.2)
        #expect(spec.snap(1.26) == 1.3)
        #expect(spec.snap(-0.04).sign == .plus)
        #expect(spec.fill(0) == 0.5)
    }

    @Test func levelHasNoDoubleTapReset() {
        #expect(SliderSpec.level(deck: "A").reset == nil)
        #expect(SliderSpec.eq(deck: "B").reset == 1)
    }
}

struct TempoTests {
    let tuning = SliderTuning()

    @Test func upIsSlowerAsOnACDJ() {
        let spec = SliderSpec.tempo(bpm: 124)
        #expect(spec.fill(-16) == 1)
        #expect(spec.fill(16) == 0)
        var drag = SliderDrag(spec: spec, value: 2, at: CGPoint(x: 0, y: 300))
        drag.move(to: CGPoint(x: 0, y: 300 - tuning.tempoHeight / 32), travel: tuning.tempoHeight, tuning: tuning)
        #expect(drag.value == 1) // up 1/32 of the travel: 1 % slower
    }

    @Test func readsTenthsAndBPM() {
        let spec = SliderSpec.tempo(bpm: 124)
        #expect(spec.readout(2.42) == "+2.4%")
        #expect(spec.readout(0) == "0.0%")
        #expect(spec.readout(-3) == "\u{2212}3.0%")
        #expect(spec.caption(2.4) == "127.0 BPM")
    }

    @Test func sticksGentlyAtZero() {
        let spec = SliderSpec.tempo(bpm: 124)
        let travel = 320.0, unitsPerPoint = spec.span / travel
        var drag = SliderDrag(spec: spec, value: 1, at: CGPoint(x: 0, y: 300), detentWidth: 14 * unitsPerPoint)
        // Down is faster, so up 11 pt from +1 % reaches 0 …
        drag.move(to: CGPoint(x: 0, y: 289), travel: travel, tuning: tuning)
        #expect(drag.value == 0)
        #expect(drag.inDetent)
        // … and it holds there for the rest of its 14 pt …
        drag.move(to: CGPoint(x: 0, y: 277), travel: travel, tuning: tuning)
        #expect(drag.value == 0)
        // … then carries on, losing nothing past the detent.
        drag.move(to: CGPoint(x: 0, y: 266), travel: travel, tuning: tuning)
        #expect(drag.value == -1)
        #expect(!drag.inDetent)
    }

    @Test func fasterThanTheRangeStretchesDownward() {
        var drag = SliderDrag(spec: .tempo(bpm: 124), value: 16, at: CGPoint(x: 0, y: 300))
        drag.move(to: CGPoint(x: 0, y: 340), travel: 240, tuning: tuning)
        #expect(drag.value == 16)
        #expect(drag.overshoot(travel: 240) < 0)
    }
}

struct MasterSectionTests {
    @Test func blendReadsEachSide() {
        let spec = SliderSpec.cueMix()
        #expect(spec.readout(0.5) == "50/50")
        #expect(spec.readout(0.2) == "CUE 80")
        #expect(spec.readout(0.7) == "MST 70")
        #expect(spec.reset == 0.5)
    }

    @Test func nothingLoudResetsOnADoubleTap() {
        #expect(SliderSpec.phones().reset == nil)
        #expect(SliderSpec.master().reset == nil)
        #expect(SliderSpec.tempo(bpm: 120).reset == nil)
    }

    @Test func noMeterMeansAShorterPanel() {
        let tuning = SliderTuning()
        #expect(PanelPlacer.headerHeight(tuning, meter: false) < PanelPlacer.headerHeight(tuning))
    }
}

struct DragTests {
    let tuning = SliderTuning()

    @Test func touchingChangesNothing() {
        let drag = SliderDrag(spec: .level(deck: "A"), value: 0.4, at: CGPoint(x: 100, y: 300))
        #expect(drag.value == 0.4)
        #expect(!drag.moved)
    }

    @Test func barHeightCoversTheWholeRange() {
        var drag = SliderDrag(spec: .level(deck: "A"), value: 0, at: CGPoint(x: 100, y: 300))
        drag.move(to: CGPoint(x: 100, y: 300 - tuning.barHeight / 2), travel: tuning.barHeight, tuning: tuning)
        #expect(abs(drag.value - 0.5) < 1e-9)
        drag.move(to: CGPoint(x: 100, y: 300 - tuning.barHeight), travel: tuning.barHeight, tuning: tuning)
        #expect(drag.value == 1)
    }

    @Test func sidewaysSlowsTheDrag() {
        #expect(tuning.fineFactor(sideways: 20) == 1)
        #expect(tuning.fineFactor(sideways: -60) == 0.5)
        #expect(tuning.fineFactor(sideways: 120) == 0.25)
        #expect(tuning.fineFactor(sideways: 400) == 0.1)

        var drag = SliderDrag(spec: .trim(deck: "A", auto: 0), value: 0, at: CGPoint(x: 100, y: 300))
        // Out to ¼ speed first, then up the bar's height: a quarter of 24 dB.
        drag.move(to: CGPoint(x: 220, y: 300), travel: tuning.barHeight, tuning: tuning)
        drag.move(to: CGPoint(x: 220, y: 300 - tuning.barHeight), travel: tuning.barHeight, tuning: tuning)
        #expect(drag.value == 6)
    }

    @Test func pullingPastTheTopStretchesAndComesBackFirst() {
        var drag = SliderDrag(spec: .level(deck: "A"), value: 0.9, at: CGPoint(x: 0, y: 300))
        let tenth = tuning.barHeight / 10
        drag.move(to: CGPoint(x: 0, y: 300 - 3 * tenth), travel: tuning.barHeight, tuning: tuning)
        #expect(drag.value == 1)
        #expect(abs(drag.overshoot(travel: tuning.barHeight) - 2 * tenth) < 1e-9)
        // Back one tenth: still past the top, still full.
        drag.move(to: CGPoint(x: 0, y: 300 - 2 * tenth), travel: tuning.barHeight, tuning: tuning)
        #expect(drag.value == 1)
        // Back two more: one tenth under the top.
        drag.move(to: CGPoint(x: 0, y: 300), travel: tuning.barHeight, tuning: tuning)
        #expect(abs(drag.value - 0.9) < 1e-9)
        #expect(drag.overshoot(travel: tuning.barHeight) == 0)
    }

    @Test func rubberBandResistsAndNeverPassesTheBar() {
        let small = rubberBand(10, dimension: 200, coefficient: 0.55)
        #expect(small > 0 && small < 10)
        #expect(rubberBand(-10, dimension: 200, coefficient: 0.55) == -small)
        #expect(rubberBand(100_000, dimension: 200, coefficient: 0.55) < 200)
        #expect(rubberBand(10, dimension: 200, coefficient: 0) == 0)
    }
}

struct MeterTests {
    let rungs = MeterRungs(redDB: 0, stepDB: 2)

    @Test func sixRungsUpToRed() {
        #expect(rungs.thresholds == [-10, -8, -6, -4, -2, 0])
        #expect(rungs.reached(-20) == 0)
        #expect(rungs.reached(-5) == 3)
        #expect(rungs.reached(0.5) == 6)
    }

    @Test func heldRungStaysLit() {
        let value = MeterValue(level: -9, hold: -3)
        #expect(rungs.isLit(0, value))
        #expect(!rungs.isLit(1, value))
        #expect(rungs.isLit(3, value)) // −4, the held one
        #expect(!rungs.isLit(4, value))
    }

    @Test func outlineFollowsTheHold() {
        #expect(rungs.tone(MeterValue(level: -30, hold: -7)) == .green)
        #expect(rungs.tone(MeterValue(level: -30, hold: -5)) == .yellow)
        #expect(rungs.tone(MeterValue(level: -30, hold: 0)) == .red)
    }
}

struct PlacementTests {
    let tuning = { var tuning = SliderTuning(); tuning.placement = .outward; return tuning }()
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

    @Test func fillEdgeLinesUpWithTheFinger() {
        let chip = CGRect(x: 300, y: 380, width: 92, height: 52)
        let finger = CGPoint(x: 340, y: 400)
        let layout = PanelPlacer.place(chip: chip, finger: finger, fill: 0.25, bounds: bounds, tuning: tuning)
        let edge = layout.bar.maxY - layout.bar.height * 0.25
        #expect(abs(edge - finger.y) < 0.001)
    }

    @Test func outwardOpensAwayFromTheCentre() {
        let left = CGRect(x: 300, y: 380, width: 92, height: 52)
        let right = CGRect(x: 600, y: 380, width: 92, height: 52)
        let a = PanelPlacer.place(chip: left, finger: CGPoint(x: 340, y: 400), fill: 0.5, bounds: bounds, tuning: tuning)
        let b = PanelPlacer.place(chip: right, finger: CGPoint(x: 640, y: 400), fill: 0.5, bounds: bounds, tuning: tuning)
        #expect(a.frame.maxX <= left.minX)
        #expect(b.frame.minX >= right.maxX)
    }

    @Test func onFingerCentresOnTheFinger() {
        var onFinger = tuning
        onFinger.placement = .onFinger
        let chip = CGRect(x: 300, y: 380, width: 92, height: 52)
        let layout = PanelPlacer.place(chip: chip, finger: CGPoint(x: 340, y: 400), fill: 0.5, bounds: bounds, tuning: onFinger)
        #expect(abs(layout.bar.midX - 340) < 0.001)
    }

    @Test func staysInsideTheStage() {
        let chip = CGRect(x: 10, y: 10, width: 92, height: 52)
        let layout = PanelPlacer.place(chip: chip, finger: CGPoint(x: 20, y: 20), fill: 0, bounds: bounds, tuning: tuning)
        #expect(bounds.contains(layout.frame))
    }

    @Test func takesTheOtherSideRatherThanCoverAnOpenPanel() {
        let chip = CGRect(x: 300, y: 380, width: 92, height: 52)
        let first = PanelPlacer.place(chip: chip, finger: CGPoint(x: 340, y: 400), fill: 0.5, bounds: bounds, tuning: tuning)
        let second = PanelPlacer.place(chip: chip.offsetBy(dx: 0, dy: 60), finger: CGPoint(x: 340, y: 460), fill: 0.5,
                                       bounds: bounds, tuning: tuning, avoiding: [first.frame])
        #expect(!second.frame.intersects(first.frame))
    }
}

@MainActor
struct RouterTests {
    func bank() -> SliderBank {
        let bank = SliderBank()
        bank.setBounds(CGRect(x: 0, y: 0, width: 1000, height: 800))
        bank.addFader(SliderID("A", .level), spec: .level(deck: "A"), value: 1)
        bank.addFader(SliderID("B", .level), spec: .level(deck: "B"), value: 0)
        bank.add(SliderID("A", .trim), spec: .trim(deck: "A", auto: -2), value: 1.5)
        bank.setFrame(CGRect(x: 300, y: 600, width: 92, height: 52), for: SliderID("A", .level))
        bank.setFrame(CGRect(x: 600, y: 600, width: 92, height: 52), for: SliderID("B", .level))
        bank.setFrame(CGRect(x: 300, y: 100, width: 92, height: 52), for: SliderID("A", .trim))
        return bank
    }

    @Test func twoFingersCrossfadeTheLevels() {
        let bank = bank()
        let travel = bank.tuning.faderTravel(.level)
        bank.touchDown(1, at: CGPoint(x: 340, y: 620), time: 0)
        bank.touchDown(2, at: CGPoint(x: 640, y: 620), time: 0)
        #expect(bank.faders.count == 2)
        #expect(bank.panels.isEmpty) // faders never expand
        bank.touchMoved(1, to: CGPoint(x: 340, y: 620 + travel / 2))
        bank.touchMoved(2, to: CGPoint(x: 640, y: 620 - travel / 2))
        #expect(abs(bank.value(SliderID("A", .level)) - 0.5) < 1e-9)
        #expect(abs(bank.value(SliderID("B", .level)) - 0.5) < 1e-9)
    }

    @Test func aFingerKeepsItsControlOverAnother() {
        let bank = bank()
        bank.touchDown(1, at: CGPoint(x: 340, y: 620), time: 0)
        // Slides right across deck B's chip: still deck A's LEVEL, at ⅒ speed that far out.
        bank.touchMoved(1, to: CGPoint(x: 640, y: 620))
        bank.touchMoved(1, to: CGPoint(x: 640, y: 620 + bank.tuning.faderTravel(.level) / 4))
        #expect(abs(bank.value(SliderID("A", .level)) - 0.975) < 1e-9)
        #expect(bank.value(SliderID("B", .level)) == 0)
    }

    @Test func aSecondFingerCannotTakeAHeldControl() {
        let bank = bank()
        bank.touchDown(1, at: CGPoint(x: 340, y: 620), time: 0)
        bank.touchDown(2, at: CGPoint(x: 350, y: 630), time: 0)
        bank.touchMoved(2, to: CGPoint(x: 350, y: 900))
        #expect(bank.value(SliderID("A", .level)) == 1)
    }

    @Test func aTouchOutsideEveryChipIsIgnoredEvenIfItSlidesOntoOne() {
        let bank = bank()
        bank.touchDown(1, at: CGPoint(x: 50, y: 50), time: 0)
        bank.touchMoved(1, to: CGPoint(x: 340, y: 620))
        #expect(bank.panels.isEmpty)
    }

    @Test func doubleTapTrimGoesBackToAuto() {
        let bank = bank()
        let trim = SliderID("A", .trim)
        bank.touchDown(1, at: CGPoint(x: 340, y: 120), time: 10)
        bank.touchUp(1, at: CGPoint(x: 340, y: 120), time: 10.08)
        bank.touchDown(2, at: CGPoint(x: 342, y: 122), time: 10.2)
        #expect(bank.value(trim) == -2)
    }

    @Test func doubleTapLevelDoesNothing() {
        let bank = bank()
        let level = SliderID("B", .level)
        bank.touchDown(1, at: CGPoint(x: 640, y: 620), time: 10)
        bank.touchUp(1, at: CGPoint(x: 640, y: 620), time: 10.08)
        bank.touchDown(2, at: CGPoint(x: 640, y: 620), time: 10.2)
        #expect(bank.value(level) == 0)
    }

    @Test func syncLockRefusesTouches() {
        let bank = bank()
        let tempo = SliderID("A", .tempo)
        bank.addFader(tempo, spec: .tempo(bpm: 124), value: 0)
        bank.setFrame(CGRect(x: 100, y: 300, width: 56, height: 240), for: tempo)
        bank.setLocked(true, for: tempo)
        bank.touchDown(1, at: CGPoint(x: 120, y: 400), time: 0)
        bank.touchMoved(1, to: CGPoint(x: 120, y: 300))
        #expect(bank.value(tempo) == 0)
        #expect(bank.faders.isEmpty)
    }

    @Test func lockingLetsGoOfAFingerAlreadyOnIt() {
        let bank = bank()
        let level = SliderID("A", .level)
        bank.touchDown(1, at: CGPoint(x: 340, y: 620), time: 0)
        bank.setLocked(true, for: level)
        bank.touchMoved(1, to: CGPoint(x: 340, y: 700))
        #expect(bank.value(level) == 1)
    }

    @Test func reportsEveryChange() {
        let bank = bank()
        var heard: [Double] = []
        bank.onChange = { _, value in heard.append(value) }
        bank.touchDown(1, at: CGPoint(x: 640, y: 620), time: 0)
        bank.touchMoved(1, to: CGPoint(x: 640, y: 620 - bank.tuning.faderTravel(.level)))
        #expect(heard == [1])
    }
}

struct FXTests {
    let tuning = SliderTuning()

    @Test func readsOffAndASignedPercent() {
        let spec = SliderSpec.fx(deck: "A")
        #expect(spec.readout(0) == "OFF")
        #expect(spec.readout(-40) == "\u{2212}40%")
        #expect(spec.readout(40) == "+40%")
        #expect(spec.caption(0) == "FILTER")
        #expect(spec.caption(40) == "FILTER HP")
        #expect(spec.with(.reverb).caption(-40) == "REVERB LP")
    }

    @Test func fillsFromTheCentreAndResetsToOff() {
        let spec = SliderSpec.fx(deck: "A")
        #expect(spec.fill(0) == 0.5)
        #expect(spec.reset == 0)
        #expect(spec.title == "FILTER")
    }

    @Test func upIsHighPassUnlessFlipped() {
        for upIsHighPass in [true, false] {
            let spec = SliderSpec.fx(deck: "A", upIsHighPass: upIsHighPass)
            var drag = SliderDrag(spec: spec, value: 0, at: CGPoint(x: 0, y: 300))
            drag.move(to: CGPoint(x: 0, y: 260), travel: tuning.barHeight, tuning: tuning)
            #expect(upIsHighPass ? drag.value > 0 : drag.value < 0)
        }
    }

    @Test func changingTheEffectKeepsTheDirection() {
        let spec = SliderSpec.fx(deck: "B", upIsHighPass: false).with(.gater)
        #expect(spec.effect == .gater)
        #expect(spec.title == "GATER")
        #expect(spec.invert)
    }
}

@MainActor
struct EffectPickerTests {
    let fx = SliderID("A", .fx)
    let chip = CGRect(x: 300, y: 300, width: 105, height: 58)

    func bank() -> SliderBank {
        let bank = SliderBank()
        bank.setBounds(CGRect(x: 0, y: 0, width: 1000, height: 800))
        bank.add(fx, spec: .fx(deck: "A"), value: -30)
        bank.setFrame(chip, for: fx)
        bank.add(SliderID("A", .trim), spec: .trim(deck: "A", auto: 0), value: 0)
        bank.setFrame(CGRect(x: 300, y: 100, width: 105, height: 58), for: SliderID("A", .trim))
        return bank
    }

    var centre: CGPoint { CGPoint(x: chip.midX, y: chip.midY) }

    @Test func holdingStillBringsUpTheListWithTheCurrentEffectUnderTheFinger() {
        let bank = bank()
        bank.touchDown(1, at: centre, time: 0)
        bank.longPress(1)
        let picker = bank.pickers[fx]
        #expect(picker?.current == 0)
        #expect(picker?.rows[0].contains(centre) == true)
        #expect(bank.panels[fx]?.closing == true)
    }

    @Test func slidingToAnEffectAndLiftingTakesIt() {
        let bank = bank()
        bank.touchDown(1, at: centre, time: 0)
        bank.longPress(1)
        let below = CGPoint(x: centre.x, y: centre.y + 2 * (PickerPlacer.rowHeight + PickerPlacer.gap))
        bank.touchMoved(1, to: below)
        #expect(bank.pickers[fx]?.highlighted == 2)
        bank.touchUp(1, at: below, time: 1)
        #expect(bank.controls[fx]?.spec.effect == .delay)
        #expect(bank.value(fx) == -30) // the amount stays
        #expect(bank.pickers.isEmpty)
    }

    @Test func liftingWithoutSlidingWaitsForATap() {
        let bank = bank()
        bank.touchDown(1, at: centre, time: 0)
        bank.longPress(1)
        bank.touchUp(1, at: centre, time: 1)
        #expect(bank.pickers[fx]?.touching == false)
        let reverb = bank.pickers[fx]!.rows[1]
        bank.touchDown(2, at: CGPoint(x: reverb.midX, y: reverb.midY), time: 2)
        #expect(bank.controls[fx]?.spec.effect == .reverb)
        #expect(bank.pickers.isEmpty)
        #expect(bank.panels[fx]?.touching != true) // the tap took the row, not the chip
    }

    @Test func aTouchElsewherePutsTheListAwayAndStillWorks() {
        let bank = bank()
        bank.touchDown(1, at: centre, time: 0)
        bank.longPress(1)
        bank.touchUp(1, at: centre, time: 1)
        bank.touchDown(2, at: CGPoint(x: 350, y: 120), time: 2)
        #expect(bank.pickers.isEmpty)
        #expect(bank.controls[fx]?.spec.effect == .filter)
        #expect(bank.panels[SliderID("A", .trim)] != nil)
    }

    @Test func aFingerThatMovedNeverBringsUpTheList() {
        let bank = bank()
        bank.touchDown(1, at: centre, time: 0)
        bank.touchMoved(1, to: CGPoint(x: centre.x, y: centre.y - 30))
        bank.longPress(1)
        #expect(bank.pickers.isEmpty)
    }

    @Test func onlyFXChipsHaveAList() {
        let bank = bank()
        bank.touchDown(1, at: CGPoint(x: 350, y: 120), time: 0)
        bank.longPress(1)
        #expect(bank.pickers.isEmpty)
    }
}
