import WindowManagement
import XCTest

final class WindowTargetTests: XCTestCase {
  func testWindowIdentifierStoresIdentifier() {
    let target = WindowTarget.windowIdentifier(456)

    guard case .windowIdentifier(let identifier) = target else {
      return XCTFail("Expected window identifier target.")
    }

    XCTAssertEqual(identifier, 456)
  }

  func testWindowTargetValueConformance() throws {
    try assertValueConformance(WindowTarget.focused)
    try assertValueConformance(WindowTarget.windowIdentifier(456))
  }

  func testWindowTargetIsSendable() {
    assertSendable(WindowTarget.focused)
    assertSendable(WindowTarget.windowIdentifier(456))
  }

  private func assertSendable<Value: Sendable>(_: Value) {}
}
