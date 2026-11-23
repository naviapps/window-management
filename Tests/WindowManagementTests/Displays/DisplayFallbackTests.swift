import WindowManagement
import XCTest

final class DisplayFallbackTests: XCTestCase {
  func testDisplayFallbackValueConformance() throws {
    try assertValueConformance(DisplayFallback.firstDisplay)
    try assertValueConformance(DisplayFallback.none)
  }

  func testDisplayFallbackIsSendable() {
    assertSendable(DisplayFallback.firstDisplay)
    assertSendable(DisplayFallback.none)
  }

  private func assertSendable<Value: Sendable>(_: Value) {}
}
