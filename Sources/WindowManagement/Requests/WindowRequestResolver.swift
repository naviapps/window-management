import CWindowManagement
import CoreGraphics

/// Rust-owned display resolution and frame planning. These functions have no native side effects.
public enum WindowRequestResolver {
  /// Resolve a complete placement, or return nil when no display matches the explicit fallback policy.
  public static func placement(
    _ request: WindowPlacementRequest, windowFrame: CGRect, in displays: [Display],
    fallback: DisplayFallback = .none
  ) -> CGRect? {
    let result = displays.map(\.nativeDisplay).withUnsafeBufferPointer {
      window_management_placement_resolve(
        request.nativeValue, windowFrame.nativeRect, $0.baseAddress, $0.count,
        fallback == .firstDisplay ? 1 : 0)
    }
    precondition(result.code != 1, "Invalid native placement request")
    return result.code == 0 ? result.frame.cgRect : nil
  }
  /// Resolve adjacent-display movement, including wrapping and relative position in usable areas.
  /// A window already on the only display keeps its normalized frame.
  public static func movement(
    _ request: WindowMoveRequest, windowFrame: CGRect, in displays: [Display],
    fallback: DisplayFallback = .none
  ) -> CGRect? {
    movementPlan(request, windowFrame: windowFrame, in: displays, fallback: fallback)?.frame
  }

  package static func movementPlan(
    _ request: WindowMoveRequest, windowFrame: CGRect, in displays: [Display],
    fallback: DisplayFallback
  ) -> (frame: CGRect, requiresFrameWrite: Bool)? {
    let result = displays.map(\.nativeDisplay).withUnsafeBufferPointer {
      window_management_movement_plan(
        request.nativeValue, windowFrame.nativeRect, $0.baseAddress, $0.count,
        fallback == .firstDisplay ? 1 : 0)
    }
    precondition(result.code != 1, "Invalid native movement request")
    return result.code == 0 ? (result.frame.cgRect, result.requires_frame_write != 0) : nil
  }
}
