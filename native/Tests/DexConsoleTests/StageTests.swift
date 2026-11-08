import CoreText
import SwiftUI
import XCTest
@testable import DexConsole

final class StageTests: XCTestCase {
    func testFitMatchesElectronUseFit() {
        // Base stage: no stretch.
        var fit = Stage.fit(CGSize(width: 1174, height: 814))
        XCTAssertEqual(fit.scale, 1, accuracy: 1e-9)
        XCTAssertEqual(fit.stretch, 0, accuracy: 1e-9)
        // 13" iPad (4:3): the spare height goes to the lanes, no bars.
        fit = Stage.fit(CGSize(width: 1366, height: 1024))
        XCTAssertEqual(fit.scale, 1366 / 1174, accuracy: 1e-9)
        XCTAssertEqual((Stage.height + fit.stretch) * fit.scale, 1024, accuracy: 1e-6)
        // Taller than 4:3 caps the stretch and letterboxes.
        fit = Stage.fit(CGSize(width: 1024, height: 1366))
        XCTAssertEqual(fit.stretch, Stage.maxStretch, accuracy: 1e-9)
        XCTAssertEqual(Stage.maxStretch, 66.5, accuracy: 1e-9)
        // Wider than the stage: height-bound, no stretch.
        XCTAssertEqual(Stage.fit(CGSize(width: 2000, height: 814)).stretch, 0, accuracy: 1e-9)
        XCTAssertEqual(Stage.fit(.zero).scale, 1)
    }

    func testLabelsUseFractionalCSSWidths() {
        // Chromium lays the header's "SPLIT CUE" out at 66.11 pt: trailing
        // letter-spacing included, pair kerning off. SwiftUI would round to 67.
        XCTAssertEqual(Face.cond(13, tracking: 1.82).width(of: "SPLIT CUE"), 66.11, accuracy: 0.02)
    }

    func testLabelFaceCutsExist() {
        for weight in [Face.Weight.regular, .bold, .heavy] {
            let name = Face.cond(12, weight: weight).name
            XCTAssertEqual(CTFontCopyPostScriptName(CTFontCreateWithName(name as CFString, 12, nil)) as String, name)
        }
    }

    func testReadoutRowShrinksLikeChromium() {
        // Deck A's readouts as Chromium lays them out: REMAIN, time and TEMPO
        // keep their text widths; KEY stops at its chip, the BPM box takes the rest.
        let widths = flexShrink(bases: [83, 133.92, 67.42, 50, 76], weights: [83, 133.92, 67.42, 50, 74],
                                minimums: [83, 133.92, 67.42, 46.63, 0], available: 402)
        for (width, expected) in zip(widths, [83, 133.92, 67.42, 46.63, 71.02]) { XCTAssertEqual(width, expected, accuracy: 0.02) }
        XCTAssertEqual(flexShrink(bases: [10, 20], minimums: [0, 0], available: 100), [10, 20], "No overflow, no shrink")
    }

    func testReadoutFormatsMatchFormatTS() {
        XCTAssertTrue(remain(384 - (384 - 72.418)) == ("01:12", "418"))
        XCTAssertTrue(remain(418 - 0.91) == ("06:57", "090"))
        XCTAssertEqual(clock(311.582), "5:11")
        XCTAssertTrue(tempoParts(1.0231) == ("+", "2.31"))
        XCTAssertTrue(tempoParts(0.97) == ("−", "3.00"))
        XCTAssertTrue(bpmParts(130 * 1.0231) == ("133", "0"))
        XCTAssertNotNil(camelotColour("8A"))
        XCTAssertNil(camelotColour("13A"))
    }

    func testMixerReadoutsMatchElectronDemo() {
        let b = ConsoleState.demoHome.decks[1]
        XCTAssertEqual(MixerMath.formatDb(MixerMath.faderDb(b.eq.low)), "−43.8")
        XCTAssertEqual(MixerMath.formatDb(MixerMath.faderDb(b.eq.mid)), "−6.0")
        XCTAssertEqual(MixerMath.formatDb(MixerMath.faderDb(b.eq.high)), "−3.0")
        XCTAssertEqual(MixerMath.formatDb(MixerMath.faderDb(0)), "−∞")
        XCTAssertEqual(MixerMath.tempoText(1.0231), "+2.31%")
        XCTAssertEqual(MixerMath.tempoToFader(1), 0.5)
        XCTAssertEqual(filterLabel(0), "FILTER")
        XCTAssertEqual(filterLabel(-1), "LP 120")
        XCTAssertEqual(filterLabel(1), "HP 9.0k")
        XCTAssertEqual(filterLabel(0.02), "FILTER", "Inside the dead band")
    }

    @MainActor
    func testDemoStagesRender() throws {
        for (name, state) in ConsoleState.demos {
            let renderer = ImageRenderer(content: ConsoleStage(state: state, stretch: 20))
            let image = try XCTUnwrap(renderer.cgImage, name)
            XCTAssertEqual(image.width, 1174, name)
            XCTAssertEqual(image.height, 834, name)
        }
    }

    /// `icons/music.note.svg`'s path, by its bounds: the artwork inside the file's 15.01 × 24.75 viewBox.
    func testTheNoteFillsItsBox() {
        let bounds = NoteShape().path(in: CGRect(origin: .zero, size: NoteShape.size)).boundingRect
        XCTAssertEqual(bounds.minX, 0.28, accuracy: 0.01)
        XCTAssertEqual(bounds.maxX, 14.71, accuracy: 0.01)
        XCTAssertEqual(bounds.minY, 0.29, accuracy: 0.01)
        XCTAssertEqual(bounds.maxY, 24.48, accuracy: 0.01)
    }
}
