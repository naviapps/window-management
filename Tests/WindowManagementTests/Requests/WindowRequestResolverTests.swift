import WindowManagement
import XCTest

final class WindowRequestResolverTests: XCTestCase {
  func testMovementPreservesSubnormalFrameDimensionsAcrossTheNativeBoundary() {
    let current = CGRect(x: 0, y: 0, width: 100, height: 100)
    let next = CGRect(x: 200, y: 0, width: 100, height: 100)
    let displays = [next, current].map { Display(frame: $0, visibleFrame: $0) }
    let size = CGFloat.leastNonzeroMagnitude
    let window = CGRect(x: 1, y: 1, width: size, height: size)

    XCTAssertEqual(
      WindowRequestResolver.movement(
        .init(direction: .next, preservesRelativePosition: false), windowFrame: window,
        in: displays),
      CGRect(x: 250, y: 50, width: size, height: size))
  }

  func testStrictByteCodecAndNativeIdentifierWidth() throws {
    let request = WindowPlacementRequest(
      placement: .fill, display: .displayIdentifier(.max), inset: .infinity)
    XCTAssertEqual(request.inset, 0)
    XCTAssertEqual(
      try WindowRequestCodec.decodePlacement(WindowRequestCodec.encode(request)), request)
    let duplicate = Data(#"{"placement":{"kind":"fill"},"inset":1,"inset":2}"#.utf8)
    XCTAssertThrowsError(try WindowRequestCodec.decodePlacement(duplicate)) { error in
      XCTAssertNotNil(error as? WindowRequestCodecError)
    }
    XCTAssertEqual(
      try WindowRequestCodec.decodeMovement(Data(#"{"direction":"next"}"#.utf8)),
      WindowMoveRequest(direction: .next))
  }

  func testRawAndNestedRequestCodecsPreserveExactFloatingPointCoordinates() throws {
    let original = Data(
      #"{"placement":{"kind":"fill"},"screen":{"kind":"point","x":-0.0,"y":5e-324}}"#.utf8)
    let strict = try WindowRequestCodec.decodePlacement(original)
    let nested = try JSONDecoder().decode(WindowPlacementRequest.self, from: original)
    for request in [strict, nested] {
      guard case .point(let value) = request.display else { return XCTFail("Expected point") }
      XCTAssertEqual(Double(value.x).bitPattern, (-0.0).bitPattern)
      XCTAssertEqual(Double(value.y).bitPattern, Double.leastNonzeroMagnitude.bitPattern)
      for encoded in try [WindowRequestCodec.encode(request), JSONEncoder().encode(request)] {
        guard case .point(let roundTrip) = try WindowRequestCodec.decodePlacement(encoded).display
        else { return XCTFail("Expected round-trip point") }
        XCTAssertEqual(Double(roundTrip.x).bitPattern, Double(value.x).bitPattern)
        XCTAssertEqual(Double(roundTrip.y).bitPattern, Double(value.y).bitPattern)
      }
    }
  }
  func testCompletePlacementAndMovementUseSharedFallbackAndCoordinates() {
    let left = Display(
      displayIdentifier: 0, frame: .init(x: 0, y: 0, width: 100, height: 80),
      visibleFrame: .init(x: 0, y: 0, width: 100, height: 80), isMain: true)
    let right = Display(
      displayIdentifier: 1, frame: .init(x: 100, y: 0, width: 100, height: 80),
      visibleFrame: .init(x: 100, y: 0, width: 100, height: 80), isMain: false
    )
    let displays = [right, left]
    let missing = WindowPlacementRequest(placement: .fill, display: .displayIdentifier(99))
    XCTAssertNil(WindowRequestResolver.placement(missing, windowFrame: .zero, in: displays))
    XCTAssertEqual(
      WindowRequestResolver.placement(
        missing, windowFrame: .zero, in: displays, fallback: .firstDisplay), left.visibleFrame)
    let frame = CGRect(x: 25, y: 20, width: 50, height: 40)
    XCTAssertEqual(
      WindowRequestResolver.movement(.init(direction: .next), windowFrame: frame, in: displays),
      CGRect(x: 125, y: 20, width: 50, height: 40))
    XCTAssertNil(
      WindowRequestResolver.movement(.init(direction: .next), windowFrame: frame, in: []))
  }
}
