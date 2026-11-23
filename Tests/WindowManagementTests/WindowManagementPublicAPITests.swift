import CoreGraphics
import WindowManagement
import XCTest

final class WindowManagementPublicAPITests: XCTestCase {
  func testCoreValueAndGeometryAPIsAreUsableFromPublicImport() {
    let snapshot = publicSnapshot()
    let filter = WindowSnapshotFilter(
      includedOwnerApplicationIdentifiers: ["com.example.app"],
      includedOwnerProcessIdentifiers: [10],
      includedWindowIdentifiers: [20]
    )
    let display = publicDisplay()
    let placement = WindowPlacement.grid(
      columns: 2,
      rows: 1,
      column: 0,
      row: 0,
      columnSpan: 1,
      rowSpan: 1
    )

    XCTAssertEqual(snapshot.ownerBundleIdentifier, "com.example.app")
    XCTAssertTrue(filter.includes(snapshot))
    XCTAssertEqual(display.frame(for: DisplayArea.visible), display.visibleFrame)
    XCTAssertEqual(
      WindowPlacementCalculator.frame(for: placement, in: display.frame),
      CGRect(x: 0, y: 0, width: 500, height: 800)
    )
    XCTAssertEqual(
      DisplaySelector.display(
        for: DisplayTarget.main,
        windowFrame: snapshot.frame,
        in: [display],
        fallback: DisplayFallback.none
      ),
      display
    )
    XCTAssertEqual(DisplaySelector.index(containing: CGPoint(x: 1, y: 1), in: [display]), 0)
    XCTAssertEqual(
      DisplaySelector.adjacentIndex(
        from: 0,
        direction: DisplayCycleDirection.next,
        displayCount: 1
      ),
      0
    )
    XCTAssertEqual(
      DisplayMovement.centerPreservingSize(
        windowFrame: snapshot.frame,
        in: display.visibleFrame
      ).size,
      snapshot.frame.size
    )
  }

  func testPublicValueConformancesAreUsableFromPublicImport() throws {
    let snapshot = publicSnapshot()
    let display = publicDisplay()

    try assertValueConformance(
      WindowState.self, WindowState(isMinimized: false, isFullScreen: true))
    try assertValueConformance(WindowTarget.self, WindowTarget.windowIdentifier(20))
    try assertValueConformance(
      WindowHitTestMissReason.self,
      WindowHitTestMissReason.noMatchingWindowAtPoint
    )
    try assertValueConformance(WindowHitTestResult.self, WindowHitTestResult.hit(snapshot))
    try assertValueConformance(WindowPlacement.self, WindowPlacement.fill)
    try assertValueConformance(DisplayArea.self, DisplayArea.visible)
    try assertValueConformance(DisplayFallback.self, DisplayFallback.firstDisplay)
    try assertValueConformance(
      DisplayCycleDirection.self,
      DisplayCycleDirection.next
    )
    try assertValueConformance(DisplayTarget.self, DisplayTarget.displayIdentifier(1))
    try assertValueConformance(WindowSnapshot.self, snapshot)
    try assertValueConformance(
      WindowSnapshotFilter.self,
      WindowSnapshotFilter(includedOwnerApplicationIdentifiers: ["com.example.app"])
    )
    try assertValueConformance(Display.self, display)

    assertSendable((any WindowCommandControlling).self)
    assertSendable((any WindowControlling).self)
    assertSendable((any WindowFrameControlling).self)
    assertSendable((any WindowFrameProviding).self)
    assertSendable((any WindowStateProviding).self)
    assertSendable((any WindowHitTesting).self)
    assertSendable((any DisplayProviding).self)
    assertSendable((any WindowSnapshotProviding).self)
    assertSendable((any WindowSnapshotResolving).self)
  }

  func testControlHitTestingAndProviderContractsAreUsableFromPublicImport() throws {
    let target = WindowTarget.windowIdentifier(20)
    let state = WindowState(isMinimized: false, isFullScreen: true)
    let hitSnapshot = publicSnapshot()
    let hit = WindowHitTestResult.hit(hitSnapshot)
    let miss = WindowHitTestResult.miss(WindowHitTestMissReason.noMatchingWindowAtPoint)
    let hitTesting: any WindowHitTesting = PublicHitTesting(result: hit)
    let emptySnapshotProvider: any WindowSnapshotProviding = PublicSnapshotProvider()
    let emptySnapshotResolver: any WindowSnapshotResolving = PublicSnapshotProvider()

    XCTAssertEqual(WindowTarget.focused, .focused)
    XCTAssertEqual(target, .windowIdentifier(20))
    XCTAssertEqual(state.isFullScreen, true)
    XCTAssertEqual(hit.snapshot, hitSnapshot)
    XCTAssertEqual(miss.missReason, .noMatchingWindowAtPoint)
    XCTAssertEqual(hitTesting.topmost(at: CGPoint(x: 10, y: 10)), hitSnapshot)
    XCTAssertEqual(try emptySnapshotProvider.snapshots(), [])
    XCTAssertNil(try emptySnapshotResolver.snapshot(for: 20))
  }

