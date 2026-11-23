import Foundation

extension WindowPlacementRequest: Codable {
  /// Decode the Rust-normalized request, including its storage defaults.
  public init(from decoder: Decoder) throws {
    try self.init(canonicalFields: WindowJSON.read(from: decoder, kind: 2))
  }

  init(canonicalFields v: [String: WindowWireValue]) throws {
    self.init(
      placement: try WindowPlacement(canonicalFields: v.objectField("placement")),
      display: try DisplayTarget(canonicalFields: v.objectField("screen")),
      area: try v.field("area"),
      inset: try v.field("inset"))
  }
  /// Encode the shared request contract.
  public func encode(to encoder: Encoder) throws {
    try WindowJSON.write(WindowRequestCodec.encode(self), to: encoder)
  }
}
extension WindowMoveRequest: Codable {
  /// Decode the shared movement contract and relative-position default.
  public init(from decoder: Decoder) throws {
    try self.init(canonicalFields: WindowJSON.read(from: decoder, kind: 3))
  }

  init(canonicalFields v: [String: WindowWireValue]) throws {
    self.init(
      direction: try v.field("direction"),
      preservesRelativePosition: try v.field("preservesRelativePosition"))
  }
  /// Encode the shared movement contract.
  public func encode(to encoder: Encoder) throws {
    try WindowJSON.write(WindowRequestCodec.encode(self), to: encoder)
  }
}
