import CoreGraphics
import WindowManagement
import XCTest

final class DisplayTargetTests: XCTestCase {
  func testDisplayTargetValueConformance() throws {
    try assertValueConformance(DisplayTarget.main)
    try assertValueConformance(DisplayTarget.containingWindow)
    try assertValueConformance(DisplayTarget.point(CGPoint(x: 10, y: 20)))
    try assertValueConformance(DisplayTarget.displayIdentifier(123))
    try assertValueConformance(DisplayTarget.orderedIndex(2))
  }

  func testDisplayTargetIsSendable() {
    assertSendable(DisplayTarget.main)
    assertSendable(DisplayTarget.containingWindow)
    assertSendable(DisplayTarget.point(CGPoint(x: 10, y: 20)))
    assertSendable(DisplayTarget.displayIdentifier(123))
    assertSendable(DisplayTarget.orderedIndex(2))
  }

  private func assertSendable<Value: Sendable>(_: Value) {}
}
