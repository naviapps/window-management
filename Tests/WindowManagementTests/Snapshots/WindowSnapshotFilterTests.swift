import WindowManagement
import XCTest

final class WindowSnapshotFilterTests: XCTestCase {
  func testCodableUsesSharedFilterDefaultsAndValidation() throws {
    let decoder = JSONDecoder()
    let partial = Data(#"{"includedWindowIdentifiers":[20]}"#.utf8)
    XCTAssertEqual(
      try decoder.decode(WindowSnapshotFilter.self, from: partial),
      WindowSnapshotFilter(includedWindowIdentifiers: [20])
    )
    XCTAssertEqual(
      try decoder.decode(WindowSnapshotFilter.self, from: Data("{}".utf8)),
      WindowSnapshotFilter()
    )
    let unknown = Data(#"{"unknown":true}"#.utf8)
    XCTAssertThrowsError(try decoder.decode(WindowSnapshotFilter.self, from: unknown)) { error in
      guard case DecodingError.dataCorrupted = error else {
        return XCTFail("Expected a Codable data-corruption error, got \(error)")
      }
    }
  }

  func testOriginalJSONUsesDefaultsAndPreservesDuplicateKeyValidation() throws {
    let filter = try WindowSnapshotFilter(
      jsonData: Data(#"{"includedOwnerApplicationIdentifiers":["com.example.allowed"]}"#.utf8))
    XCTAssertEqual(
      filter, WindowSnapshotFilter(includedOwnerApplicationIdentifiers: ["com.example.allowed"]))
    XCTAssertTrue(filter.includes(makeSnapshot()))
    XCTAssertEqual(try WindowSnapshotFilter(jsonData: Data("{}".utf8)), WindowSnapshotFilter())
    let duplicate = Data(#"{"includedWindowIdentifiers":[1],"includedWindowIdentifiers":[2]}"#.utf8)
    XCTAssertThrowsError(try WindowSnapshotFilter(jsonData: duplicate)) { error in
      XCTAssertTrue(error is WindowRequestCodecError)
    }
  }

  func testJSONPreservesWideNumericFilterIdentifiers() throws {
    let json = Data(
      """
      {"includedOwnerProcessIdentifiers":[111,-9223372036854775808,9223372036854775807],
       "includedWindowIdentifiers":[222,18446744073709551615],
       "excludedOwnerProcessIdentifiers":[4294967407],"excludedWindowIdentifiers":[4294967518]}
      """.utf8)
    let filter = try WindowSnapshotFilter(jsonData: json)
    XCTAssertTrue(filter.includedOwnerProcessIdentifiers.contains(.min))
    XCTAssertTrue(filter.includedOwnerProcessIdentifiers.contains(.max))
    XCTAssertTrue(filter.includedWindowIdentifiers.contains(.max))
    XCTAssertEqual(filter.excludedOwnerProcessIdentifiers, [4_294_967_407])
    XCTAssertEqual(filter.excludedWindowIdentifiers, [4_294_967_518])
    XCTAssertTrue(filter.includes(makeSnapshot()))
    XCTAssertEqual(try WindowSnapshotFilter(jsonData: filter.jsonData), filter)
    XCTAssertEqual(
      try JSONDecoder().decode(WindowSnapshotFilter.self, from: JSONEncoder().encode(filter)),
      filter)
  }

  func testJSONPreservesOpaqueIdentifiersThroughCodableRoundTrip() throws {
    let composed = "\u{00e9}"
    let decomposed = "e\u{0301}"
    let json = Data(#"{"includedOwnerApplicationIdentifiers":["\u00e9","e\u0301"]}"#.utf8)
    let filter = try WindowSnapshotFilter(jsonData: json)
    let encoded = try JSONEncoder().encode(filter)
    let roundTrip = try JSONDecoder().decode(WindowSnapshotFilter.self, from: encoded)

    for candidate in [filter, roundTrip] {
      XCTAssertTrue(candidate.includes(makeSnapshot(ownerBundleIdentifier: composed)))
      XCTAssertTrue(candidate.includes(makeSnapshot(ownerBundleIdentifier: decomposed)))
    }

    let composedOnly = WindowSnapshotFilter(includedOwnerApplicationIdentifiers: [composed])
    let decomposedOnly = WindowSnapshotFilter(includedOwnerApplicationIdentifiers: [decomposed])
    XCTAssertNotEqual(composedOnly, decomposedOnly)
    XCTAssertNotEqual(filter, composedOnly)
    XCTAssertEqual(roundTrip, filter)
    XCTAssertEqual(Set([composedOnly, decomposedOnly, filter, roundTrip]).count, 3)
    XCTAssertEqual(try WindowSnapshotFilter(jsonData: filter.jsonData), filter)
  }

  func testCompiledFilterSupportsConcurrentValueCopies() async {
    let filter = WindowSnapshotFilter(includedOwnerProcessIdentifiers: [111])
    let snapshot = makeSnapshot()
    let results = await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<16 { group.addTask { filter.includes(snapshot) } }
      var results: [Bool] = []
      for await result in group { results.append(result) }
      return results
    }
    XCTAssertEqual(results, Array(repeating: true, count: 16))
  }
  func testInitUsesDefaultFilterOptions() {
    let filter = WindowSnapshotFilter()

    XCTAssertTrue(filter.includedOwnerApplicationIdentifiers.isEmpty)
    XCTAssertTrue(filter.includedOwnerProcessIdentifiers.isEmpty)
    XCTAssertTrue(filter.includedWindowIdentifiers.isEmpty)
    XCTAssertTrue(filter.excludedOwnerApplicationIdentifiers.isEmpty)
    XCTAssertTrue(filter.excludedOwnerProcessIdentifiers.isEmpty)
    XCTAssertTrue(filter.excludedWindowIdentifiers.isEmpty)
  }

  func testInitStoresFilterOptions() {
    let filter = makeFilter()

    XCTAssertEqual(filter.includedOwnerApplicationIdentifiers, ["com.example.allowed"])
    XCTAssertEqual(filter.includedOwnerProcessIdentifiers, [111])
    XCTAssertEqual(filter.includedWindowIdentifiers, [222])
    XCTAssertEqual(filter.excludedOwnerApplicationIdentifiers, ["com.example.blocked"])
    XCTAssertEqual(filter.excludedOwnerProcessIdentifiers, [333])
    XCTAssertEqual(filter.excludedWindowIdentifiers, [444])
  }

  func testWindowSnapshotFilterValueConformance() throws {
    try assertValueConformance(WindowSnapshotFilter())
    try assertValueConformance(makeFilter())
  }

  func testWindowSnapshotFilterIsSendable() {
    assertSendable(makeFilter())
  }

  func testSnapshotProjectsNumericAndApplicationIdentityToFilter() {
    let filter = makeFilter()
    XCTAssertTrue(filter.includes(makeSnapshot()))
    XCTAssertFalse(filter.includes(makeSnapshot(ownerBundleIdentifier: "com.example.other")))
    XCTAssertFalse(filter.includes(makeSnapshot(ownerProcessIdentifier: 333)))
    XCTAssertFalse(filter.includes(makeSnapshot(windowIdentifier: 444)))
    XCTAssertFalse(filter.includes(makeSnapshot(ownerBundleIdentifier: nil)))
  }

  func testIdentityMatchDistinguishesRejectionAndApplicationRequirements() {
    let numeric = WindowSnapshotFilter(
      includedOwnerProcessIdentifiers: [111], includedWindowIdentifiers: [222],
      excludedWindowIdentifiers: [333])
    XCTAssertEqual(
      numeric.matchIdentity(windowIdentifier: 222, ownerProcessIdentifier: 111), .included)
    XCTAssertEqual(
      numeric.matchIdentity(windowIdentifier: 222, ownerProcessIdentifier: 333), .excluded)
    for filter in [
      WindowSnapshotFilter(includedOwnerApplicationIdentifiers: [""]),
      WindowSnapshotFilter(
        excludedOwnerApplicationIdentifiers: [""], excludedWindowIdentifiers: [333]),
    ] {
      XCTAssertEqual(
        filter.matchIdentity(windowIdentifier: 222, ownerProcessIdentifier: 111),
        .requiresApplicationIdentifier)
    }
  }

  func testScalarSelectionPreservesOpaqueApplicationIdentifierPresence() {
    let identifier = "日本語😀\0window"
    let filter = WindowSnapshotFilter(includedOwnerApplicationIdentifiers: ["", identifier])
    XCTAssertTrue(
      filter.includes(
        windowIdentifier: 222, ownerProcessIdentifier: 111, ownerApplicationIdentifier: ""))
    XCTAssertTrue(
      filter.includes(
        windowIdentifier: 222, ownerProcessIdentifier: 111, ownerApplicationIdentifier: identifier))
    XCTAssertFalse(
      filter.includes(
        windowIdentifier: 222, ownerProcessIdentifier: 111, ownerApplicationIdentifier: nil))
    XCTAssertFalse(
      filter.includes(
        windowIdentifier: 222, ownerProcessIdentifier: 111, ownerApplicationIdentifier: "日本語😀"))
  }

  func testScalarSelectionPreservesPlatformNumericValues() {
    let all = WindowSnapshotFilter()
    XCTAssertTrue(
      all.includes(
        windowIdentifier: 0, ownerProcessIdentifier: 0, ownerApplicationIdentifier: nil))
    XCTAssertTrue(
      all.includes(
        windowIdentifier: .max, ownerProcessIdentifier: -1, ownerApplicationIdentifier: nil))
    let selected = WindowSnapshotFilter(
      includedOwnerProcessIdentifiers: [-1], includedWindowIdentifiers: [UInt64(CGWindowID.max)])
    XCTAssertTrue(
      selected.includes(
        windowIdentifier: .max, ownerProcessIdentifier: -1, ownerApplicationIdentifier: nil))
    XCTAssertFalse(
      selected.includes(
        windowIdentifier: 0, ownerProcessIdentifier: -1, ownerApplicationIdentifier: nil))
    XCTAssertFalse(
      selected.includes(
        windowIdentifier: .max, ownerProcessIdentifier: 0, ownerApplicationIdentifier: nil))
    XCTAssertFalse(
      WindowSnapshotFilter(excludedOwnerProcessIdentifiers: [-1]).includes(
        windowIdentifier: .max, ownerProcessIdentifier: -1, ownerApplicationIdentifier: nil))
    XCTAssertFalse(
      WindowSnapshotFilter(excludedWindowIdentifiers: [UInt64(CGWindowID.max)]).includes(
        windowIdentifier: .max, ownerProcessIdentifier: -1, ownerApplicationIdentifier: nil))
  }

  private func makeFilter() -> WindowSnapshotFilter {
    WindowSnapshotFilter(
      includedOwnerApplicationIdentifiers: ["com.example.allowed"],
      includedOwnerProcessIdentifiers: [111],
      includedWindowIdentifiers: [222],
      excludedOwnerApplicationIdentifiers: ["com.example.blocked"],
      excludedOwnerProcessIdentifiers: [333],
      excludedWindowIdentifiers: [444]
    )
  }

  private func makeSnapshot(
    ownerProcessIdentifier: pid_t = 111,
    windowIdentifier: CGWindowID = 222,
    ownerBundleIdentifier: String? = "com.example.allowed"
  ) -> WindowSnapshot {
    WindowSnapshot(
      ownerProcessIdentifier: ownerProcessIdentifier,
      windowIdentifier: windowIdentifier,
      ownerName: "Allowed",
      ownerBundleIdentifier: ownerBundleIdentifier,
      title: "Main",
      frame: .zero,
    )
  }

  private func assertSendable<Value: Sendable>(_: Value) {}
}
