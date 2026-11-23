import CoreGraphics
import WindowManagement
import XCTest

final class WindowPlacementCalculatorTests: XCTestCase {
  func testFillReturnsInsetDisplayArea() {
    let displayArea = CGRect(x: 10, y: 20, width: 300, height: 200)
    XCTAssertEqual(
      WindowPlacementCalculator.frame(for: .fill, in: displayArea, inset: 10),
      CGRect(x: 20, y: 30, width: 280, height: 180)
    )
  }

  func testGridPlacementCalculatesTopRowCell() {
    let displayArea = CGRect(x: 0, y: 0, width: 300, height: 200)
    XCTAssertEqual(
      WindowPlacementCalculator.frame(
        for: .grid(columns: 3, rows: 2, column: 1, row: 1, columnSpan: 1, rowSpan: 1),
        in: displayArea
      ),
      CGRect(x: 100, y: 100, width: 100, height: 100)
    )
  }

  func testGridPreservesSubnormalCoordinatesAcrossTheNativeBoundary() {
    let smallest = CGFloat.leastNonzeroMagnitude
    XCTAssertEqual(
      WindowPlacementCalculator.frame(
        for: .grid(columns: 8, rows: 8, column: 4, row: 4, columnSpan: 4, rowSpan: 4),
        in: CGRect(x: 0, y: 0, width: 2 * smallest, height: 2 * smallest)),
      CGRect(x: smallest, y: smallest, width: smallest, height: smallest))
  }

  func testCenteredClampsNonFiniteRatios() {
    let displayArea = CGRect(x: 0, y: 0, width: 200, height: 100)

    XCTAssertEqual(
      WindowPlacementCalculator.frame(
        for: .centered(widthRatio: .infinity, heightRatio: .nan), in: displayArea),
      CGRect(x: 0, y: 50, width: 200, height: 0)
    )
  }
}
