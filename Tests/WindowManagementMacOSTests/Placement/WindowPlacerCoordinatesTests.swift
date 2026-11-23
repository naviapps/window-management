import CoreGraphics
import WindowManagement
import XCTest

@testable import WindowManagementMacOS

@MainActor
final class WindowPlacerCoordinatesTests: XCTestCase {
  func testFillKeepsMenuBarAndDockOffsetsInAccessibilityCoordinates() throws {
    let frameController = AccessibilityFrameFixture(
      frame: CGRect(x: 100, y: 100, width: 200, height: 100))
    let placer = makePlacer(frameController: frameController)

    try placer.place(.fill, for: .focused, display: .displayIdentifier(1))

    XCTAssertEqual(frameController.currentFrame, CGRect(x: 0, y: 25, width: 1440, height: 825))
  }

  func testFirstGridRowIsAtTheTopForLiveAccessibilityPlacement() throws {
    let frameController = AccessibilityFrameFixture(frame: .zero)
    let placer = makePlacer(frameController: frameController)

    try placer.place(
      .grid(columns: 1, rows: 2, column: 0, row: 0, columnSpan: 1, rowSpan: 1),
      for: .focused,
      display: .displayIdentifier(1)
    )

    XCTAssertEqual(frameController.currentFrame, CGRect(x: 0, y: 25, width: 1440, height: 412.5))
  }

  func testContainingWindowResolvesDisplayAbovePrimaryWithNegativeAccessibilityY() throws {
    let frameController = AccessibilityFrameFixture(
      frame: CGRect(x: 100, y: -800, width: 200, height: 100))
    let placer = makePlacer(frameController: frameController)

    try placer.place(.fill, for: .focused, displayFallback: .none)

    XCTAssertEqual(frameController.currentFrame, CGRect(x: 0, y: -900, width: 1440, height: 900))
  }

  func testMainTargetUsesPrimaryWhenFocusedWindowIsOnSecondaryDisplay() throws {
    let frameController = AccessibilityFrameFixture(
      frame: CGRect(x: 100, y: -800, width: 200, height: 100))
    let placer = makePlacer(frameController: frameController, primaryIndex: 0)

    try placer.place(.fill, for: .focused, displayFallback: .none)
    XCTAssertEqual(frameController.currentFrame, CGRect(x: 0, y: -900, width: 1440, height: 900))

    try placer.place(.fill, for: .focused, display: .main, displayFallback: .none)
    XCTAssertEqual(frameController.currentFrame, CGRect(x: 0, y: 25, width: 1440, height: 825))
  }

  func testMoveToDisplayAbovePrimaryCentersInAccessibilityCoordinates() throws {
    let frameController = AccessibilityFrameFixture(
      frame: CGRect(x: 100, y: 100, width: 200, height: 100))
    let placer = makePlacer(frameController: frameController)

    try placer.moveToAdjacentDisplay(
      .next, for: .focused, preservingRelativePosition: false, displayFallback: .none)

    XCTAssertEqual(frameController.currentFrame, CGRect(x: 620, y: -500, width: 200, height: 100))
  }

  func testPointTargetResolvesDisplayBelowPrimaryInAccessibilityCoordinates() throws {
    let frameController = AccessibilityFrameFixture(frame: .zero)
    let placer = makePlacer(frameController: frameController, secondaryY: -900)

    try placer.place(
      .fill, for: .focused, display: .point(CGPoint(x: 100, y: 1000)), displayFallback: .none)

    XCTAssertEqual(frameController.currentFrame, CGRect(x: 0, y: 900, width: 1440, height: 900))
  }

  private func makePlacer(
    frameController: AccessibilityFrameFixture, secondaryY: CGFloat = 900, primaryIndex: Int = 1
  ) -> WindowPlacer {
    let appKitDisplays = AppKitDisplayFixture(secondaryY: secondaryY, primaryIndex: primaryIndex)
    let accessibilityDisplays = AccessibilityDisplayProvider(
      appKitDisplayProvider: appKitDisplays
    )
    return WindowPlacer(frameController: frameController, displayProvider: accessibilityDisplays)
  }
}

@MainActor
private final class AccessibilityFrameFixture: WindowFrameControlling {
  var currentFrame: CGRect

  init(frame: CGRect) {
    currentFrame = frame
  }

  func frame(for _: WindowTarget) throws -> CGRect {
    currentFrame
  }

  func setFrame(_ frame: CGRect, for _: WindowTarget) throws {
    currentFrame = frame
  }
}

private struct AppKitDisplayFixture: DisplayProviding {
  let secondaryY: CGFloat
  // Some coordinate tests deliberately place the main flag on a different display.
  let primaryIndex: Int

  @MainActor
  func displays() -> [Display] {
    [
      Display(
        displayIdentifier: 1,
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 50, width: 1440, height: 825),
        isMain: primaryIndex == 0
      ),
      Display(
        displayIdentifier: 2,
        frame: CGRect(x: 0, y: secondaryY, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: secondaryY, width: 1440, height: 900),
        isMain: primaryIndex == 1
      ),
    ]
  }
}