  @MainActor
  func testControlAndDisplayProviderContractsAreUsableFromPublicImport() throws {
    let target = WindowTarget.focused
    let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
    let state = WindowState(isMinimized: true, isFullScreen: false)
    let display = publicDisplay()
    let frameController = PublicFrameController(frame: frame)
    let frameProvider: any WindowFrameProviding = frameController
    let frameControlling: any WindowFrameControlling = frameController
    let commandControlling: any WindowCommandControlling = PublicCommandController()
    let stateProviding: any WindowStateProviding = PublicStateProvider(state: state)
    let displayProviding: any DisplayProviding = PublicDisplayProvider(displays: [display])

    XCTAssertEqual(try frameProvider.frame(for: target), frame)
    try frameControlling.setFrame(frame, for: target)
    try commandControlling.requestClose(target)
    try commandControlling.setMinimized(target, isMinimized: false)
    try commandControlling.setFullScreen(target, isFullScreen: true)
    try commandControlling.raise(target)
    try commandControlling.lower(target)
    XCTAssertEqual(try stateProviding.state(for: target), state)
    XCTAssertEqual(displayProviding.displays(), [display])
  }

  func testDocumentationExamplesAreUsableWithoutTestableImport() {
    let display = Display(
      frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
      visibleFrame: CGRect(x: 0, y: 44, width: 1440, height: 812)
    )
    let frame = WindowPlacementCalculator.frame(
      for: .grid(columns: 2, rows: 1, column: 0, row: 0, columnSpan: 1, rowSpan: 1),
      in: display.visibleFrame,
      inset: 8
    )
    let snapshot = WindowSnapshot(
      ownerProcessIdentifier: 42,
      windowIdentifier: 1001,
      ownerName: "Editor",
      ownerBundleIdentifier: "com.example.editor",
      title: "Document",
      frame: CGRect(x: 120, y: 80, width: 900, height: 640),
    )

    XCTAssertEqual(frame, CGRect(x: 8, y: 52, width: 712, height: 796))
    XCTAssertEqual(snapshot.ownerBundleIdentifier, "com.example.editor")
  }
}

private func publicSnapshot() -> WindowSnapshot {
  WindowSnapshot(
    ownerProcessIdentifier: 10,
    windowIdentifier: 20,
    ownerName: "Example",
    ownerBundleIdentifier: "com.example.app",
    title: "Main",
    frame: CGRect(x: 10, y: 20, width: 300, height: 200),
  )
}

private func publicDisplay() -> Display {
  Display(
    displayIdentifier: 1,
    frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
    visibleFrame: CGRect(x: 0, y: 40, width: 1000, height: 720),
    isMain: true
  )
}

private struct PublicHitTesting: WindowHitTesting {
  let result: WindowHitTestResult

  func hitTest(at _: CGPoint) -> WindowHitTestResult {
    result
  }
}

private struct PublicSnapshotProvider: WindowSnapshotProviding, WindowSnapshotResolving {
  func snapshots() throws -> [WindowSnapshot] {
    []
  }

  func snapshot(for _: CGWindowID) throws -> WindowSnapshot? {
    nil
  }
}

private final class PublicFrameController: WindowFrameControlling {
  private let frameValue: CGRect

  init(frame: CGRect) {
    frameValue = frame
  }

  func frame(for _: WindowTarget) throws -> CGRect {
    frameValue
  }

  func setFrame(_: CGRect, for _: WindowTarget) throws {}
}

private struct PublicCommandController: WindowCommandControlling {
  func requestClose(_: WindowTarget) throws {}
  func setMinimized(_: WindowTarget, isMinimized _: Bool) throws {}

  func setFullScreen(_: WindowTarget, isFullScreen _: Bool) throws {}

  func raise(_: WindowTarget) throws {}

  func lower(_: WindowTarget) throws {}
}

private struct PublicStateProvider: WindowStateProviding {
  let stateValue: WindowState

  init(state: WindowState) {
    stateValue = state
  }

  func state(for _: WindowTarget) throws -> WindowState {
    stateValue
  }
}

private struct PublicDisplayProvider: DisplayProviding {
  let displayValues: [Display]

  init(displays: [Display]) {
    displayValues = displays
  }

  func displays() -> [Display] {
    displayValues
  }
}

private func assertPublicSendableValue<Value: Sendable>(_: Value) {}
