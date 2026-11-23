import AppKit
import WindowManagement
import WindowManagementMacOS
import XCTest

@MainActor
final class AppKitDisplayProviderTests: XCTestCase {
  func testDisplaysMapCurrentNSDisplays() {
    let provider = AppKitDisplayProvider()
    let displays = provider.displays()
    let nsDisplays = NSScreen.screens

    XCTAssertFalse(displays.isEmpty)
    XCTAssertEqual(displays.count, nsDisplays.count)

    for (index, pair) in zip(displays, nsDisplays).enumerated() {
      let (display, nsDisplay) = pair
      XCTAssertEqual(display.displayIdentifier, nsDisplay.displayIdentifier)
      XCTAssertEqual(display.frame, nsDisplay.frame)
      XCTAssertEqual(display.visibleFrame, nsDisplay.visibleFrame)
      XCTAssertEqual(display.isMain, index == 0)
    }
  }

  func testProviderCanBeUsedThroughDisplayProvidingProtocol() {
    let provider: any DisplayProviding = AppKitDisplayProvider()
    let nsDisplays = NSScreen.screens

    XCTAssertEqual(provider.displays().count, nsDisplays.count)
  }

  func testProviderIsSendable() {
    assertSendable(AppKitDisplayProvider())
  }

  private func assertSendable<Value: Sendable>(_: Value) {}
}

extension NSScreen {
  fileprivate var displayIdentifier: CGDirectDisplayID? {
    let displayNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    return displayNumber.map { CGDirectDisplayID($0.uint32Value) }
  }
}
