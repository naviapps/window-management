import CWindowManagement
import Foundation

extension WindowPlacement: Codable {
  /// Decode through the shared Rust placement schema.
  public init(from decoder: Decoder) throws {
    try self.init(canonicalFields: WindowJSON.read(from: decoder, kind: 0))
  }

  init(canonicalFields v: [String: WindowWireValue]) throws {
    switch try v.field("kind", as: String.self) {
    case "fill": self = .fill
    case "grid":
      self = try .grid(
        columns: v.field("columns"), rows: v.field("rows"), column: v.field("column"),
        row: v.field("row"), columnSpan: v.field("columnSpan"), rowSpan: v.field("rowSpan"))
    case "centered":
      self = try .centered(widthRatio: v.field("widthRatio"), heightRatio: v.field("heightRatio"))
    default: throw WindowRequestCodecError.invalidData("Unsupported canonical placement kind.")
    }
  }
  /// Encode canonical Rust-normalized values using the shared tagged shape.
  public func encode(to encoder: Encoder) throws {
    try WindowJSON.write(
      WindowJSON.data { window_management_placement_json(nativeValue) }, to: encoder)
  }
}
