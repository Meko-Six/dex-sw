import XCTest
@testable import DexAudio

/// The output's life, event by event, without a device: what each event does in each phase.
final class AudioLifecycleTests: XCTestCase {
    private let headphones = OutputLatency.Signature(device: "headphones", channels: 2, sampleRate: 48_000)
    private let speakers = OutputLatency.Signature(device: "speakers", channels: 2, sampleRate: 48_000)

    private func running(at now: Double = 0) -> AudioLifecycle {
        var life = AudioLifecycle()
        XCTAssertEqual(life.send(.start(engineRunning: false), now: now), [.start(delay: 0)])
        XCTAssertEqual(life.audioState, .recovering)
        XCTAssertEqual(life.send(.started(output: headphones, runningNow: true, outputNow: headphones), now: now),
                       [.finish(resume: [false, false], notice: nil)])
        XCTAssertEqual(life.phase, .running)
        XCTAssertEqual(life.audioState, .ready)
        return life
    }

    func testAStartOpensTheOutputOnceAndAgainOnlyIfItStopped() {
        var life = running()
        XCTAssertEqual(life.send(.start(engineRunning: true)), [], "Already open")
        XCTAssertEqual(life.send(.start(engineRunning: false), now: 9), [.start(delay: 0)], "Open again if the output stopped")
        XCTAssertEqual(life.send(.start(engineRunning: false), now: 9), [], "Not twice at once")
    }

    func testAnInterruptionKeepsWhatWasPlayingThroughAChangeOfConfiguration() {
        var life = running()
        XCTAssertEqual(life.send(.interruptionBegan(playing: [true, false])), [.suspend, .notice(.interrupted)])
        XCTAssertEqual(life.audioState, .interrupted)
        XCTAssertEqual(life.send(.configurationChanged), [], "Must not erase what to resume")
        XCTAssertEqual(life.send(.start(engineRunning: false)), [])
        XCTAssertEqual(life.send(.interruptionEnded(shouldResume: true), now: 5), [.start(delay: 0)])
        XCTAssertEqual(life.send(.started(output: headphones, runningNow: true, outputNow: headphones), now: 5),
                       [.finish(resume: [true, false], notice: nil)])
    }

    func testAnInterruptionThatShouldNotResumeAsksForPlay() {
        var life = running()
        _ = life.send(.interruptionBegan(playing: [true, true]))
        _ = life.send(.interruptionEnded(shouldResume: false), now: 5)
        XCTAssertEqual(life.send(.started(output: headphones, runningNow: true, outputNow: headphones), now: 5),
                       [.finish(resume: [false, false], notice: .readyPressPlay)])
    }

    func testAChangeOfOutputPausesAndNeverPlaysOnItsOwn() {
        var life = running()
        XCTAssertEqual(life.send(.outputChanged, now: 5), [.suspend, .start(delay: 0)])
        XCTAssertEqual(life.send(.started(output: speakers, runningNow: true, outputNow: speakers), now: 5),
                       [.finish(resume: [false, false], notice: .outputChangedPressPlay)])
        // During an interruption it stays paused, and forgets what it would have resumed.
        _ = life.send(.interruptionBegan(playing: [true, true]))
        XCTAssertEqual(life.send(.outputChanged), [.suspend, .notice(.outputChangedStaysPaused)])
        _ = life.send(.interruptionEnded(shouldResume: true), now: 9)
        XCTAssertEqual(life.send(.started(output: speakers, runningNow: true, outputNow: speakers), now: 9),
                       [.finish(resume: [false, false], notice: .readyPressPlay)])
    }

    func testAChangeDuringAStartIsHeldAndJudgedWhenItFinishes() {
        var life = AudioLifecycle()
        _ = life.send(.start(engineRunning: false), now: 0)
        XCTAssertEqual(life.send(.configurationNotice(now: 0.1, running: false, output: nil)), [])
        XCTAssertTrue(life.changePending)
        // The start ended on another output than it found: act on the change.
        XCTAssertEqual(life.send(.started(output: headphones, runningNow: true, outputNow: speakers), now: 0.2),
                       [.finish(resume: [false, false], notice: nil), .suspend, .start(delay: 0)])
        // Held again, but the start ended on the output it found: let go.
        _ = life.send(.configurationNotice(now: 0.3, running: false, output: nil))
        XCTAssertEqual(life.send(.started(output: speakers, runningNow: true, outputNow: speakers), now: 0.4),
                       [.finish(resume: [false, false], notice: .outputChangedPressPlay)])
        XCTAssertFalse(life.changePending)
    }

