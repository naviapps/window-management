import CWindowManagement
import Foundation

/// A rejection from the shared window request codec.
public enum WindowRequestCodecError: LocalizedError, Equatable, Hashable, Sendable {
  /// Malformed JSON, an unknown field or an incompatible value.
  case invalidData(String)
  /// English diagnostic; hosts own localized presentation.
  public var errorDescription: String? {
    switch self {
    case .invalidData(let value): value
    }
  }
}

/// Strict JSON entry points. Original bytes reach Rust before Foundation can consume duplicate keys.
public enum WindowRequestCodec {
  /// Decode a placement request with canonical display, area and inset defaults.
  public static func decodePlacement(_ data: Data) throws -> WindowPlacementRequest {
    try WindowPlacementRequest(
      canonicalFields: WindowJSON.fields(WindowJSON.normalize(data, kind: 2)))
  }
  /// Decode an adjacent-display movement request.
  public static func decodeMovement(_ data: Data) throws -> WindowMoveRequest {
    try WindowMoveRequest(canonicalFields: WindowJSON.fields(WindowJSON.normalize(data, kind: 3)))
  }
  /// Encode a normalized placement request.
  public static func encode(_ request: WindowPlacementRequest) throws -> Data {
    try WindowJSON.data { window_management_placement_request_json(request.nativeValue) }
  }
  /// Encode an adjacent-display movement request.
  public static func encode(_ request: WindowMoveRequest) throws -> Data {
    try WindowJSON.data { window_management_move_request_json(request.nativeValue) }
  }
}

enum WindowJSON {
  static func normalize(_ data: Data, kind: UInt32) throws -> Data {
    try self.data {
      data.withUnsafeBytes {
        window_management_value_json(kind, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
      }
    }
  }
  static func data(_ create: () -> OpaquePointer?) throws -> Data {
    precondition(
      window_management_abi_version() == WINDOW_MANAGEMENT_ABI_VERSION,
      "Unsupported native window ABI")
    guard let owner = create() else {
      throw WindowRequestCodecError.invalidData("Native JSON owner is unavailable.")
    }
    defer { window_management_json_destroy(owner) }
    let view = window_management_json_view(owner)
    guard let pointer = view.data else {
      throw WindowRequestCodecError.invalidData("Native JSON bytes are unavailable.")
    }
    let result = Data(bytes: pointer, count: view.length)
    guard view.code == 0 else {
      throw WindowRequestCodecError.invalidData(String(decoding: result, as: UTF8.self))
    }
    return result
  }
  static func read(from decoder: Decoder, kind: UInt32) throws -> [String: WindowWireValue] {
    let raw = try WindowWireValue(from: decoder)
    do {
      return try fields(normalize(JSONEncoder().encode(raw), kind: kind))
    } catch let error as WindowRequestCodecError {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath, debugDescription: error.localizedDescription,
          underlyingError: error))
    }
  }
  static func fields(_ canonical: Data) throws -> [String: WindowWireValue] {
    try JSONDecoder().decode(WindowWireValue.self, from: canonical).objectFields()
  }
  static func write(_ canonical: Data, to encoder: Encoder) throws {
    try JSONDecoder().decode(WindowWireValue.self, from: canonical).encode(to: encoder)
  }
}

/// A private Codable projection, without window policy or validation rules.
indirect enum WindowWireValue: Codable {
  case object([String: Self])
  case array([Self])
  case string(String)
  case integer(Int64)
  case unsigned(UInt64)
  case number(Double)
  case bool(Bool)
  case null
  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let v = try? c.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? c.decode(Int64.self) {
      if v == 0, let floating = try? c.decode(Double.self), floating == 0, floating.sign == .minus {
        self = .number(floating)
      } else {
        self = .integer(v)
      }
    } else if let v = try? c.decode(UInt64.self) {
      self = .unsigned(v)
    } else if let v = try? c.decode(Double.self) {
      self = .number(v)
    } else if let v = try? c.decode(String.self) {
      self = .string(v)
    } else if let v = try? c.decode([String: Self].self) {
      self = .object(v)
    } else {
      self = try .array(c.decode([Self].self))
    }
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .object(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    case .integer(let v): try c.encode(v)
    case .unsigned(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .bool(let v): try c.encode(v)
    case .null: try c.encodeNil()
    }
  }
  func objectFields() throws -> [String: Self] {
    guard case .object(let fields) = self else {
      throw WindowRequestCodecError.invalidData("Expected a window object.")
    }
    return fields
  }
}
extension Dictionary where Key == String, Value == WindowWireValue {
  func objectField(_ name: String) throws -> [String: WindowWireValue] {
    guard let value = self[name] else {
      throw WindowRequestCodecError.invalidData("Missing canonical field: \(name)")
    }
    return try value.objectFields()
  }
  func field<T: Decodable>(_ name: String, as _: T.Type = T.self) throws -> T {
    guard let value = self[name] else {
      throw WindowRequestCodecError.invalidData("Missing canonical field: \(name)")
    }
    return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
  }
}
