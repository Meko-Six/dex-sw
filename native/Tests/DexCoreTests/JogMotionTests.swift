import XCTest
@testable import DexCore

final class JogMotionTests: XCTestCase {
    func testAFlickTravelsTheSameTrackDistanceAtEveryZoom() throws {
        // The same hand speed on the screen, in points a second, from fully in to fully out.
        for points in [100.0, 300.0, 1000.0, 4000.0] {
            let expected = min(JogFling.longestDistance, points / 1050 * JogFling.referenceSpan / JogFling.referenceDamping)
            for span in [3.0, 6, 12, 24, 48] {
                let velocity = points / 1050 * span, speed = min(8, velocity)
                let damping = JogFling.damping(velocity: velocity, speed: speed, span: span)
                let coast = try XCTUnwrap(JogCoast(position: 100, velocity: speed, bounds: 0...1000, damping: damping,
                                                   stopSpeed: 0.06, maximumDuration: 6))
                let travelled = coast.sample(at: coast.duration).position - 100
                XCTAssertEqual(travelled, expected, accuracy: 0.06 / damping + 0.12, "\(points) pt/s at \(span) s")
                XCTAssertEqual(coast.sample(at: 0).velocity, speed, accuracy: 1e-9, "The coast starts at the lane's speed")
            }
        }
    }
    func testTheHardestFlickIsHalfWhatItWasAtTheDefaultZoom() {
        XCTAssertEqual(JogFling.longestDistance, 8 / 1.2 / 2, accuracy: 1e-9)
        XCTAssertEqual(JogFling.damping(velocity: 8, speed: 8, span: 12), 2.4, accuracy: 1e-9)
    }
    func testZoomingInMakesTheSameFlickLookBigger() {
        // Screen travel for one hand speed: track distance over the seconds the lane shows.
        let travel = [3.0, 12, 48].map { span in JogFling.distance(velocity: 300.0 / 1050 * span, span: span) / span }
        XCTAssertGreaterThan(travel[0], travel[1])
        XCTAssertGreaterThan(travel[1], travel[2])
    }
    func testCoastContinuesInReleaseDirectionSlowsAndStopsIndependentlyOfFrameRate() throws {
        for velocity in [-12.0, 12] {
            let coast = try XCTUnwrap(JogCoast(position: 50, velocity: velocity, bounds: 0...100, stopSpeed: 0.08))
            let a = coast.sample(at: 0.1), b = coast.sample(at: 0.2)
            XCTAssertGreaterThan((a.position - 50) * velocity, 0)
            XCTAssertGreaterThan((b.position - a.position) * velocity, 0)
            XCTAssertLessThan(abs(b.velocity), abs(a.velocity))
            let end = coast.sample(at: coast.duration)
            XCTAssertTrue(end.finished); XCTAssertEqual(end.velocity, 0)
            for frames in [30, 60, 120] {
                var last = coast.sample(at: 0)
                for i in 1...Int(ceil(coast.duration * Double(frames))) { last = coast.sample(at: Double(i) / Double(frames)) }
                XCTAssertEqual(last.position, end.position, accuracy: 1e-12)
            }
            XCTAssertEqual(coast.sample(at: 100), end)
        }
    }
    func testTrackEdgesAndStationaryReleaseStopWithoutBounceOrOvershoot() throws {
        for (start, velocity, edge) in [(0.1, -20.0, 0.0), (99.9, 20.0, 100.0)] {
            let coast = try XCTUnwrap(JogCoast(position: start, velocity: velocity, bounds: 0...100, stopSpeed: 0.08))
            XCTAssertLessThan(coast.duration, 0.01)
            XCTAssertEqual(coast.sample(at: 1).position, edge, accuracy: 1e-9)
            XCTAssertTrue(coast.sample(at: 1).finished)
        }
        let still = try XCTUnwrap(JogCoast(position: 20, velocity: 0.01, bounds: 0...100, stopSpeed: 0.08))
        XCTAssertEqual(still.duration, 0); XCTAssertEqual(still.sample(at: 1).position, 20)
        XCTAssertNil(JogCoast(position: .nan, velocity: 1, bounds: 0...100, stopSpeed: 0.08))
    }
    func testVelocityUsesRecentMotionAndExpiresWhenFingerStops() {
        var motion = JogVelocity()
        motion.add(position: 0, at: 1)
        motion.add(position: 2, at: 1.02)
        motion.add(position: 4, at: 1.04)
        XCTAssertEqual(motion.velocity(at: 1.05), 100, accuracy: 1e-9)
        XCTAssertEqual(motion.velocity(at: 1.2), 0)
        motion.add(position: 900, at: 1.04)
        motion.add(position: .infinity, at: 1.05)
        XCTAssertEqual(motion.velocity(at: 1.05), 100, accuracy: 1e-9)
        motion.add(position: 4, at: 1.3)
        XCTAssertEqual(motion.velocity(at: 1.3), 0)
        motion.add(position: 5, at: 1.32)
        motion.add(position: 6, at: 1.34)
        motion.add(position: 5.5, at: 1.36)
        XCTAssertEqual(motion.velocity(at: 1.36), -25, accuracy: 1e-9)
    }
}
