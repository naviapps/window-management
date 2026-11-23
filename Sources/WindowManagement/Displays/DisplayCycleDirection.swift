/// Direction for selecting an adjacent display from an ordered display list.
public enum DisplayCycleDirection: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
  /// Select the next ordered display.
  case next
  /// Select the previous ordered display.
  case previous
}
