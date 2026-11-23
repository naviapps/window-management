import CoreGraphics
import WindowManagement
import XCTest

final class DisplayTests: XCTestCase {
  func testInitSanitizesNonFiniteFrames() {
    let display = Display(
      frame: CGRect(x: .infinity, y: .nan, width: .infinity, height: -.infinity),
      visibleFrame: CGRect(x: .nan, y: .infinity, width: -.infinity, height: .nan)
    )

    XCTAssertEqual(display.frame, .zero)
    XCTAssertEqual(display.visibleFrame, .zero)
  }

  private let fullFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
  private let visibleFrame = CGRect(x: 0, y: 24, width: 800, height: 576)

  func testInitUsesDefaultMetadata() {
    let display = makeDisplay()

    XCTAssertNil(display.displayIdentifier)
    XCTAssertFalse(display.isMain)
  }

  func testInitStoresMetadata() {
    let display = makeDisplay(displayIdentifier: 123, isMain: true)

    XCTAssertEqual(display.displayIdentifier, 123)
    XCTAssertTrue(display.isMain)
  }

  func testFrameReturnsRequestedDisplayArea() {
    let display = makeDisplay()

    XCTAssertEqual(display.frame(for: .full), fullFrame)
    XCTAssertEqual(display.frame(for: .visible), visibleFrame)
  }

  func testRestoredDisplayUsesTheSameBoundsAsAConstructedDisplay() throws {
    let saved = Data(
      #"{"displayIdentifier":123,"frame":[[800,600],[-800,-600]],"visibleFrame":[[800,600],[-780,-560]],"isMain":true}"#
        .utf8)
    let restored = try JSONDecoder().decode(Display.self, from: saved)
    let constructed = Display(
      displayIdentifier: 123,
      frame: CGRect(x: 800, y: 600, width: -800, height: -600),
      visibleFrame: CGRect(x: 800, y: 600, width: -780, height: -560),
      isMain: true)

    XCTAssertEqual(restored, constructed)
    XCTAssertEqual(restored.frame.origin, .zero)
    XCTAssertEqual(restored.visibleFrame.origin, CGPoint(x: 20, y: 40))
  }

  func testDisplayValueConformance() throws {
    try assertValueConformance(makeDisplay())
    try assertValueConformance(makeDisplay(displayIdentifier: 123, isMain: true))
  }

  func testDisplayIsSendable() {
    assertSendable(makeDisplay(displayIdentifier: 123, isMain: true))
  }

  private func makeDisplay(
    displayIdentifier: CGDirectDisplayID? = nil,
    isMain: Bool = false
  ) -> Display {
    Display(
      displayIdentifier: displayIdentifier,
      frame: fullFrame,
      visibleFrame: visibleFrame,
      isMain: isMain
    )
  }

  private func assertSendable<Value: Sendable>(_: Value) {}
}
