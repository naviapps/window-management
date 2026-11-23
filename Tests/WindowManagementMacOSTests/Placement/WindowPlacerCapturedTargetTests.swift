import ApplicationServices
import CoreGraphics
import WindowManagement
import XCTest

@testable import WindowManagementMacOS

@MainActor
final class WindowPlacerCapturedTargetTests: XCTestCase {
  func testContainingWindowPlacementWritesToTheWindowWhoseFrameWasRead() throws {
    let fixture = ChangingWindowAXFixture()

    try fixture.placer().place(.fill, for: .focused, displayFallback: .none)

    XCTAssertEqual(fixture.focusedWindowReads, 1)
    XCTAssertEqual(fixture.sizeCheckedWindows, [.first])
    XCTAssertEqual(
      fixture.writes,
      [
        .init(window: .first, change: .position(CGPoint(x: 0, y: 20))),
        .init(window: .first, change: .size(CGSize(width: 800, height: 560))),
      ])
  }

  func testContainingWindowPlacementMovesWindowWithReadOnlySizeWhenSizeMatches() {
    let fixture = ChangingWindowAXFixture(
      firstFrame: CGRect(x: 100, y: 30, width: 400, height: 560),
      rejectSizeWrites: true, reportsSizeSettable: false)

    do {
      try fixture.placer().place(
        .grid(columns: 2, rows: 1, column: 1, row: 0, columnSpan: 1, rowSpan: 1),
        for: .focused, displayFallback: .none)
    } catch {
      XCTFail("A same-size placement must not require writable size: \(error)")
      return
    }

    XCTAssertEqual(fixture.focusedWindowReads, 1)
    XCTAssertTrue(fixture.sizeCheckedWindows.isEmpty)
    XCTAssertEqual(fixture.attemptedWindows, [.first])
    XCTAssertEqual(
      fixture.writes,
      [.init(window: .first, change: .position(CGPoint(x: 400, y: 20)))])
  }

  func testPlacementDoesNotMoveAWindowReportingReadOnlySize() {
    let fixture = ChangingWindowAXFixture(rejectSizeWrites: true, reportsSizeSettable: false)

    XCTAssertThrowsError(
      try fixture.placer().place(.fill, for: .focused, displayFallback: .none)
    ) { error in
      XCTAssertEqual(
        error as? WindowAccessibilityError,
        .accessibilityOperationFailed(operation: .setFrame, failure: .attributeUnsupported))
    }

    XCTAssertEqual(fixture.focusedWindowReads, 1)
    XCTAssertEqual(fixture.sizeCheckedWindows, [.first])
    XCTAssertTrue(fixture.attemptedWindows.isEmpty)
    XCTAssertTrue(fixture.writes.isEmpty)
  }

  func testAdjacentDisplayMovementMovesWindowWithReadOnlySizeWhenItFits() throws {
    let fixture = ChangingWindowAXFixture(rejectSizeWrites: true, reportsSizeSettable: false)

    try fixture.placer().moveToAdjacentDisplay(
      .next, for: .focused, preservingRelativePosition: false, displayFallback: .none)

    XCTAssertEqual(fixture.focusedWindowReads, 1)
    XCTAssertTrue(fixture.sizeCheckedWindows.isEmpty)
    XCTAssertEqual(
      fixture.writes,
      [.init(window: .first, change: .position(CGPoint(x: 1100, y: 250)))])
  }

  func testAdjacentDisplayMovementResizesCapturedWindowToFitSmallerDisplay() throws {
    let fixture = ChangingWindowAXFixture(reportsSizeSettable: true, destinationWidth: 150)

    try fixture.placer().moveToAdjacentDisplay(
      .next, for: .focused, preservingRelativePosition: false, displayFallback: .none)

    XCTAssertEqual(fixture.focusedWindowReads, 1)
    XCTAssertEqual(fixture.sizeCheckedWindows, [.first])
    XCTAssertEqual(
      fixture.writes,
      [
        .init(window: .first, change: .position(CGPoint(x: 800, y: 250))),
        .init(window: .first, change: .size(CGSize(width: 150, height: 100))),
      ])
  }

