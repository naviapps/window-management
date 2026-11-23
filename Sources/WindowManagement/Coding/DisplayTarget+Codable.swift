import CWindowManagement
import Foundation

extension DisplayTarget: Codable {
  /// Decode using platform-independent native identifier widths and shared normalization.
  public init(from decoder: Decoder) throws {
    self = try WindowJSON.project(from: decoder) {
      try JSONDecoder().decode(Canonical.self, from: WindowJSON.normalize($0, kind: 1)).value
    }
  }

  struct Canonical: Decodable {
    private enum Field: String, CodingKey {
      case kind, x, y, displayIdentifier, orderedIndex
    }

    let value: DisplayTarget

    init(from decoder: any Decoder) throws {
      let v = try decoder.container(keyedBy: Field.self)
      switch try v.decode(String.self, forKey: .kind) {
      case "main": value = .main
      case "containing-window": value = .containingWindow
      case "point":
        value = try .point(
          .init(x: v.decode(CGFloat.self, forKey: .x), y: v.decode(CGFloat.self, forKey: .y)))
      case "display-identifier":
        value = try .displayIdentifier(v.decode(UInt64.self, forKey: .displayIdentifier))
      case "ordered-index": value = try .orderedIndex(v.decode(Int.self, forKey: .orderedIndex))
      default: throw WindowRequestCodecError.invalidData("Unsupported canonical display target.")
      }
    }
  }
  /// Encode a display target using the shared tagged shape.
  public func encode(to encoder: Encoder) throws {
    try WindowJSON.write(
      WindowJSON.data { window_management_display_target_json(nativeValue) }, to: encoder)
  }
}
