import SwiftUI
import XCTest
@testable import DexConsole

final class PlatterGripTests: XCTestCase {
    func testOnlyTheExposedArcCanStartAJog() {
        let bounds = CGRect(x: 0, y: 0, width: Layout.platter.size, height: Layout.platter.size)
        for deck in ["A", "B"] {
            let grip = PlatterGrip(deck: deck).path(in: bounds)
            let cut = deck == "A" ? bounds.maxX - Layout.tuckedRim : Layout.tuckedRim
            let away: CGFloat = deck == "A" ? -1 : 1
            XCTAssertTrue(grip.contains(CGPoint(x: cut + away, y: bounds.midY)))
            XCTAssertFalse(grip.contains(CGPoint(x: cut - away, y: bounds.midY)))
            XCTAssertTrue(grip.contains(CGPoint(x: bounds.midX, y: bounds.midY)))
            XCTAssertFalse(grip.contains(CGPoint(x: deck == "A" ? 1 : bounds.maxX - 1, y: 1)))
        }
    }
}
