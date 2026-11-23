import Foundation

extension WindowPlacementRequest: Codable {
  /// Decode the Rust-normalized request, including its storage defaults.
  public init(from decoder: Decoder) throws {
    self = try WindowJSON.project(from: decoder, WindowRequestCodec.decodePlacement)
  }

  struct Canonical: Decodable {
    private let placement: WindowPlacement.Canonical
    private let screen: DisplayTarget.Canonical
    private let area: DisplayArea
    private let inset: CGFloat

    var value: WindowPlacementRequest {
      .init(normalizedPlacement: placement.value, display: screen.value, area: area, inset: inset)
    }
  }
  /// Encode the shared request contract.
  public func encode(to encoder: Encoder) throws {
    try WindowJSON.write(WindowRequestCodec.encode(self), to: encoder)
  }
}
extension WindowMoveRequest: Codable {
  /// Decode the shared movement contract and relative-position default.
  public init(from decoder: Decoder) throws {
    self = try WindowJSON.project(from: decoder, WindowRequestCodec.decodeMovement)
  }

  struct Canonical: Decodable {
    private let direction: DisplayCycleDirection
    private let preservesRelativePosition: Bool

    var value: WindowMoveRequest {
      .init(direction: direction, preservesRelativePosition: preservesRelativePosition)
    }
  }
  /// Encode the shared movement contract.
  public func encode(to encoder: Encoder) throws {
    try WindowJSON.write(WindowRequestCodec.encode(self), to: encoder)
  }
}
