import CWindowManagement
import CoreGraphics

/// A reusable normalized window placement request, independent of focus or product policy.
public struct WindowPlacementRequest: Equatable, Hashable, Sendable {
  /// Target geometry.
  public let placement: WindowPlacement
  /// Platform-native display selection rule.
  public let display: DisplayTarget
  /// Full or usable display area.
  public let area: DisplayArea
  /// Finite nonnegative inset.
  public let inset: CGFloat
  /// Creates a request using shared Rust normalization.
  public init(
    placement: WindowPlacement, display: DisplayTarget = .containingWindow,
    area: DisplayArea = .visible, inset: CGFloat = 0
  ) {
    self.init(
      normalizedPlacement: placement.normalized, display: display.normalized, area: area,
      inset: window_management_inset_normalize(inset))
  }

  init(
    normalizedPlacement: WindowPlacement, display: DisplayTarget, area: DisplayArea, inset: CGFloat
  ) {
    placement = normalizedPlacement
    self.display = display
    self.area = area
    self.inset = inset
  }

  var nativeValue: WindowManagementPlacementRequest {
    .init(
      placement: placement.nativeValue, display: display.nativeValue,
      area: area == .full ? 1 : 0, inset: inset)
  }
}
