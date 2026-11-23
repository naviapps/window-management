/// Provides app-facing display values.
public protocol DisplayProviding: Sendable {
  /// Returns the current displays.
  @MainActor
  func displays() -> [Display]
}
