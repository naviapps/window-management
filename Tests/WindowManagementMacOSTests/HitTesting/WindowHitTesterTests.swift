import CoreGraphics
import WindowManagement
import XCTest
import os

@testable import WindowManagementMacOS

@MainActor
final class WindowHitTesterTests: XCTestCase {
  func testHitTesterOnlyOptedInLevelsCanWinInNativeOrder() {
    let normalLevel = CGWindowLevelForKey(.normalWindow)
    let floatingLevel = CGWindowLevelForKey(.floatingWindow)
    let overlay = ObservedWindowInfo(
      values: makeRawWindowInfo(
        layer: NSNumber(value: floatingLevel + 1), ownerProcessIdentifier: 111,
        windowIdentifier: 11))
    let provider = NativeWindowListProviderSpy(windowInfo: [
      overlay,
      ObservedWindowInfo(
        values: makeRawWindowInfo(
          layer: NSNumber(value: floatingLevel), ownerProcessIdentifier: 222, windowIdentifier: 22)),
      ObservedWindowInfo(
        values: makeRawWindowInfo(
          layer: NSNumber(value: floatingLevel), ownerProcessIdentifier: 333, windowIdentifier: 33)),
      ObservedWindowInfo(
        values: makeRawWindowInfo(
          layer: NSNumber(value: normalLevel), ownerProcessIdentifier: 444, windowIdentifier: 44)),
    ])
    let bundleProvider = RecordingWindowBundleIdentifierProvider()
    let defaultTester = WindowHitTester(
      listProvider: provider, ownerBundleIdentifierProvider: bundleProvider)
    let floatingTester = WindowHitTester(
      listProvider: provider, ownerBundleIdentifierProvider: bundleProvider,
      windowLayers: [Int(normalLevel), Int(floatingLevel)])
    let point = CGPoint(x: 10, y: 10)

    XCTAssertEqual(defaultTester.hitTest(at: point).snapshot?.windowIdentifier, 44)
    XCTAssertEqual(floatingTester.hitTest(at: point).snapshot?.windowIdentifier, 22)
    XCTAssertEqual(overlay.lookedUpKeys, [kCGWindowLayer as String, kCGWindowLayer as String])
    XCTAssertEqual(bundleProvider.requests, [444, 222])
  }

  func testHitTesterSkipsInvisibleFrontWindowWithoutFilteringSnapshotQueries() throws {
    let invisible = ObservedWindowInfo(
      values: makeRawWindowInfo(
        ownerProcessIdentifier: 111, windowIdentifier: 11, alpha: NSNumber(value: 0.0)))
    let provider = NativeWindowListProviderSpy(windowInfo: [
      invisible,
      ObservedWindowInfo(
        values: makeRawWindowInfo(
          ownerProcessIdentifier: 222, windowIdentifier: 22, alpha: NSNumber(value: 1.0))),
    ])
    let owners = RecordingWindowBundleIdentifierProvider { pid in "com.example.owner-\(pid)" }
    let tester = WindowHitTester(listProvider: provider, ownerBundleIdentifierProvider: owners)
    let hit = tester.hitTest(at: CGPoint(x: 10, y: 10)).snapshot
    XCTAssertEqual(hit?.windowIdentifier, 22)
    XCTAssertEqual(hit?.ownerBundleIdentifier, "com.example.owner-222")
    XCTAssertEqual(owners.requests, [222])
    XCTAssertEqual(
      invisible.lookedUpKeys,
      [kCGWindowLayer as String, kCGWindowBounds as String, kCGWindowAlpha as String])

    let query = WindowSnapshotQuery(listProvider: provider, ownerBundleIdentifierProvider: owners)
    XCTAssertEqual(try query.snapshots().map(\.windowIdentifier), [11, 22])
    XCTAssertEqual(try query.snapshot(for: 11)?.ownerBundleIdentifier, "com.example.owner-111")
  }

