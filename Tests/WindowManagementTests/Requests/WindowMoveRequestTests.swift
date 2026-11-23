import WindowManagement
import XCTest

final class WindowMoveRequestTests: XCTestCase {
  func testRoundTripsTypedCodableMovement() throws {
    let request = WindowMoveRequest(direction: .previous, preservesRelativePosition: false)
    let data = try JSONEncoder().encode(request)
    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertEqual(Set(fields.keys), ["direction", "preservesRelativePosition"])
    XCTAssertEqual(fields["direction"] as? String, "previous")
    XCTAssertEqual(fields["preservesRelativePosition"] as? Bool, false)
    XCTAssertEqual(try JSONDecoder().decode(WindowMoveRequest.self, from: data), request)
  }

  func testDecodingProjectsTheNativeRelativePositionDefault() throws {
    let data = Data(#"{"direction":"next"}"#.utf8)
    let request = try JSONDecoder().decode(WindowMoveRequest.self, from: data)

    XCTAssertEqual(request.direction, .next)
    XCTAssertTrue(request.preservesRelativePosition)
    XCTAssertTrue(WindowMoveRequest(direction: .next).preservesRelativePosition)
  }

  func testNestedDecodingKeepsThePathAndNativeError() {
    let data = Data(#"{"move":{"direction":"next","preservesRelativePosition":null}}"#.utf8)

    XCTAssertThrowsError(try JSONDecoder().decode([String: WindowMoveRequest].self, from: data)) {
      error in
      guard case DecodingError.dataCorrupted(let context) = error else {
        return XCTFail("Expected a Codable data-corruption error, got \(error)")
      }
      XCTAssertEqual(context.codingPath.map(\.stringValue), ["move"])
      XCTAssertNotNil(context.underlyingError as? WindowRequestCodecError)
    }
  }
}
