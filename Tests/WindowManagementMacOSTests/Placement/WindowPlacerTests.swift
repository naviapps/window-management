import CoreGraphics
import WindowManagement
import WindowManagementMacOS
import XCTest
import os

final class WindowPlacerTests: XCTestCase {
  @MainActor
  func testPlacementAndMovementUseWindowOverlapAcrossADisplayGap() throws {
    let target = WindowTarget.windowIdentifier(12)
    let original = CGRect(x: -250, y: -50, width: 450, height: 100)
    let displays = DisplayProviderStub(displays: [
      .init(
        frame: CGRect(x: 100, y: -100, width: 300, height: 300),
        visibleFrame: CGRect(x: 100, y: -80, width: 300, height: 280)),
      .init(
        frame: CGRect(x: -400, y: -100, width: 200, height: 300),
        visibleFrame: CGRect(x: -400, y: -100, width: 200, height: 300)),
    ])
    let placementFrames = WindowFrameControllerFake(frames: [(target, original)])
    let placer = WindowPlacer(frameController: placementFrames, displayProvider: displays)
    try placer.place(.fill, for: target, displayFallback: .none)
    XCTAssertEqual(
      try placementFrames.frame(for: target), CGRect(x: 100, y: -80, width: 300, height: 280))

    let movementFrames = WindowFrameControllerFake(frames: [(target, original)])
    let mover = WindowPlacer(frameController: movementFrames, displayProvider: displays)
    try mover.moveToAdjacentDisplay(
      .next, for: target, preservingRelativePosition: false, displayFallback: .none)
    XCTAssertEqual(
      try movementFrames.frame(for: target), CGRect(x: -400, y: 0, width: 200, height: 100))
  }

  @MainActor
  func testPlaceUsesVisibleFrameForTarget() throws {
    let target = WindowTarget.windowIdentifier(1)
    let frameController = WindowFrameControllerFake(frames: [
      (target, CGRect(x: 10, y: 10, width: 100, height: 100))
    ])
    let displays = DisplayProviderStub(displays: [
      .init(
        frame: CGRect(x: 0, y: 0, width: 800, height: 600),
        visibleFrame: CGRect(x: 0, y: 20, width: 800, height: 560),
        isMain: true
      )
    ])
    let controller = WindowPlacer(
      frameController: frameController,
      displayProvider: displays
    )

    try controller.place(
      .grid(columns: 2, rows: 1, column: 1, row: 0, columnSpan: 1, rowSpan: 1), for: target)
    XCTAssertEqual(
      try frameController.frame(for: target), CGRect(x: 400, y: 20, width: 400, height: 560))
  }

  @MainActor
  func testMoveToAdjacentDisplayPreservesRelativePosition() throws {
    let target = WindowTarget.windowIdentifier(2)
    let frameController = WindowFrameControllerFake(frames: [
      (target, CGRect(x: 100, y: 50, width: 200, height: 100))
    ])
    let displays = DisplayProviderStub(displays: [
      .init(
        frame: CGRect(x: 0, y: 0, width: 800, height: 600),
        visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600)),
      .init(
        frame: CGRect(x: 800, y: 0, width: 800, height: 600),
        visibleFrame: CGRect(x: 800, y: 0, width: 800, height: 600)
      ),
    ])

    let controller = WindowPlacer(
      frameController: frameController,
      displayProvider: displays
    )