  func testHitTesterKeepsPartlyTransparentOrUnknownAlphaInNativeOrder() {
    let alphas: [NSNumber?] = [NSNumber(value: 0.25), nil, NSNumber(value: false)]
    for alpha in alphas {
      let provider = NativeWindowListProviderSpy(windowInfo: [
        ObservedWindowInfo(
          values: makeRawWindowInfo(windowIdentifier: 11, alpha: alpha)),
        ObservedWindowInfo(
          values: makeRawWindowInfo(windowIdentifier: 22, alpha: NSNumber(value: 1.0))),
      ])
      let tester = WindowHitTester(
        listProvider: provider, ownerBundleIdentifierProvider: makeBundleIdentifierProvider())
      XCTAssertEqual(tester.hitTest(at: CGPoint(x: 10, y: 10)).snapshot?.windowIdentifier, 11)
    }
  }

  func testHitTesterDecodesOnlyVisitedNativeFields() throws {
    let rows = [
      ObservedWindowInfo(
        values: makeRawWindowInfo(
          layer: 1, ownerProcessIdentifier: 111, windowIdentifier: 111)),
      ObservedWindowInfo(
        values: makeRawWindowInfo(
          frame: CGRect(x: 200, y: 200, width: 100, height: 100),
          ownerProcessIdentifier: 222, windowIdentifier: 222)),
      ObservedWindowInfo(
        values: makeRawWindowInfo(
          frame: CGRect(x: 100, y: 100, width: -100, height: -100),
          ownerProcessIdentifier: 333, windowIdentifier: 333,
          ownerName: "Winning Owner", title: "Winning Title")),
      ObservedWindowInfo(
        values: makeRawWindowInfo(
          ownerProcessIdentifier: 444, windowIdentifier: 444)),
    ]
    let provider = NativeWindowListProviderSpy(windowInfo: rows)
    let bundleProvider = RecordingWindowBundleIdentifierProvider()
    let hitTester = WindowHitTester(
      listProvider: provider, ownerBundleIdentifierProvider: bundleProvider)

    let selected = try XCTUnwrap(hitTester.hitTest(at: CGPoint(x: 10, y: 10)).snapshot)

    XCTAssertEqual(selected.windowIdentifier, 333)
    XCTAssertEqual(selected.ownerProcessIdentifier, 333)
    XCTAssertEqual(selected.ownerName, "Winning Owner")
    XCTAssertEqual(selected.title, "Winning Title")
    XCTAssertEqual(selected.ownerBundleIdentifier, "com.example.app")
    XCTAssertEqual(selected.frame, CGRect(x: 0, y: 0, width: 100, height: 100))
    XCTAssertEqual(rows[0].lookedUpKeys, [kCGWindowLayer as String])
    XCTAssertEqual(rows[1].lookedUpKeys, [kCGWindowLayer as String, kCGWindowBounds as String])
    XCTAssertEqual(rows[2].lookedUpKeys.count, 7)
    XCTAssertEqual(
      Set(rows[2].lookedUpKeys),
      Set([
        kCGWindowLayer as String, kCGWindowBounds as String, kCGWindowAlpha as String,
        kCGWindowOwnerPID as String,
        kCGWindowNumber as String, kCGWindowOwnerName as String, kCGWindowName as String,
      ]))
    XCTAssertEqual(rows[3].lookedUpKeys, [])
    XCTAssertEqual(bundleProvider.requests, [333])
    XCTAssertEqual(provider.requests, [.onScreenWindows])
  }

