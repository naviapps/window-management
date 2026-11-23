import WindowManagement
import XCTest

final class DisplayCycleDirectionTests: XCTestCase {
  func testDisplayCycleDirectionValueConformance() throws {
    try assertValueConformance(DisplayCycleDirection.next)
    try assertValueConformance(DisplayCycleDirection.previous)
  }

  func testDisplayCycleDirectionIsSendable() {
    assertSendable(DisplayCycleDirection.next)
    assertSendable(DisplayCycleDirection.previous)
  }

  private func assertSendable<Value: Sendable>(_: Value) {}
}
