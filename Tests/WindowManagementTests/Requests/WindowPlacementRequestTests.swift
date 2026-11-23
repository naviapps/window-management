import CoreGraphics
import WindowManagement
import XCTest

final class WindowPlacementRequestTests: XCTestCase {
  func testNormalizesPlacementGeometryToExecutableRanges() {
    XCTAssertEqual(
      WindowPlacementRequest(
        placement: .grid(
          columns: 0,
          rows: -2,
          column: 4,
          row: -1,
          columnSpan: 0,
          rowSpan: 9
        )
      ).placement,
      .grid(columns: 1, rows: 1, column: 0, row: 0, columnSpan: 1, rowSpan: 1)
    )
    XCTAssertEqual(
      WindowPlacementRequest(
        placement: .centered(widthRatio: .infinity, heightRatio: .nan)
      ).placement,
      .centered(widthRatio: 1, heightRatio: 0)
    )
  }

  func testNormalizesInvalidDisplaySelectors() {
    XCTAssertEqual(
      WindowPlacementRequest(
        placement: .fill,
        display: .point(.init(x: .nan, y: -.infinity))
      ).display,
      .point(.zero)
    )
    XCTAssertEqual(
      WindowPlacementRequest(placement: .fill, display: .orderedIndex(-1)).display,
      .orderedIndex(0)
    )
  }