    try controller.moveToAdjacentDisplay(.next, for: target, preservingRelativePosition: true)
    XCTAssertEqual(
      try frameController.frame(for: target), CGRect(x: 900, y: 50, width: 200, height: 100))
  }

  @MainActor
  func testPlaceUsesFullDisplayBoundsWhenRequested() throws {
    let target = WindowTarget.windowIdentifier(3)
    let frameController = WindowFrameControllerFake(frames: [
      (target, CGRect(x: 10, y: 10, width: 100, height: 100))
    ])
    let displays = DisplayProviderStub(displays: [
      .init(
        frame: CGRect(x: 0, y: 0, width: 800, height: 600),
        visibleFrame: CGRect(x: 0, y: 20, width: 800, height: 560),
        isMain: true
      )
    ])
    let controller = WindowPlacer(frameController: frameController, displayProvider: displays)

    try controller.place(
      .grid(columns: 2, rows: 1, column: 0, row: 0, columnSpan: 1, rowSpan: 1),
      for: target,
      area: .full
    )

    XCTAssertEqual(
      try frameController.frame(for: target), CGRect(x: 0, y: 0, width: 400, height: 600))
  }

  @MainActor
  func testPlaceThrowsBeforeReadingWindowFrameWhenNoDisplaysAreAvailable() throws {
    let target = WindowTarget.windowIdentifier(42)
    let frameController = WindowFrameControllerFake()
    let controller = WindowPlacer(
      frameController: frameController,
      displayProvider: DisplayProviderStub(displays: [])
    )

    XCTAssertThrowsError(
      try controller.place(.fill, for: target)
    ) { error in
      XCTAssertEqual(error as? WindowPlacerError, .displayNotFound(.containingWindow))
    }
    XCTAssertEqual(frameController.frameReadCount, 0)
  }

  @MainActor
  func testPlaceDoesNotReadWindowFrameForExplicitDisplayTargets() throws {
    let target = WindowTarget.windowIdentifier(43)
    let frameController = WindowFrameControllerFake(frames: [
      (target, CGRect(x: 0, y: 0, width: 10, height: 10))
    ])
    let controller = WindowPlacer(
      frameController: frameController,
      displayProvider: DisplayProviderStub(displays: [
        .init(
          displayIdentifier: 1,
          frame: CGRect(x: 0, y: 0, width: 800, height: 600),
          visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
          isMain: true
        )
      ])
    )

    try controller.place(.fill, for: target, display: .displayIdentifier(1))

    XCTAssertEqual(frameController.frameReadCount, 0)
    XCTAssertEqual(
      try frameController.frame(for: target), CGRect(x: 0, y: 0, width: 800, height: 600))
  }

  @MainActor
  func testPlaceThrowsWhenStrictDisplayTargetDoesNotMatch() throws {
    let target = WindowTarget.windowIdentifier(6)
    let original = CGRect(x: 10, y: 10, width: 100, height: 100)
    let frameController = WindowFrameControllerFake(frames: [(target, original)])
    let displays = DisplayProviderStub(displays: [
      .init(
        displayIdentifier: 1,
        frame: CGRect(x: 0, y: 0, width: 800, height: 600),
        visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600)
      )
    ])
    let controller = WindowPlacer(frameController: frameController, displayProvider: displays)

    XCTAssertThrowsError(
      try controller.place(
        .fill,
        for: target,
        display: .displayIdentifier(99),
        displayFallback: .none
      )
    ) { error in
      XCTAssertEqual(error as? WindowPlacerError, .displayNotFound(.displayIdentifier(99)))
    }
    XCTAssertEqual(try frameController.frame(for: target), original)
  }

  @MainActor
  func testMoveToAdjacentDisplayCanCenterInsteadOfPreservingRelativePosition() throws {
    let target = WindowTarget.windowIdentifier(5)
    let frameController = WindowFrameControllerFake(frames: [
      (target, CGRect(x: 100, y: 50, width: 200, height: 100))
    ])
    let displays = DisplayProviderStub(displays: [
      .init(
        frame: CGRect(x: 0, y: 0, width: 800, height: 600),
        visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600)),
      .init(
        frame: CGRect(x: 800, y: 0, width: 800, height: 600),
        visibleFrame: CGRect(x: 800, y: 0, width: 800, height: 600)
      ),
    ])

    let controller = WindowPlacer(frameController: frameController, displayProvider: displays)

    try controller.moveToAdjacentDisplay(.next, for: target, preservingRelativePosition: false)

    XCTAssertEqual(
      try frameController.frame(for: target), CGRect(x: 1100, y: 250, width: 200, height: 100))
  }

  @MainActor
  func testMoveToAdjacentDisplayDoesNotWriteWhenWindowIsOnTheOnlyDisplay() throws {
    let target = WindowTarget.windowIdentifier(82)
    let displays = DisplayProviderStub(displays: [
      .init(
        frame: CGRect(x: 0, y: 0, width: 800, height: 600),
        visibleFrame: CGRect(x: 0, y: 25, width: 800, height: 575))
    ])
    for original in [
      CGRect(x: -100, y: 20, width: 950, height: 200),
      CGRect(x: 850, y: 220, width: -950, height: -200),
    ] {
      let frameController = WindowFrameControllerFake(frames: [(target, original)])
      let placer = WindowPlacer(frameController: frameController, displayProvider: displays)
      try placer.moveToAdjacentDisplay(.next, for: target, displayFallback: .none)
      try placer.moveToAdjacentDisplay(.previous, for: target, preservingRelativePosition: false)
      XCTAssertEqual(frameController.frameWriteCount, 0)
      XCTAssertEqual(try frameController.frame(for: target), original)
    }
  }

  @MainActor
  func testMoveToMirroredDisplayStillWritesTheFrame() throws {
    let target = WindowTarget.windowIdentifier(84)
    let original = CGRect(x: 200, y: 100, width: 200, height: 200)
    let frames = WindowFrameControllerFake(frames: [(target, original)])
    let area = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let placer = WindowPlacer(
      frameController: frames,
      displayProvider: DisplayProviderStub(displays: [
        .init(displayIdentifier: 1, frame: area, visibleFrame: area, isMain: true),
        .init(displayIdentifier: 2, frame: area, visibleFrame: area),
      ])
    )
    try placer.moveToAdjacentDisplay(.next, for: target, displayFallback: .none)
    XCTAssertEqual(frames.frameWriteCount, 1)
    XCTAssertEqual(try frames.frame(for: target), original)
  }

  @MainActor
  func testMoveReportsAnUnavailableCapturedTargetBeforePlanning() {
    let target = WindowTarget.windowIdentifier(85)
    let area = CGRect(x: 0, y: 0, width: 800, height: 600)
    let frames = WindowFrameControllerFake()
    let placer = WindowPlacer(
      frameController: frames,
      displayProvider: DisplayProviderStub(displays: [.init(frame: area, visibleFrame: area)]))
    XCTAssertThrowsError(try placer.moveToAdjacentDisplay(.next, for: target)) { error in
      guard case WindowFrameControllerFakeError.missingFrame(let missing) = error else {
        return XCTFail("Unexpected capture failure: \(error)")
      }
      XCTAssertEqual(missing, target)
    }
    XCTAssertEqual(frames.frameReadCount, 1)
    XCTAssertEqual(frames.frameWriteCount, 0)
  }

  @MainActor
  func testMoveToAdjacentDisplayCanRecoverOffscreenWindowToTheOnlyDisplay() throws {
    let target = WindowTarget.windowIdentifier(83)
    let frameController = WindowFrameControllerFake(frames: [
      (target, CGRect(x: 900, y: 900, width: 100, height: 100))
    ])
    let placer = WindowPlacer(
      frameController: frameController,
      displayProvider: DisplayProviderStub(displays: [
        .init(
          frame: CGRect(x: 0, y: 0, width: 800, height: 600),
          visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600))
      ])
    )

    try placer.moveToAdjacentDisplay(.next, for: target, preservingRelativePosition: false)

    XCTAssertEqual(frameController.frameWriteCount, 1)
    XCTAssertEqual(
      try frameController.frame(for: target), CGRect(x: 350, y: 250, width: 100, height: 100))
  }

  @MainActor
  func testMoveToAdjacentDisplayThrowsWhenStrictCurrentDisplayDoesNotMatch() throws {
    let target = WindowTarget.windowIdentifier(7)
    let original = CGRect(x: 900, y: 900, width: 100, height: 100)
    let frameController = WindowFrameControllerFake(frames: [(target, original)])
    let displays = DisplayProviderStub(displays: [
      .init(
        frame: CGRect(x: 0, y: 0, width: 800, height: 600),
        visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600)
      )
    ])
    let controller = WindowPlacer(frameController: frameController, displayProvider: displays)

    XCTAssertThrowsError(
      try controller.moveToAdjacentDisplay(.next, for: target, displayFallback: .none)
    ) { error in
      XCTAssertEqual(error as? WindowPlacerError, .displayNotFound(.containingWindow))
    }
    XCTAssertEqual(try frameController.frame(for: target), original)
  }

  @MainActor
  func testMoveToAdjacentDisplayFallsBackToFirstDisplayWhenCurrentDisplayDoesNotMatch() throws {
    let target = WindowTarget.windowIdentifier(10)
    let frameController = WindowFrameControllerFake(frames: [
      (target, CGRect(x: 900, y: 900, width: 100, height: 100))
    ])
    let displays = DisplayProviderStub(displays: [
      .init(
        frame: CGRect(x: 0, y: 0, width: 800, height: 600),
        visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600)),
      .init(
        frame: CGRect(x: 800, y: 0, width: 800, height: 600),
        visibleFrame: CGRect(x: 800, y: 0, width: 800, height: 600)
      ),
    ])
    let controller = WindowPlacer(frameController: frameController, displayProvider: displays)

    try controller.moveToAdjacentDisplay(.next, for: target, preservingRelativePosition: false)

    XCTAssertEqual(
      try frameController.frame(for: target), CGRect(x: 1150, y: 250, width: 100, height: 100))
  }

  @MainActor
  func testMoveToAdjacentDisplayThrowsWhenNoDisplaysAreAvailable() throws {
    let target = WindowTarget.windowIdentifier(8)
    let original = CGRect(x: 10, y: 10, width: 100, height: 100)
    let frameController = WindowFrameControllerFake(frames: [(target, original)])
    let controller = WindowPlacer(
      frameController: frameController,
      displayProvider: DisplayProviderStub(displays: [])
    )

    XCTAssertThrowsError(
      try controller.moveToAdjacentDisplay(.next, for: target)
    ) { error in
      XCTAssertEqual(error as? WindowPlacerError, .displayNotFound(.containingWindow))
    }
    XCTAssertEqual(try frameController.frame(for: target), original)
  }

  @MainActor
  func testMoveToAdjacentDisplayThrowsBeforeReadingWindowFrameWhenNoDisplaysAreAvailable()
    throws
  {
    let target = WindowTarget.windowIdentifier(81)
    let frameController = WindowFrameControllerFake()
    let controller = WindowPlacer(
      frameController: frameController,
      displayProvider: DisplayProviderStub(displays: [])
    )

    XCTAssertThrowsError(
      try controller.moveToAdjacentDisplay(.next, for: target)
    ) { error in
      XCTAssertEqual(error as? WindowPlacerError, .displayNotFound(.containingWindow))
    }
    XCTAssertEqual(frameController.frameReadCount, 0)
  }

}

