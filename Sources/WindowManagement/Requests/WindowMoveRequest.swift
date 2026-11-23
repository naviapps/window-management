import CWindowManagement

/// A reusable adjacent-display movement request, independent of focus or product policy.
public struct WindowMoveRequest: Equatable, Hashable, Sendable {
  /// Movement direction in deterministic display order.
  public let direction: DisplayCycleDirection
  /// Preserve normalized position, or center while preserving size.
  public let preservesRelativePosition: Bool
  /// Creates an adjacent-display movement request.
  public init(direction: DisplayCycleDirection, preservesRelativePosition: Bool = true) {
    self.direction = direction
    self.preservesRelativePosition = preservesRelativePosition
  }

  var nativeValue: WindowManagementMoveRequest {
    .init(
      direction: direction == .next ? 0 : 1,
      preserves_relative_position: preservesRelativePosition ? 1 : 0)
  }
}
