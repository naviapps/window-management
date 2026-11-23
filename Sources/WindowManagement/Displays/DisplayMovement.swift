import CWindowManagement
import CoreGraphics

/// Shared Rust geometry for moving windows between usable display areas.
public enum DisplayMovement {
  /// Centers a window, shrinking only dimensions exceeding the finite target area.
  public static func centerPreservingSize(windowFrame: CGRect, in visibleFrame: CGRect) -> CGRect {
    window_management_move(windowFrame.nativeRect, .init(), visibleFrame.nativeRect, 0).cgRect
  }
  /// Retains normalized relative position, clamping size and position to the target area.
  public static func preservingRelativePosition(
    windowFrame: CGRect, from sourceVisibleFrame: CGRect, to targetVisibleFrame: CGRect
  ) -> CGRect {
    window_management_move(
      windowFrame.nativeRect, sourceVisibleFrame.nativeRect, targetVisibleFrame.nativeRect, 1
    )
    .cgRect
  }
}