    func testOnlyTheStartsOwnEchoIsLetGo() {
        var life = running(at: 10)
        // Just after the start, still going into the same output: its own echo.
        XCTAssertEqual(life.send(.configurationNotice(now: 10.1, running: true, output: headphones)), [])
        // Just after, but another output: real.
        XCTAssertEqual(life.send(.configurationNotice(now: 10.1, running: true, output: speakers), now: 10.1),
                       [.suspend, .start(delay: 0)])
        life = running(at: 10)
        // Later, any change is real.
        XCTAssertEqual(life.send(.configurationNotice(now: 11, running: true, output: headphones), now: 11),
                       [.suspend, .start(delay: 0)])
    }

    func testAStartThatFailsMidChangeTriesOnceMoreAndNeverLoops() {
        var life = AudioLifecycle()
        _ = life.send(.start(engineRunning: false), now: 0)
        _ = life.send(.configurationNotice(now: 0.1, running: false, output: nil))
        XCTAssertEqual(life.send(.startFailed, now: 0.2), [.start(delay: AudioLifecycle.retryDelay)])
        XCTAssertEqual(life.audioState, .recovering)
        // The retry sets off its own notices and fails again: that's the end of it.
        _ = life.send(.configurationNotice(now: 0.8, running: false, output: nil))
        XCTAssertEqual(life.send(.startFailed, now: 0.9), [.fail])
        XCTAssertEqual(life.phase, .failed)
        XCTAssertEqual(life.audioState, .unavailable)
        // The app coming forward tries again, as before.
        XCTAssertEqual(life.send(.foreground(engineRunning: false), now: 20), [.suspend, .start(delay: 0)])
        XCTAssertEqual(life.send(.started(output: headphones, runningNow: true, outputNow: headphones), now: 20),
                       [.finish(resume: [false, false], notice: .readyPressPlay)])
    }

    func testAStartThatFailsWithNoChangeUnderWayFailsAtOnce() {
        var life = AudioLifecycle()
        _ = life.send(.start(engineRunning: false))
        XCTAssertEqual(life.send(.startFailed), [.fail])
        XCTAssertEqual(life.phase, .failed)
    }

    func testLostMediaServicesStayLostUntilReset() {
        var life = running()
        XCTAssertEqual(life.send(.servicesLost), [.suspend, .notice(.servicesRestarting)])
        XCTAssertEqual(life.audioState, .unavailable)
        XCTAssertEqual(life.send(.foreground(engineRunning: false)), [], "A foreground must not revive them")
        XCTAssertEqual(life.send(.start(engineRunning: false)), [])
        XCTAssertEqual(life.send(.interruptionBegan(playing: [true, false])), [])
        XCTAssertEqual(life.send(.willSleep), [.suspend, .notice(.pausedForSleep)])
        XCTAssertEqual(life.phase, .servicesLost, "Still lost after sleeping")
        XCTAssertEqual(life.send(.servicesReset), [.suspend, .rebuild])
        XCTAssertEqual(life.audioState, .recovering)
        XCTAssertEqual(life.send(.rebuilt, now: 3), [.start(delay: 0)])
        XCTAssertEqual(life.send(.started(output: headphones, runningNow: true, outputNow: headphones), now: 3),
                       [.finish(resume: [false, false], notice: .restoredPressPlay)])
    }

    func testSleepAndWakingAskForPlay() {
        var life = running()
        XCTAssertEqual(life.send(.willSleep), [.suspend, .notice(.pausedForSleep)])
        XCTAssertEqual(life.audioState, .unavailable)
        XCTAssertEqual(life.send(.foreground(engineRunning: true)), [], "Nothing to do if the output is still open")
        XCTAssertEqual(life.send(.foreground(engineRunning: false), now: 7), [.suspend, .start(delay: 0)])
        XCTAssertEqual(life.send(.started(output: headphones, runningNow: true, outputNow: headphones), now: 7),
                       [.finish(resume: [false, false], notice: .readyPressPlay)])
    }

    func testAfterShutdownOnlyAStartCounts() {
        var life = running()
        XCTAssertEqual(life.send(.shutdown), [])
        XCTAssertEqual(life.audioState, .unavailable)
        for event: AudioLifecycle.Event in [.outputChanged, .servicesLost, .willSleep, .foreground(engineRunning: false),
                                             .interruptionBegan(playing: [true, true]), .startFailed] {
            XCTAssertEqual(life.send(event), [], "\(event)")
        }
        XCTAssertEqual(life.send(.start(engineRunning: false)), [.start(delay: 0)])
    }

    func testAResultThatArrivesLateChangesNothing() {
        var life = running()
        _ = life.send(.interruptionBegan(playing: [false, false]))
        XCTAssertEqual(life.send(.started(output: headphones, runningNow: true, outputNow: headphones)), [])
        XCTAssertEqual(life.send(.startFailed), [])
        XCTAssertEqual(life.send(.rebuilt), [])
        XCTAssertEqual(life.audioState, .interrupted)
    }
}