  func testInvalidatedCapturedWindowFailsWithoutWritingToTheNewFocusedWindow() {
    let fixture = ChangingWindowAXFixture(invalidateFirstAfterRead: true)

    XCTAssertThrowsError(
      try fixture.placer().place(.fill, for: .focused, displayFallback: .none)
    ) { error in
      XCTAssertEqual(
        error as? WindowAccessibilityError,
        .accessibilityOperationFailed(operation: .setFrame, failure: .invalidUIElement))
    }

    XCTAssertEqual(fixture.focusedWindowReads, 1)
    XCTAssertEqual(fixture.attemptedWindows, [.first])
    XCTAssertEqual(fixture.writes, [])
  }

  func testWindowIdentifierDoesNotResolveAReplacementElementAfterReadingTheFrame() throws {
    let fixture = ChangingWindowAXFixture()

    try fixture.placer().place(
      .fill, for: .windowIdentifier(42), displayFallback: .none)

    XCTAssertEqual(fixture.applicationWindowListReads, 1)
    XCTAssertEqual(fixture.focusedWindowReads, 0)
    XCTAssertEqual(
      fixture.writes,
      [
        .init(window: .first, change: .position(CGPoint(x: 0, y: 20))),
        .init(window: .first, change: .size(CGSize(width: 800, height: 560))),
      ])
  }
}

@MainActor
private final class ChangingWindowAXFixture {
  enum Window: Equatable {
    case first
    case second
    case unexpected
  }

  enum Change: Equatable {
    case position(CGPoint)
    case size(CGSize)
  }

  struct Write: Equatable {
    let window: Window
    let change: Change
  }

  private let systemElement = AXUIElementCreateSystemWide()
  private let appElement = AXUIElementCreateApplication(getpid())
  private let firstWindow = AXUIElementCreateApplication(getpid() + 1)
  private let secondWindow = AXUIElementCreateApplication(getpid() + 2)
  private let firstFrame: CGRect
  private let invalidateFirstAfterRead: Bool
  private let rejectSizeWrites: Bool
  private let reportsSizeSettable: Bool?
  private let destinationWidth: CGFloat
  private var didReadFirstFrame = false
  private(set) var focusedWindowReads = 0
  private(set) var applicationWindowListReads = 0
  private(set) var attemptedWindows: [Window] = []
  private(set) var sizeCheckedWindows: [Window] = []
  private(set) var writes: [Write] = []

  init(
    firstFrame: CGRect = CGRect(x: 100, y: 60, width: 200, height: 100),
    invalidateFirstAfterRead: Bool = false, rejectSizeWrites: Bool = false,
    reportsSizeSettable: Bool? = nil,
    destinationWidth: CGFloat = 800
  ) {
    self.firstFrame = firstFrame
    self.invalidateFirstAfterRead = invalidateFirstAfterRead
    self.rejectSizeWrites = rejectSizeWrites
    self.reportsSizeSettable = reportsSizeSettable
    self.destinationWidth = destinationWidth
  }

  func placer() -> WindowPlacer {
    let client = AXClient.testing(
      createApplicationElement: { _ in self.appElement },
      copyAttributeValue: { element, attribute, value in
        self.copyAttributeValue(element, attribute, value)
      },
      setAttributeValue: { element, attribute, value in
        self.setAttributeValue(element, attribute, value)
      },
      isAttributeSettable: { element, attribute, value in
        guard attribute as String == AXWindowAttribute.size.accessibilityName else {
          return .attributeUnsupported
        }
        self.sizeCheckedWindows.append(self.windowIdentity(element))
        guard let reportsSizeSettable = self.reportsSizeSettable else { return .notImplemented }
        value.pointee = DarwinBoolean(reportsSizeSettable)
        return .success
      }
    )
    let controller = AXWindowController(
      accessibilityClient: client,
      systemWideElement: systemElement,
      applicationChecker: RunningApplicationCheckerStub(),
      windowListProvider: WindowListProviderStub(ownerProcessIdentifier: getpid()))
    return WindowPlacer(
      frameController: controller, displayProvider: CapturedTargetDisplays(width: destinationWidth))
  }

