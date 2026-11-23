/// Selects whether display-aware operations use the full frame or visible frame.
public enum DisplayArea: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
  /// Use the full display frame, including system-reserved areas.
  case full
  /// Use the visible display frame, excluding system-reserved areas.
  case visible
}
