import CWindowManagement
import Foundation

extension WindowPlacement: Codable {
  /// Decode through the shared Rust placement schema.
  public init(from decoder: Decoder) throws {
    self = try WindowJSON.project(from: decoder) {
      try JSONDecoder().decode(Canonical.self, from: WindowJSON.normalize($0, kind: 0)).value
    }
  }

  struct Canonical: Decodable {
    private enum Field: String, CodingKey {
      case kind, columns, rows, column, row, columnSpan, rowSpan, widthRatio, heightRatio
    }

    let value: WindowPlacement

    init(from decoder: any Decoder) throws {
      let v = try decoder.container(keyedBy: Field.self)
      switch try v.decode(String.self, forKey: .kind) {
      case "fill": value = .fill
      case "grid":
        value = try .grid(
          columns: v.decode(Int.self, forKey: .columns), rows: v.decode(Int.self, forKey: .rows),
          column: v.decode(Int.self, forKey: .column), row: v.decode(Int.self, forKey: .row),
          columnSpan: v.decode(Int.self, forKey: .columnSpan),
          rowSpan: v.decode(Int.self, forKey: .rowSpan))
      case "centered":
        value = try .centered(
          widthRatio: v.decode(CGFloat.self, forKey: .widthRatio),
          heightRatio: v.decode(CGFloat.self, forKey: .heightRatio))
      default: throw WindowRequestCodecError.invalidData("Unsupported canonical placement kind.")
      }
    }
  }
  /// Encode canonical Rust-normalized values using the shared tagged shape.
  public func encode(to encoder: Encoder) throws {
    try WindowJSON.write(
      WindowJSON.data { window_management_placement_json(nativeValue) }, to: encoder)
  }
}
