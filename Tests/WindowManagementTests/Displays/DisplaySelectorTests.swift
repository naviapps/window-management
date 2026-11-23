import CoreGraphics
import WindowManagement
import XCTest

final class DisplaySelectorTests: XCTestCase {
  func testDisplayResolvesTargets() {
    let primary = makeDisplay(
      CGRect(x: 0, y: 0, width: 200, height: 200),
      displayIdentifier: 1,
      isMain: true
    )
    let secondary = makeDisplay(
      CGRect(x: 200, y: 0, width: 200, height: 200),
      displayIdentifier: 2
    )
    let displays = [secondary, primary]

    for (target, frame, expected): (DisplayTarget, CGRect, Display) in [
      (.main, secondary.frame, primary),
      (.containingWindow, secondary.frame, secondary),
      (.displayIdentifier(2), primary.frame, secondary),
      (.point(CGPoint(x: 210, y: 10)), primary.frame, secondary),
      (.orderedIndex(1), primary.frame, secondary),
    ] {
      XCTAssertEqual(
        DisplaySelector.display(for: target, windowFrame: frame, in: displays, fallback: .none),
        expected)
    }
  }

  func testMissingDisplayUsesPublicFallbackDefaultAndRespectsExplicitNone() {
    let right = makeDisplay(CGRect(x: 300, y: 0, width: 200, height: 200))
    let left = makeDisplay(CGRect(x: 0, y: 0, width: 200, height: 200))
    let target = DisplayTarget.displayIdentifier(99)
    let displays = [right, left]

    XCTAssertEqual(
      DisplaySelector.display(for: target, windowFrame: right.frame, in: displays), left)
    XCTAssertNil(
      DisplaySelector.display(for: target, windowFrame: right.frame, in: displays, fallback: .none))
    XCTAssertNil(DisplaySelector.display(for: target, windowFrame: right.frame, in: []))
  }

  func testInvalidTargetsOnlyResolveWithFallbackOrRequestNormalization() {
    let display = makeDisplay(CGRect(x: 0, y: 0, width: 100, height: 80), displayIdentifier: 0)
    XCTAssertEqual(
      DisplaySelector.display(
        for: .displayIdentifier(0), windowFrame: .zero, in: [display], fallback: .none), display)
    for target in [DisplayTarget.point(CGPoint(x: CGFloat.nan, y: 10)), .orderedIndex(-1)] {
      XCTAssertNil(
        DisplaySelector.display(
          for: target, windowFrame: .zero, in: [display], fallback: .none))
      XCTAssertEqual(
        DisplaySelector.display(for: target, windowFrame: .zero, in: [display]), display)
      let request = WindowPlacementRequest(placement: .fill, display: target)
      XCTAssertEqual(
        DisplaySelector.display(
          for: request.display, windowFrame: .zero, in: [display], fallback: .none), display)
    }
  }

  func testIndexContainingPointProjectsOrderedIndexAndMissingResult() {
    let right = makeDisplay(CGRect(x: 300, y: 0, width: 200, height: 200))
    let left = makeDisplay(CGRect(x: 0, y: 0, width: 200, height: 200))
    let displays = [right, left]

    XCTAssertEqual(DisplaySelector.index(containing: CGPoint(x: 350, y: 10), in: displays), 1)
    XCTAssertNil(DisplaySelector.index(containing: CGPoint(x: 500, y: 10), in: displays))
  }

  func testDisplayOrderReturnsOriginalValuesWithTiedAndMissingIdentifiers() {
    let primary = makeDisplay(
      CGRect(x: 0, y: 0, width: 100, height: 100), displayIdentifier: 1,
      visibleFrame: CGRect(x: 0, y: 10, width: 100, height: 90))
    let larger = makeDisplay(
      CGRect(x: -0.0, y: -0.0, width: 200, height: 100), displayIdentifier: 0)
    let higherIdentifier = makeDisplay(
      CGRect(x: -0.0, y: 0, width: 100, height: 100), displayIdentifier: 9)
    let missingIdentifier = makeDisplay(CGRect(x: 0, y: -0.0, width: 100, height: 100))
    let duplicateIdentifier = makeDisplay(
      CGRect(x: -0.0, y: -0.0, width: 100, height: 100), displayIdentifier: 1,
      visibleFrame: CGRect(x: 0, y: 20, width: 100, height: 80))
    let displays = [primary, larger, higherIdentifier, missingIdentifier, duplicateIdentifier]
    let ordered = DisplaySelector.orderedDisplays(from: displays)
    XCTAssertEqual(
      ordered, [primary, duplicateIdentifier, higherIdentifier, missingIdentifier, larger])
    XCTAssertEqual(ordered[2].frame.origin.x.sign, .minus)
    XCTAssertEqual(ordered[3].frame.origin.y.sign, .minus)
    XCTAssertEqual(
      DisplaySelector.orderedDisplays(from: [duplicateIdentifier, primary]),
      [duplicateIdentifier, primary])
  }

  func testAdjacentIndexPreservesTheNativeSignedIntegerWidth() {
    XCTAssertEqual(
      DisplaySelector.adjacentIndex(
        from: Int.min,
        direction: .previous,
        displayCount: Int.max
      ),
      Int.max - 2
    )
    XCTAssertNil(
      DisplaySelector.adjacentIndex(from: Int.max, direction: .next, displayCount: Int.min))
  }

  private func makeDisplay(
    _ frame: CGRect,
    displayIdentifier: CGDirectDisplayID? = nil,
    visibleFrame: CGRect? = nil,
    isMain: Bool = false
  ) -> Display {
    Display(
      displayIdentifier: displayIdentifier,
      frame: frame,
      visibleFrame: visibleFrame ?? frame,
      isMain: isMain
    )
  }
}