  func testStandaloneWindowValuesCanonicalizeAtCodableBoundaries() throws {
    let placementData = try JSONEncoder().encode(
      WindowPlacement.centered(widthRatio: .infinity, heightRatio: -.infinity)
    )
    XCTAssertEqual(
      try JSONDecoder().decode(WindowPlacement.self, from: placementData),
      .centered(widthRatio: 1, heightRatio: 0)
    )

    let displayData = try JSONEncoder().encode(
      DisplayTarget.point(
        CGPoint(x: CGFloat.nan, y: CGFloat.infinity)
      )
    )
    XCTAssertEqual(
      try JSONDecoder().decode(DisplayTarget.self, from: displayData),
      .point(.zero)
    )

    let invalidGridData =
      #"{"kind":"grid","columns":0,"rows":-1,"column":8,"row":-2,"columnSpan":0,"rowSpan":9}"#.data(
        using: .utf8
      )!
    XCTAssertEqual(
      try JSONDecoder().decode(WindowPlacement.self, from: invalidGridData),
      .grid(columns: 1, rows: 1, column: 0, row: 0, columnSpan: 1, rowSpan: 1)
    )
  }

  func testUsesFocusedWindowDefaults() {
    let request = WindowPlacementRequest(placement: .fill)

    XCTAssertEqual(request.display, .containingWindow)
    XCTAssertEqual(request.area, .visible)
    XCTAssertEqual(request.inset, 0)
  }

  func testNormalizesInvalidInsets() {
    XCTAssertEqual(WindowPlacementRequest(placement: .fill, inset: -1).inset, 0)
    XCTAssertEqual(WindowPlacementRequest(placement: .fill, inset: .infinity).inset, 0)
    XCTAssertEqual(WindowPlacementRequest(placement: .fill, inset: .nan).inset, 0)
  }

  func testRoundTripsCodable() throws {
    let requests = [
      WindowPlacementRequest(placement: .fill),
      WindowPlacementRequest(
        placement: .grid(
          columns: 2,
          rows: 3,
          column: 1,
          row: 2,
          columnSpan: 1,
          rowSpan: 1
        ),
        display: .orderedIndex(1),
        area: .full,
        inset: 8
      ),
      WindowPlacementRequest(
        placement: .centered(widthRatio: 0.7, heightRatio: 0.5),
        display: .displayIdentifier(7),
        area: .full,
        inset: 12
      ),
      WindowPlacementRequest(
        placement: .grid(columns: 3, rows: 1, column: 1, row: 0, columnSpan: 2, rowSpan: 1),
        display: .point(.init(x: 10, y: 20))
      ),
    ]

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    for request in requests {
      XCTAssertEqual(
        try decoder.decode(WindowPlacementRequest.self, from: encoder.encode(request)),
        request
      )
    }
  }

  func testPublicWindowValueTypesRoundTripCodable() throws {
    let placements: [WindowPlacement] = [
      .fill,
      .grid(columns: 2, rows: 3, column: 1, row: 2, columnSpan: 1, rowSpan: 1),
      .centered(widthRatio: 0.7, heightRatio: 0.5),
    ]
    let displays: [DisplayTarget] = [
      .main,
      .containingWindow,
      .orderedIndex(2),
      .displayIdentifier(7),
      .point(.init(x: 10, y: 20)),
    ]
    let areas: [DisplayArea] = [.visible, .full]

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    for placement in placements {
      XCTAssertEqual(
        try decoder.decode(WindowPlacement.self, from: encoder.encode(placement)),
        placement
      )
    }
    for display in displays {
      XCTAssertEqual(
        try decoder.decode(DisplayTarget.self, from: encoder.encode(display)),
        display
      )
    }
    for area in areas {
      XCTAssertEqual(
        try decoder.decode(DisplayArea.self, from: encoder.encode(area)),
        area
      )
    }
  }

  func testDecodingNormalizesInvalidInsets() throws {
    let encoded = try JSONEncoder().encode(WindowPlacementRequest(placement: .fill))
    var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    payload["inset"] = -1
    let data = try JSONSerialization.data(withJSONObject: payload)

    let request = try JSONDecoder().decode(WindowPlacementRequest.self, from: data)

    XCTAssertEqual(request.inset, 0)
  }

  func testDecodingUsesFocusedWindowDefaultsWhenOptionalFieldsAreOmitted() throws {
    let encoded = try JSONEncoder().encode(WindowPlacementRequest(placement: .fill))
    var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    payload.removeValue(forKey: "screen")
    payload.removeValue(forKey: "area")
    payload.removeValue(forKey: "inset")
    let data = try JSONSerialization.data(withJSONObject: payload)

    XCTAssertEqual(
      try JSONDecoder().decode(WindowPlacementRequest.self, from: data),
      WindowPlacementRequest(placement: .fill)
    )
  }

  func testNestedCodablePreservesThePathAndTypedNativeRejection() {
    struct Stored: Decodable { let request: WindowPlacementRequest }
    let data = Data(#"{"request":{"placement":{"kind":"fill","columns":2}}}"#.utf8)

    XCTAssertThrowsError(try JSONDecoder().decode(Stored.self, from: data)) { error in
      guard case DecodingError.dataCorrupted(let context) = error else {
        return XCTFail("Expected a Codable data-corruption error, got \(error)")
      }
      XCTAssertEqual(context.codingPath.map(\.stringValue), ["request"])
      XCTAssertNotNil(context.underlyingError as? WindowRequestCodecError)
    }
  }

  func testCodableReadsAndWritesStoredPlacementRequest() throws {
    let stored = Data(
      """
      {
        "placement": {
          "kind": "grid", "columns": 2, "rows": 3, "column": 1, "row": 2,
          "columnSpan": 1, "rowSpan": 1
        },
        "screen": { "kind": "point", "x": 10, "y": 20 },
        "area": "full",
        "inset": 6
      }
      """.utf8
    )
    let expected = WindowPlacementRequest(
      placement: .grid(columns: 2, rows: 3, column: 1, row: 2, columnSpan: 1, rowSpan: 1),
      display: .point(.init(x: 10, y: 20)), area: .full, inset: 6)

    XCTAssertEqual(try JSONDecoder().decode(WindowPlacementRequest.self, from: stored), expected)

    let encoded = try JSONEncoder().encode(expected)
    XCTAssertEqual(
      try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? NSDictionary),
      try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? NSDictionary))
  }
}
