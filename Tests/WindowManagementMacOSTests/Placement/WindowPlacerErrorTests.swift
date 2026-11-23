import WindowManagement
import WindowManagementMacOS
import XCTest

final class WindowPlacerErrorTests: XCTestCase {
  func testWindowPlacerErrorIsSendable() {
    assertSendable(WindowPlacerError.displayNotFound(.displayIdentifier(1)))
  }

  func testWindowPlacerErrorIsHashable() {
    assertHashable(WindowPlacerError.displayNotFound(.displayIdentifier(1)))
  }

  func testWindowPlacerErrorEquatableMatchesIdenticalValues() {
    XCTAssertEqual(
      WindowPlacerError.displayNotFound(.displayIdentifier(1)),
      .displayNotFound(.displayIdentifier(1))
    )
  }

  func testWindowPlacerErrorEquatableDistinguishesAssociatedValues() {
    XCTAssertNotEqual(
      WindowPlacerError.displayNotFound(.main),
      .displayNotFound(.displayIdentifier(1))
    )
  }

  private func assertSendable<Value: Sendable>(_: Value) {}

  private func assertHashable<Value: Hashable>(_: Value) {}
}
