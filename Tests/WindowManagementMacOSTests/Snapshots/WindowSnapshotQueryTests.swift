import CoreGraphics
import WindowManagement
import XCTest
import os

@testable import WindowManagementMacOS

final class WindowSnapshotQueryTests: XCTestCase {
  func testSnapshotQuerySkipsEntriesWithNonFiniteFrames() throws {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(
        layer: 0,
        frame: CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100),
        ownerProcessIdentifier: 123
      )
    ])

    XCTAssertTrue(try WindowSnapshotQuery(listProvider: provider).snapshots().isEmpty)
  }

  func testSnapshotQueryReadsDefaultOnScreenWindowList() throws {
    let provider = WindowListProviderSpy(entries: [])
    let query = WindowSnapshotQuery(listProvider: provider)

    _ = try query.snapshots()

    XCTAssertEqual(provider.requests, [.onScreenWindows])
  }

  func testSnapshotQueryForwardsCustomWindowListOptions() throws {
    let provider = WindowListProviderSpy(entries: [])
    let query = WindowSnapshotQuery(
      request: .windows(options: [.optionAll]),
      listProvider: provider
    )

    _ = try query.snapshots()

    XCTAssertEqual(provider.requests, [.windows(options: [.optionAll])])
  }

  func testSnapshotQueryIsSendable() {
    assertSendable(WindowSnapshotQuery(listProvider: WindowListProviderSpy(entries: [])))
  }

  func testSnapshotQueryFiltersByLayer() throws {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(
        layer: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), ownerProcessIdentifier: 111),
      makeWindowEntry(
        layer: 0, frame: CGRect(x: 10, y: 10, width: 100, height: 100), ownerProcessIdentifier: 222
      ),
    ])

    let query = WindowSnapshotQuery(
      listProvider: provider,
      ownerBundleIdentifierProvider: WindowOwnerBundleIdentifierProvidingStub(
        bundleIdentifier: "com.example.app")
    )

    let snapshots = try query.snapshots()
    XCTAssertEqual(snapshots.count, 1)
    XCTAssertEqual(snapshots.first?.ownerProcessIdentifier, 222)
  }

  func testSnapshotQueryIncludesOwnerBundleIdentifier() throws {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(
        layer: 0, frame: CGRect(x: 0, y: 0, width: 100, height: 100), ownerProcessIdentifier: 123)
    ])

    let query = WindowSnapshotQuery(
      listProvider: provider,
      ownerBundleIdentifierProvider: WindowOwnerBundleIdentifierProvidingStub(
        bundleIdentifier: "com.example.app")
    )

    let snapshots = try query.snapshots()
    XCTAssertEqual(snapshots.first?.ownerBundleIdentifier, "com.example.app")
  }

  func testSnapshotQueryIncludesWindowMetadata() throws {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(
        layer: 0,
        frame: CGRect(x: 0, y: 0, width: 100, height: 100),
        ownerProcessIdentifier: 123,
        windowIdentifier: 456
      )
    ])

    let snapshot = try WindowSnapshotQuery(listProvider: provider).snapshots().first

    XCTAssertEqual(snapshot?.ownerName, "ExampleApp")
    XCTAssertEqual(snapshot?.title, "Main")
    XCTAssertEqual(snapshot?.windowIdentifier, 456)
  }

  func testSnapshotQueryStandardizesFrame() throws {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(
        layer: 0,
        frame: CGRect(x: 100, y: 100, width: -80, height: -60),
        ownerProcessIdentifier: 123
      )
    ])

    let query = WindowSnapshotQuery(listProvider: provider)

    XCTAssertEqual(
      try query.snapshots().first?.frame,
      CGRect(x: 20, y: 40, width: 80, height: 60)
    )
  }

  func testSnapshotQueryCanBeUsedThroughSnapshotProvidingProtocol() throws {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 123, windowIdentifier: 456)
    ])
    let query: any WindowSnapshotProviding & WindowSnapshotResolving =
      WindowSnapshotQuery(listProvider: provider)

    XCTAssertEqual(try query.snapshots().map(\.windowIdentifier), [456])
    XCTAssertEqual(try query.snapshot(for: 456)?.windowIdentifier, 456)
  }

  func testSnapshotQuerySkipsEntriesWithoutWindowIdentifier() throws {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 123, windowIdentifier: nil)
    ])

    let query = WindowSnapshotQuery(
      listProvider: provider,
      ownerBundleIdentifierProvider: WindowOwnerBundleIdentifierProvidingStub(
        bundleIdentifier: "com.example.app")
    )

    XCTAssertTrue(try query.snapshots().isEmpty)
  }

  func testSnapshotQuerySkipsCGWindowEntriesWithInvalidIdentifiers() throws {
    let provider = NativeWindowListProviderSpy(windowInfo: [
      makeCGWindowInfo(
        ownerProcessIdentifier: NSNumber(value: 123),
        windowIdentifier: NSNumber(value: -1)),
      makeCGWindowInfo(
        ownerProcessIdentifier: NSNumber(value: -1),
        windowIdentifier: NSNumber(value: 456)),
      makeCGWindowInfo(
        ownerProcessIdentifier: NSNumber(value: 123),
        windowIdentifier: NSNumber(value: 1.5)),
      makeCGWindowInfo(
        ownerProcessIdentifier: NSNumber(value: true),
        windowIdentifier: NSNumber(value: 456)),
    ])
    let query = WindowSnapshotQuery(listProvider: provider)

    XCTAssertTrue(try query.snapshots().isEmpty)
  }

  func testSnapshotQuerySkipsCGWindowEntriesWithInvalidLayers() throws {
    let provider = NativeWindowListProviderSpy(windowInfo: [
      makeCGWindowInfo(
        layer: NSNumber(value: true),
        ownerProcessIdentifier: NSNumber(value: 123),
        windowIdentifier: NSNumber(value: 456)),
      makeCGWindowInfo(
        layer: NSNumber(value: 0.5),
        ownerProcessIdentifier: NSNumber(value: 123),
        windowIdentifier: NSNumber(value: 456)),
    ])
    let query = WindowSnapshotQuery(listProvider: provider)

    XCTAssertTrue(try query.snapshots().isEmpty)
  }

  func testSnapshotQuerySkipsNonFiniteAndOverflowNativeNumbersBeforeMetadata() throws {
    let invalidProcesses = [
      NSNumber(value: Double.nan), NSNumber(value: Double.infinity),
      NSNumber(value: Int64(Int32.max) + 1), NSNumber(value: 1.5),
    ]
    let invalidWindows = [
      NSNumber(value: Double.nan), NSNumber(value: Double.infinity),
      NSNumber(value: UInt64(UInt32.max) + 1), NSNumber(value: true),
    ]
    let info =
      invalidProcesses.map {
        makeCGWindowInfo(ownerProcessIdentifier: $0, windowIdentifier: 456)
      }
      + invalidWindows.map {
        makeCGWindowInfo(ownerProcessIdentifier: 123, windowIdentifier: $0)
      }
    let bundleProvider = RecordingWindowBundleIdentifierProvider()
    let query = WindowSnapshotQuery(
      listProvider: NativeWindowListProviderSpy(windowInfo: info),
      ownerBundleIdentifierProvider: bundleProvider)

    XCTAssertTrue(try query.snapshots().isEmpty)
    XCTAssertEqual(bundleProvider.requests, [])
  }

  func testSnapshotQuerySkipsMetadataForRejectedNumericIdentifiers() throws {
    let entries = [
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 123, windowIdentifier: 111),
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 456, windowIdentifier: 222),
    ]
    let filters: [WindowSnapshotFilter] = [
      .init(includedOwnerProcessIdentifiers: [456]),
      .init(includedWindowIdentifiers: [222]),
      .init(excludedOwnerProcessIdentifiers: [123]),
      .init(excludedWindowIdentifiers: [111]),
    ]
    for filter in filters {
      let bundleProvider = RecordingWindowBundleIdentifierProvider()
      let query = WindowSnapshotQuery(
        listProvider: WindowListProviderSpy(entries: entries),
        ownerBundleIdentifierProvider: bundleProvider, filter: filter)

      let selected = try query.snapshots()

      XCTAssertEqual(selected.map(\.windowIdentifier), [222])
      XCTAssertEqual(selected.first?.ownerBundleIdentifier, "com.example.app")
      XCTAssertEqual(selected.first?.ownerName, "ExampleApp")
      XCTAssertEqual(selected.first?.title, "Main")
      XCTAssertEqual(bundleProvider.requests, [456])
    }
  }

  func testSnapshotQueryDoesNotResolveMetadataWhenEveryNumericIdentifierIsRejected() throws {
    let entries = [
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 123, windowIdentifier: 111),
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 456, windowIdentifier: 222),
    ]
    for filter in [
      WindowSnapshotFilter(includedOwnerProcessIdentifiers: [999]),
      WindowSnapshotFilter(includedWindowIdentifiers: [999]),
    ] {
      let bundleProvider = RecordingWindowBundleIdentifierProvider()
      let query = WindowSnapshotQuery(
        listProvider: WindowListProviderSpy(entries: entries),
        ownerBundleIdentifierProvider: bundleProvider, filter: filter)

      XCTAssertTrue(try query.snapshots().isEmpty)
      XCTAssertEqual(bundleProvider.requests, [])
    }
  }

  func testSnapshotQueryResolvesApplicationConstraintsOnceAndRetainsUnknownMetadata() throws {
    let entries = [
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 123, windowIdentifier: 111),
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 456, windowIdentifier: 222),
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 789, windowIdentifier: 333),
    ]
    let filters: [(WindowSnapshotFilter, [CGWindowID])] = [
      (.init(includedOwnerApplicationIdentifiers: ["com.example.allowed"]), [222]),
      (.init(excludedOwnerApplicationIdentifiers: ["com.example.blocked"]), [111, 222]),
    ]
    for (filter, expected) in filters {
      let bundleProvider = RecordingWindowBundleIdentifierProvider {
        switch $0 {
        case 456: "com.example.allowed"
        case 789: "com.example.blocked"
        default: nil
        }
      }
      let query = WindowSnapshotQuery(
        listProvider: WindowListProviderSpy(entries: entries),
        ownerBundleIdentifierProvider: bundleProvider, filter: filter)

      let snapshots = try query.snapshots()

      XCTAssertEqual(snapshots.map(\.windowIdentifier), expected)
      XCTAssertEqual(bundleProvider.requests, [123, 456, 789])
      XCTAssertEqual(
        snapshots.first(where: { $0.windowIdentifier == 222 })?.ownerBundleIdentifier,
        "com.example.allowed")
      XCTAssertNil(snapshots.first(where: { $0.windowIdentifier == 111 })?.ownerBundleIdentifier)
    }
  }

  func testSnapshotQuerySkipsApplicationLookupForNumericRejections() throws {
    let entries = [
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 123, windowIdentifier: 111),
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 456, windowIdentifier: 222),
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 789, windowIdentifier: 333),
    ]
    let provider = RecordingWindowBundleIdentifierProvider { _ in "com.example.allowed" }
    let filter = WindowSnapshotFilter(
      includedOwnerApplicationIdentifiers: ["com.example.allowed"],
      includedOwnerProcessIdentifiers: [123, 456], excludedWindowIdentifiers: [111])
    let query = WindowSnapshotQuery(
      listProvider: WindowListProviderSpy(entries: entries),
      ownerBundleIdentifierProvider: provider, filter: filter)

    let snapshots = try query.snapshots()
    XCTAssertEqual(snapshots.map(\.windowIdentifier), [222])
    XCTAssertEqual(snapshots.first?.ownerBundleIdentifier, "com.example.allowed")
    XCTAssertEqual(provider.requests, [456])
  }

  func testSnapshotQueryReadsFreshEntriesAndOwnerMetadataOnEachCall() throws {
    let provider = ChangingWindowListProvider(entries: [
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 123, windowIdentifier: 111)
    ])
    let bundleIdentifier = OSAllocatedUnfairLock(initialState: "com.example.first")
    let bundleProvider = RecordingWindowBundleIdentifierProvider { _ in
      bundleIdentifier.withLock { $0 }
    }
    let query = WindowSnapshotQuery(
      listProvider: provider, ownerBundleIdentifierProvider: bundleProvider)

    XCTAssertEqual(try query.snapshots().first?.ownerBundleIdentifier, "com.example.first")
    provider.replaceEntries(with: [
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 123, windowIdentifier: 222)
    ])
    bundleIdentifier.withLock { $0 = "com.example.updated" }
    let updated = try query.snapshots()

    XCTAssertEqual(updated.map(\.windowIdentifier), [222])
    XCTAssertEqual(updated.first?.ownerBundleIdentifier, "com.example.updated")
    XCTAssertEqual(bundleProvider.requests, [123, 123])
    XCTAssertEqual(provider.requests, [.onScreenWindows, .onScreenWindows])
  }

  func testSnapshotQueryFiltersExcludedOwnerApplicationIdentifiers() throws {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 123)
    ])

    let query = WindowSnapshotQuery(
      listProvider: provider,
      ownerBundleIdentifierProvider: WindowOwnerBundleIdentifierProvidingStub(
        bundleIdentifier: "com.example.blocked"),
      filter: WindowSnapshotFilter(excludedOwnerApplicationIdentifiers: ["com.example.blocked"])
    )

    XCTAssertTrue(try query.snapshots().isEmpty)
  }

  func testSnapshotQueryAppliesExcludedOwnerApplicationIdentifiersAfterIncludedOnes() throws {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 123)
    ])

    let query = WindowSnapshotQuery(
      listProvider: provider,
      ownerBundleIdentifierProvider: WindowOwnerBundleIdentifierProvidingStub(
        bundleIdentifier: "com.example.app"),
      filter: WindowSnapshotFilter(
        includedOwnerApplicationIdentifiers: ["com.example.app"],
        excludedOwnerApplicationIdentifiers: ["com.example.app"]
      )
    )

    XCTAssertTrue(try query.snapshots().isEmpty)
  }

  func testSnapshotQueryFiltersExcludedOwnerProcessIdentifiers() throws {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 123),
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 456),
    ])
    let bundleIdentifierProvider = WindowOwnerBundleIdentifierProvidingStub(
      bundleIdentifier: "com.example.app")

    let query = WindowSnapshotQuery(
      listProvider: provider,
      ownerBundleIdentifierProvider: bundleIdentifierProvider,
      filter: WindowSnapshotFilter(excludedOwnerProcessIdentifiers: [123])
    )

    let snapshots = try query.snapshots()
    XCTAssertEqual(snapshots.map(\.ownerProcessIdentifier), [456])
  }

  func testSnapshotQueryFiltersExcludedWindowIdentifiers() throws {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 123, windowIdentifier: 111),
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 456, windowIdentifier: 222),
    ])
    let bundleIdentifierProvider = WindowOwnerBundleIdentifierProvidingStub(
      bundleIdentifier: "com.example.app")

    let query = WindowSnapshotQuery(
      listProvider: provider,
      ownerBundleIdentifierProvider: bundleIdentifierProvider,
      filter: WindowSnapshotFilter(excludedWindowIdentifiers: [111])
    )

    let snapshots = try query.snapshots()
    XCTAssertEqual(snapshots.map(\.windowIdentifier), [222])
  }

  func testSnapshotQueryFiltersIncludedOwnerApplicationIdentifiers() throws {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 123)
    ])

    let query = WindowSnapshotQuery(
      listProvider: provider,
      ownerBundleIdentifierProvider: WindowOwnerBundleIdentifierProvidingStub(
        bundleIdentifier: "com.example.allowed"),
      filter: WindowSnapshotFilter(includedOwnerApplicationIdentifiers: ["com.example.allowed"])
    )

    XCTAssertEqual(try query.snapshots().map(\.ownerProcessIdentifier), [123])
  }

  func testSnapshotQueryRejectsIncludedOwnerBundleIdentifierWhenIdentifierIsUnavailable() throws {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 123)
    ])

    let query = WindowSnapshotQuery(
      listProvider: provider,
      ownerBundleIdentifierProvider: WindowOwnerBundleIdentifierProvidingStub(
        bundleIdentifier: nil),
      filter: WindowSnapshotFilter(includedOwnerApplicationIdentifiers: ["com.example.allowed"])
    )

    XCTAssertTrue(try query.snapshots().isEmpty)
  }

  func testSnapshotQueryFiltersIncludedOwnerProcessIdentifiers() throws {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 123),
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 456),
    ])

    let query = WindowSnapshotQuery(
      listProvider: provider,
      filter: WindowSnapshotFilter(includedOwnerProcessIdentifiers: [456])
    )

    XCTAssertEqual(try query.snapshots().map(\.ownerProcessIdentifier), [456])
  }

  func testSnapshotQueryFiltersIncludedWindowIdentifiers() throws {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 123, windowIdentifier: 111),
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 456, windowIdentifier: 222),
    ])

    let query = WindowSnapshotQuery(
      listProvider: provider,
      filter: WindowSnapshotFilter(includedWindowIdentifiers: [222])
    )

    XCTAssertEqual(try query.snapshots().map(\.windowIdentifier), [222])
  }

  func testSnapshotForWindowIdentifierReadsSingleWindowList() throws {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 123, windowIdentifier: 222)
    ])

    let query = WindowSnapshotQuery(listProvider: provider)
    let snapshot = try query.snapshot(for: 222)

    XCTAssertEqual(snapshot?.windowIdentifier, 222)
    XCTAssertEqual(provider.requests, [.window(222)])
  }

  func testSnapshotForWindowIdentifierForwardsCustomSingleWindowListOptions() throws {
    let provider = WindowListProviderSpy(entries: [])
    let query = WindowSnapshotQuery(
      makeSingleWindowRequest: { .window($0, options: [.optionAll]) },
      listProvider: provider
    )

    _ = try query.snapshot(for: 222)

    XCTAssertEqual(provider.requests, [.window(222, options: [.optionAll])])
  }

  func testSnapshotForWindowIdentifierReturnsNilWhenFilteredOut() throws {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 123, windowIdentifier: 222)
    ])

    let query = WindowSnapshotQuery(
      listProvider: provider,
      filter: WindowSnapshotFilter(excludedWindowIdentifiers: [222])
    )

    XCTAssertNil(try query.snapshot(for: 222))
  }

  func testSnapshotForWindowIdentifierThrowsWhenWindowListUnavailable() {
    let query = WindowSnapshotQuery(listProvider: WindowListProviderSpy(entries: nil))

    XCTAssertThrowsError(try query.snapshot(for: 222)) { error in
      XCTAssertEqual(error as? WindowSnapshotQueryError, .windowListUnavailable)
    }
  }

  func testSnapshotForWindowIdentifierReturnsNilWhenReturnedEntryDoesNotMatchIdentifier() throws {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 123, windowIdentifier: 111)
    ])

    let query = WindowSnapshotQuery(listProvider: provider)

    XCTAssertNil(try query.snapshot(for: 222))
  }

  func testSnapshotForWindowIdentifierDoesNotResolveUnrelatedOwnerMetadata() throws {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 123, windowIdentifier: 111)
    ])
    let bundleProvider = RecordingWindowBundleIdentifierProvider()
    let query = WindowSnapshotQuery(
      listProvider: provider, ownerBundleIdentifierProvider: bundleProvider)

    XCTAssertNil(try query.snapshot(for: 222))
    XCTAssertEqual(bundleProvider.requests, [])
    XCTAssertEqual(provider.requests, [.window(222)])
  }

  func testSnapshotForWindowIdentifierReadsMatchedIDOnceAndStopsBeforeTail() throws {
    let wrong = ObservedWindowInfo(values: makeRawWindowInfo(windowIdentifier: 111))
    let winner = ObservedWindowInfo(
      values: makeRawWindowInfo(
        ownerProcessIdentifier: 456, windowIdentifier: 222))
    let tail = ObservedWindowInfo(values: makeRawWindowInfo(windowIdentifier: 333))
    let provider = NativeWindowListProviderSpy(windowInfo: [wrong, winner, tail])
    let bundleProvider = RecordingWindowBundleIdentifierProvider()
    let query = WindowSnapshotQuery(
      listProvider: provider, ownerBundleIdentifierProvider: bundleProvider)

    let result = try query.snapshot(for: 222)

    XCTAssertEqual(result?.windowIdentifier, 222)
    XCTAssertEqual(result?.ownerProcessIdentifier, 456)
    XCTAssertEqual(result?.ownerName, "ExampleApp")
    XCTAssertEqual(result?.title, "Main")
    XCTAssertEqual(wrong.lookedUpKeys, [kCGWindowNumber as String])
    XCTAssertEqual(winner.lookedUpKeys.filter { $0 == kCGWindowNumber as String }.count, 1)
    XCTAssertEqual(winner.lookedUpKeys.count, 6)
    XCTAssertEqual(tail.lookedUpKeys, [])
    XCTAssertEqual(bundleProvider.requests, [456])
    XCTAssertEqual(provider.requests, [.window(222)])
  }

  func testSnapshotQueryReturnsTopmostMatchingWindowWhenLimited() throws {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 1),
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 2),
    ])
    let bundleIdentifierProvider = WindowOwnerBundleIdentifierProvidingStub(
      bundleIdentifier: "com.example.app")

    let query = WindowSnapshotQuery(
      listProvider: provider,
      ownerBundleIdentifierProvider: bundleIdentifierProvider,
      limit: .topmostMatchingWindow
    )

    let snapshots = try query.snapshots()
    XCTAssertEqual(snapshots.map(\.ownerProcessIdentifier), [1])
  }

  func testSnapshotQueryReturnsFirstMatchingTopmostWindowWhenLimited() throws {
    let provider = WindowListProviderSpy(entries: [
      makeWindowEntry(layer: 1, frame: .zero, ownerProcessIdentifier: 1),
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 2),
      makeWindowEntry(layer: 0, frame: .zero, ownerProcessIdentifier: 3),
    ])

    let query = WindowSnapshotQuery(
      listProvider: provider,
      limit: .topmostMatchingWindow
    )

    XCTAssertEqual(try query.snapshots().map(\.ownerProcessIdentifier), [2])
  }

  func testSnapshotQueryThrowsWhenWindowListUnavailable() {
    let query = WindowSnapshotQuery(listProvider: WindowListProviderSpy(entries: nil))

    XCTAssertThrowsError(try query.snapshots()) { error in
      XCTAssertEqual(error as? WindowSnapshotQueryError, .windowListUnavailable)
    }
  }

  func testSnapshotQueryErrorIsEquatableAndSendable() {
    XCTAssertEqual(WindowSnapshotQueryError.windowListUnavailable, .windowListUnavailable)
    assertSendable(WindowSnapshotQueryError.windowListUnavailable)
  }
}

private func makeCGWindowInfo(
  layer: NSNumber = NSNumber(value: 0),
  ownerProcessIdentifier: NSNumber,
  windowIdentifier: NSNumber
) -> NSDictionary {
  [
    kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 100, height: 100)
      .dictionaryRepresentation,
    kCGWindowLayer as String: layer,
    kCGWindowOwnerPID as String: ownerProcessIdentifier,
    kCGWindowNumber as String: windowIdentifier,
  ]
}

private func assertSendable<Value: Sendable>(_: Value) {}
