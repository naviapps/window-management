import CWindowManagement
import Foundation

extension DisplayTarget: Codable {
  /// Decode using platform-independent native identifier widths and shared normalization.
  public init(from decoder: Decoder) throws {
    try self.init(canonicalFields: WindowJSON.read(from: decoder, kind: 1))
  }

  init(canonicalFields v: [String: WindowWireValue]) throws {
    switch try v.field("kind", as: String.self) {
    case "main": self = .main
    case "containing-window": self = .containingWindow
    case "point":
      self = try .point(.init(x: v.field("x", as: CGFloat.self), y: v.field("y", as: CGFloat.self)))
    case "display-identifier": self = try .displayIdentifier(v.field("displayIdentifier"))
    case "ordered-index": self = try .orderedIndex(v.field("orderedIndex"))
    default: throw WindowRequestCodecError.invalidData("Unsupported canonical display target.")
    }
  }
  /// Encode a display target using the shared tagged shape.
  public func encode(to encoder: Encoder) throws {
    try WindowJSON.write(
      WindowJSON.data { window_management_display_target_json(nativeValue) }, to: encoder)
  }
}
