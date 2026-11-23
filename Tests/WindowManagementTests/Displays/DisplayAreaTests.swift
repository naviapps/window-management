import WindowManagement
import XCTest

final class DisplayAreaTests: XCTestCase {
  func testDisplayAreaValueConformance() throws {
    try assertValueConformance(DisplayArea.full)
    try assertValueConformance(DisplayArea.visible)
  }

  func testDisplayAreaIsSendable() {
    assertSendable(DisplayArea.full)
    assertSendable(DisplayArea.visible)
  }

  private func assertSendable<Value: Sendable>(_: Value) {}
}
