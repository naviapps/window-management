/// Display-selection behavior when a requested display cannot be resolved.
public enum DisplayFallback: Equatable, Hashable, Sendable, Codable {
  /// Use the first deterministically ordered display when one exists.
  case firstDisplay
  /// Do not fall back; return nil or throw from higher-level operations.
  case none
}
