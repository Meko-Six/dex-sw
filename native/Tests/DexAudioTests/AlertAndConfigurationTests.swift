import XCTest
@testable import DexAudio

@MainActor
final class AlertAndConfigurationTests: XCTestCase {
    func testADeckProblemRaisedAgainWithTheSameWordsCountsAgain() throws {
        let mixer = NativeMixer()
        defer { mixer.shutdown() }
        try mixer.enableOfflineRendering()
        mixer.a.toggleLoop()   // No track, so no grid: refused.
        let words = try XCTUnwrap(mixer.a.error)
        let first = mixer.a.errorRevision
        mixer.a.toggleLoop()
        XCTAssertEqual(mixer.a.error, words)
        XCTAssertEqual(mixer.a.errorRevision, first &+ 1)
        XCTAssertEqual(mixer.b.errorRevision, 0, "The other deck raised nothing")
    }

    func testAConfigurationChangeIsHeldDuringAStartAndOnlyTheStartsOwnEchoIsLetGo() {
        // While a start is under way nothing can be judged, whatever else is true.
        for running in [false, true] {
            for same in [false, true] {
                XCTAssertEqual(ConfigurationChange.decide(starting: true, settling: true, running: running, sameOutput: same), .wait)
                XCTAssertEqual(ConfigurationChange.decide(starting: true, settling: false, running: running, sameOutput: same), .wait)
            }
        }
        // Just after a start, the engine still going into the same output: the start's echo.
        XCTAssertEqual(ConfigurationChange.decide(starting: false, settling: true, running: true, sameOutput: true), .ignore)
        // Just after a start, but the output is another one, or the engine has stopped: real.
        XCTAssertEqual(ConfigurationChange.decide(starting: false, settling: true, running: true, sameOutput: false), .act)
        XCTAssertEqual(ConfigurationChange.decide(starting: false, settling: true, running: false, sameOutput: true), .act)
        // Any other time it is acted on, as before.
        XCTAssertEqual(ConfigurationChange.decide(starting: false, settling: false, running: true, sameOutput: true), .act)
    }
}
