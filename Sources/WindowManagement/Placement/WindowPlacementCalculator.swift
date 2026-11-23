import CWindowManagement
import CoreGraphics

/// Resolves placements through the shared Rust geometry engine.
public enum WindowPlacementCalculator {
  /// Normalizes finite bounds and clamps the inset, grid and ratios without inverting the frame.
  public static func frame(
    for placement: WindowPlacement, in displayArea: CGRect, inset: CGFloat = 0
  ) -> CGRect {
    precondition(
      window_management_abi_version() == WINDOW_MANAGEMENT_ABI_VERSION,
      "Unsupported native window ABI")
    let result = window_management_placement(placement.nativeValue, displayArea.nativeRect, inset)
    precondition(result.code == 0, "Invalid native placement")
    return result.frame.cgRect
  }
}