  private var currentWindow: AXUIElement {
    didReadFirstFrame ? secondWindow : firstWindow
  }

  private func copyAttributeValue(
    _ element: AXUIElement, _ attribute: CFString,
    _ value: UnsafeMutablePointer<CFTypeRef?>
  ) -> AXError {
    switch attribute as String {
    case AXWindowAttribute.focusedApplication.accessibilityName
    where CFEqual(element, systemElement):
      value.pointee = appElement
      return .success
    case AXWindowAttribute.focusedWindow.accessibilityName where CFEqual(element, appElement):
      focusedWindowReads += 1
      value.pointee = currentWindow
      return .success
    case AXWindowAttribute.windows.accessibilityName where CFEqual(element, appElement):
      applicationWindowListReads += 1
      value.pointee = [currentWindow] as CFArray
      return .success
    case AXWindowAttribute.windowIdentifier.accessibilityName:
      value.pointee = NSNumber(value: UInt32(42))
      return .success
    case AXWindowAttribute.position.accessibilityName where CFEqual(element, firstWindow):
      var position = firstFrame.origin
      value.pointee = AXValueCreate(.cgPoint, &position)
      return value.pointee == nil ? .failure : .success
    case AXWindowAttribute.size.accessibilityName where CFEqual(element, firstWindow):
      var size = firstFrame.size
      value.pointee = AXValueCreate(.cgSize, &size)
      // The OS can change focus or replace a window while the native read is in progress.
      didReadFirstFrame = true
      return value.pointee == nil ? .failure : .success
    default:
      value.pointee = nil
      return .noValue
    }
  }

  private func setAttributeValue(
    _ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef
  ) -> AXError {
    let window = windowIdentity(element)
    attemptedWindows.append(window)
    if window == .first && didReadFirstFrame && invalidateFirstAfterRead {
      return .invalidUIElement
    }
    guard CFGetTypeID(value) == AXValueGetTypeID() else { return .illegalArgument }
    let axValue = Unmanaged<AXValue>
      .fromOpaque(Unmanaged.passUnretained(value).toOpaque())
      .takeUnretainedValue()
    let change: Change
    switch attribute as String {
    case AXWindowAttribute.position.accessibilityName:
      var position = CGPoint.zero
      guard AXValueGetValue(axValue, .cgPoint, &position) else { return .illegalArgument }
      change = .position(position)
    case AXWindowAttribute.size.accessibilityName:
      if rejectSizeWrites { return .attributeUnsupported }
      var size = CGSize.zero
      guard AXValueGetValue(axValue, .cgSize, &size) else { return .illegalArgument }
      change = .size(size)
    default:
      return .attributeUnsupported
    }
    writes.append(Write(window: window, change: change))
    return .success
  }

  private func windowIdentity(_ element: AXUIElement) -> Window {
    if CFEqual(element, firstWindow) { return .first }
    if CFEqual(element, secondWindow) { return .second }
    return .unexpected
  }
}

private struct CapturedTargetDisplays: DisplayProviding {
  let width: CGFloat

  @MainActor
  func displays() -> [Display] {
    [
      .init(
        displayIdentifier: 1,
        frame: CGRect(x: 0, y: 0, width: 800, height: 600),
        visibleFrame: CGRect(x: 0, y: 20, width: 800, height: 560)),
      .init(
        displayIdentifier: 2,
        frame: CGRect(x: 800, y: 0, width: width, height: 600),
        visibleFrame: CGRect(x: 800, y: 20, width: width, height: 560)),
    ]
  }
}