  func testHitTesterSkipsMetadataForRejectedWindowIdentifiers() {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(
        layer: 0, frame: CGRect(x: 0, y: 0, width: 100, height: 100),
        ownerProcessIdentifier: 111, windowIdentifier: 111),
      makeWindowEntry(
        layer: 0, frame: CGRect(x: 0, y: 0, width: 100, height: 100),
        ownerProcessIdentifier: 222, windowIdentifier: 222),
    ])
    let bundleProvider = RecordingWindowBundleIdentifierProvider()
    let hitTester = WindowHitTester(
      listProvider: provider, ownerBundleIdentifierProvider: bundleProvider,
      filter: .init(includedWindowIdentifiers: [222]))

    XCTAssertEqual(hitTester.hitTest(at: CGPoint(x: 10, y: 10)).snapshot?.windowIdentifier, 222)
    XCTAssertEqual(bundleProvider.requests, [222])
  }

  func testHitTesterUsesHalfOpenPointEdgesBeforeMetadataLookup() {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(
        layer: 0, frame: CGRect(x: 10, y: 20, width: 30, height: 40),
        ownerProcessIdentifier: 111, windowIdentifier: 111)
    ])
    let bundleProvider = RecordingWindowBundleIdentifierProvider()
    let hitTester = WindowHitTester(
      listProvider: provider, ownerBundleIdentifierProvider: bundleProvider)

    XCTAssertEqual(hitTester.hitTest(at: CGPoint(x: 10, y: 20)).snapshot?.windowIdentifier, 111)
    for point in [CGPoint(x: 40, y: 30), CGPoint(x: 20, y: 60), CGPoint(x: 9, y: 30)] {
      XCTAssertEqual(hitTester.hitTest(at: point), .miss(.noMatchingWindowAtPoint))
    }
    XCTAssertEqual(bundleProvider.requests, [111])
    XCTAssertEqual(provider.requests.count, 4)
  }

  func testHitTesterSkipsBundleLookupForWindowsOutsidePoint() {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(
        layer: 0,
        frame: CGRect(x: 200, y: 200, width: 100, height: 100),
        ownerProcessIdentifier: 111
      )
    ])
    let bundleProvider = CountingBundleIdentifierProvider()
    let hitTester = WindowHitTester(
      listProvider: provider,
      ownerBundleIdentifierProvider: bundleProvider
    )

    XCTAssertEqual(
      hitTester.hitTest(at: CGPoint(x: 10, y: 10)),
      .miss(.noMatchingWindowAtPoint)
    )
    XCTAssertEqual(bundleProvider.callCount, 0)
  }

  func testHitTesterReturnsWindowListUnavailableWhenProviderReturnsNil() {
    let provider = WindowListProviderSpy(entries: nil)
    let hitTester = WindowHitTester(
      listProvider: provider,
      ownerBundleIdentifierProvider: makeBundleIdentifierProvider()
    )
    XCTAssertEqual(hitTester.hitTest(at: CGPoint(x: 10, y: 10)), .miss(.sourceUnavailable))
  }

  func testHitTesterDoesNotTransformPointWhenWindowListUnavailable() {
    let transformCount = OSAllocatedUnfairLock(initialState: 0)
    let provider = WindowListProviderSpy(entries: nil)
    let hitTester = WindowHitTester(
      listProvider: provider,
      pointTransform: { point in
        transformCount.withLock { $0 += 1 }
        return point
      },
      ownerBundleIdentifierProvider: makeBundleIdentifierProvider()
    )

    XCTAssertEqual(hitTester.hitTest(at: CGPoint(x: 10, y: 10)), .miss(.sourceUnavailable))
    XCTAssertEqual(transformCount.withLock { $0 }, 0)
  }

  func testHitTesterReadsDefaultOnScreenWindowList() {
    let provider = WindowListProviderSpy(entries: [])
    let hitTester = WindowHitTester(listProvider: provider)

    _ = hitTester.hitTest(at: CGPoint(x: 10, y: 10))

    XCTAssertEqual(provider.requests, [.onScreenWindows])
  }

  func testHitTesterForwardsCustomWindowListOptions() {
    let provider = WindowListProviderSpy(entries: [])
    let hitTester = WindowHitTester(
      request: .windows(options: [.optionAll]),
      listProvider: provider
    )

    _ = hitTester.hitTest(at: CGPoint(x: 10, y: 10))

    XCTAssertEqual(provider.requests, [.windows(options: [.optionAll])])
  }

  func testHitTesterReturnsNoMatchingWindowAtPointWhenNoFrameContainsPoint() {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(
        layer: 0, frame: CGRect(x: 0, y: 0, width: 50, height: 50), ownerProcessIdentifier: 111)
    ])
    let hitTester = WindowHitTester(
      listProvider: provider,
      ownerBundleIdentifierProvider: makeBundleIdentifierProvider()
    )
    XCTAssertEqual(hitTester.hitTest(at: CGPoint(x: 100, y: 100)), .miss(.noMatchingWindowAtPoint))
  }

  func testHitTesterStandardizesFrameBeforeHitTesting() {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(
        layer: 0,
        frame: CGRect(x: 100, y: 100, width: -100, height: -100),
        ownerProcessIdentifier: 111
      )
    ])
    let hitTester = WindowHitTester(listProvider: provider)

    XCTAssertEqual(
      hitTester.hitTest(at: CGPoint(x: 10, y: 10)).snapshot?.ownerProcessIdentifier,
      111
    )
  }

  func testHitTesterReturnsNoWindowWhenOwnerProcessIdentifierMissing() {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(
        layer: 0, frame: CGRect(x: 0, y: 0, width: 100, height: 100), ownerProcessIdentifier: nil)
    ])
    let hitTester = WindowHitTester(
      listProvider: provider,
      ownerBundleIdentifierProvider: makeBundleIdentifierProvider()
    )
    XCTAssertEqual(hitTester.hitTest(at: CGPoint(x: 10, y: 10)), .miss(.noMatchingWindowAtPoint))
  }

  func testHitTesterReturnsNoWindowWhenWindowIdentifierMissing() {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(
        layer: 0,
        frame: CGRect(x: 0, y: 0, width: 100, height: 100),
        ownerProcessIdentifier: 111,
        windowIdentifier: nil
      )
    ])
    let hitTester = WindowHitTester(
      listProvider: provider,
      ownerBundleIdentifierProvider: makeBundleIdentifierProvider()
    )
    XCTAssertEqual(hitTester.hitTest(at: CGPoint(x: 10, y: 10)), .miss(.noMatchingWindowAtPoint))
  }

  func testHitTesterFiltersByLayer() {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(
        layer: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), ownerProcessIdentifier: 111),
      makeWindowEntry(
        layer: 0, frame: CGRect(x: 0, y: 0, width: 100, height: 100), ownerProcessIdentifier: 222),
    ])
    let hitTester = WindowHitTester(listProvider: provider)
    switch hitTester.hitTest(at: CGPoint(x: 10, y: 10)) {
    case .hit(let window):
      XCTAssertEqual(window.ownerProcessIdentifier, 222)
    case .miss(let reason):
      XCTFail("Expected hit, got miss(\(reason))")
    }
  }

  func testHitTesterReturnsFirstMatchingWindow() {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(
        layer: 0, frame: CGRect(x: 0, y: 0, width: 100, height: 100), ownerProcessIdentifier: 111),
      makeWindowEntry(
        layer: 0, frame: CGRect(x: 0, y: 0, width: 100, height: 100), ownerProcessIdentifier: 222),
    ])
    let hitTester = WindowHitTester(listProvider: provider)

    switch hitTester.hitTest(at: CGPoint(x: 10, y: 10)) {
    case .hit(let window):
      XCTAssertEqual(window.ownerProcessIdentifier, 111)
    case .miss(let reason):
      XCTFail("Expected hit, got miss(\(reason))")
    }
  }

  func testHitTesterAppliesPointTransform() {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(
        layer: 0, frame: CGRect(x: 0, y: 0, width: 100, height: 100), ownerProcessIdentifier: 222)
    ])
    let hitTester = WindowHitTester(
      listProvider: provider,
      pointTransform: { CGPoint(x: $0.x - 20, y: $0.y - 20) },
      ownerBundleIdentifierProvider: makeBundleIdentifierProvider()
    )

    switch hitTester.hitTest(at: CGPoint(x: 110, y: 110)) {
    case .hit(let window):
      XCTAssertEqual(window.ownerProcessIdentifier, 222)
    case .miss(let reason):
      XCTFail("Expected hit, got miss(\(reason))")
    }
  }

  func testHitTesterIncludesOwnerNameAndTitle() {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(
        layer: 0, frame: CGRect(x: 0, y: 0, width: 100, height: 100), ownerProcessIdentifier: 222)
    ])
    let hitTester = WindowHitTester(
      listProvider: provider,
      ownerBundleIdentifierProvider: makeBundleIdentifierProvider()
    )
    switch hitTester.hitTest(at: CGPoint(x: 10, y: 10)) {
    case .hit(let window):
      XCTAssertEqual(window.ownerName, "ExampleApp")
      XCTAssertEqual(window.ownerBundleIdentifier, "com.example.app")
      XCTAssertEqual(window.title, "Main")
    case .miss(let reason):
      XCTFail("Expected hit, got miss(\(reason))")
    }
  }

  func testHitTesterIncludesWindowIdentifierWhenPresent() {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(
        layer: 0, frame: CGRect(x: 0, y: 0, width: 100, height: 100), ownerProcessIdentifier: 222)
    ])
    let hitTester = WindowHitTester(
      listProvider: provider,
      ownerBundleIdentifierProvider: makeBundleIdentifierProvider()
    )
    switch hitTester.hitTest(at: CGPoint(x: 10, y: 10)) {
    case .hit(let window):
      XCTAssertEqual(window.windowIdentifier, 12345)
    case .miss(let reason):
      XCTFail("Expected hit, got miss(\(reason))")
    }
  }

  func testHitTesterFiltersExcludedOwnerApplicationIdentifiers() {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(
        layer: 0, frame: CGRect(x: 0, y: 0, width: 100, height: 100), ownerProcessIdentifier: 222)
    ])
    let hitTester = WindowHitTester(
      listProvider: provider,
      ownerBundleIdentifierProvider: makeBundleIdentifierProvider(
        bundleIdentifier: "com.example.blocked"),
      filter: WindowSnapshotFilter(excludedOwnerApplicationIdentifiers: ["com.example.blocked"])
    )

    XCTAssertEqual(hitTester.hitTest(at: CGPoint(x: 10, y: 10)), .miss(.noMatchingWindowAtPoint))
  }

  func testHitTesterFiltersIncludedOwnerApplicationIdentifiers() {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(
        layer: 0, frame: CGRect(x: 0, y: 0, width: 100, height: 100), ownerProcessIdentifier: 222)
    ])
    let hitTester = WindowHitTester(
      listProvider: provider,
      ownerBundleIdentifierProvider: makeBundleIdentifierProvider(
        bundleIdentifier: "com.example.allowed"),
      filter: WindowSnapshotFilter(includedOwnerApplicationIdentifiers: ["com.example.allowed"])
    )

    XCTAssertEqual(
      hitTester.hitTest(at: CGPoint(x: 10, y: 10)).snapshot?.ownerProcessIdentifier, 222)
  }

  func testHitTesterFiltersIncludedWindowIdentifiers() {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(
        layer: 0, frame: CGRect(x: 0, y: 0, width: 100, height: 100),
        ownerProcessIdentifier: 111,
        windowIdentifier: 111),
      makeWindowEntry(
        layer: 0, frame: CGRect(x: 0, y: 0, width: 100, height: 100),
        ownerProcessIdentifier: 222,
        windowIdentifier: 222),
    ])
    let hitTester = WindowHitTester(
      listProvider: provider,
      filter: WindowSnapshotFilter(includedWindowIdentifiers: [222])
    )

    XCTAssertEqual(hitTester.hitTest(at: CGPoint(x: 10, y: 10)).snapshot?.windowIdentifier, 222)
  }

  func testHitTesterIsSendable() {
    let hitTester = WindowHitTester(listProvider: WindowListProviderSpy(entries: []))

    assertSendable(hitTester)
  }

  private func makeBundleIdentifierProvider(
    bundleIdentifier: String = "com.example.app"
  ) -> WindowOwnerBundleIdentifierProvidingStub {
    WindowOwnerBundleIdentifierProvidingStub(bundleIdentifier: bundleIdentifier)
  }

  private func assertSendable<Value: Sendable>(_: Value) {}
}

private struct CountingBundleIdentifierProvider: WindowOwnerBundleIdentifierProviding {
  private let callCountStorage = OSAllocatedUnfairLock(initialState: 0)

  var callCount: Int {
    callCountStorage.withLock { $0 }
  }

  func bundleIdentifier(forProcessIdentifier _: pid_t) -> String? {
    callCountStorage.withLock { $0 += 1 }
    return "com.example.app"
  }
}
