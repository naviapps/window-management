import WindowManagement
import XCTest

@MainActor
final class DisplayProvidingTests: XCTestCase {
  func testDisplaysCanBeReadThroughProvidingProtocol() {
    let display = Display(frame: .zero, visibleFrame: .zero)
    let provider: any DisplayProviding = DisplayProviderStub(displays: [display])

    XCTAssertEqual(provider.displays(), [display])
  }
}

private struct DisplayProviderStub: DisplayProviding {
  let displayValues: [Display]

  init(displays: [Display]) {
    displayValues = displays
  }

  func displays() -> [Display] {
    displayValues
  }
}
