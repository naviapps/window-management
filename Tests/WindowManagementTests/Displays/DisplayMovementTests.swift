import CoreGraphics
import WindowManagement
import XCTest

final class DisplayMovementTests: XCTestCase {
  func testMoveCenterPreservingSizeKeepsFittingSizeCentered() {
    let windowFrame = CGRect(x: 0, y: 0, width: 120, height: 80)
    let visibleFrame = CGRect(x: 100, y: 200, width: 300, height: 200)
    let moved = DisplayMovement.centerPreservingSize(
      windowFrame: windowFrame,
      in: visibleFrame
    )

    XCTAssertEqual(moved, CGRect(x: 190, y: 260, width: 120, height: 80))
  }

  func testMovePreservingRelativePositionKeepsRelativeOrigin() {
    let windowFrame = CGRect(x: 50, y: 100, width: 100, height: 100)
    let source = CGRect(x: 0, y: 0, width: 200, height: 200)
    let target = CGRect(x: 300, y: 400, width: 400, height: 300)
    let moved = DisplayMovement.preservingRelativePosition(
      windowFrame: windowFrame,
      from: source,
      to: target
    )

    XCTAssertEqual(moved, CGRect(x: 450, y: 600, width: 100, height: 100))
  }
}