@MainActor
private final class WindowFrameControllerFake: WindowFrameControlling {
  private let framesStorage: OSAllocatedUnfairLock<[(WindowTarget, CGRect)]>
  private let frameReadCountStorage = OSAllocatedUnfairLock(initialState: 0)
  private(set) var frameWriteCount = 0

  var frameReadCount: Int {
    frameReadCountStorage.withLock { $0 }
  }

  init(frames: [(WindowTarget, CGRect)] = []) {
    framesStorage = OSAllocatedUnfairLock(initialState: frames)
  }

  @MainActor
  func frame(for target: WindowTarget) throws -> CGRect {
    frameReadCountStorage.withLock { $0 += 1 }
    let frame = framesStorage.withLock { frames in
      frames.first(where: { $0.0 == target })?.1
    }
    guard let frame else {
      throw WindowFrameControllerFakeError.missingFrame(target)
    }
    return frame
  }

  @MainActor
  func setFrame(_ frame: CGRect, for target: WindowTarget) throws {
    frameWriteCount += 1
    let didUpdate = framesStorage.withLock { frames in
      guard let index = frames.firstIndex(where: { $0.0 == target }) else {
        return false
      }
      frames[index].1 = frame
      return true
    }
    guard didUpdate else {
      throw WindowFrameControllerFakeError.missingFrame(target)
    }
  }
}

private enum WindowFrameControllerFakeError: Error {
  case missingFrame(WindowTarget)
}

private struct DisplayProviderStub: DisplayProviding {
  private let storedDisplays: [Display]

  init(displays: [Display]) {
    storedDisplays = displays
  }

  @MainActor
  func displays() -> [Display] {
    storedDisplays
  }
}
