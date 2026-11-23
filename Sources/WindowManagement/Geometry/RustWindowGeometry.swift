import CWindowManagement
import CoreGraphics

extension CGRect {
  package func containsWindowPoint(_ point: CGPoint) -> Bool {
    window_management_rect_contains(nativeRect, point.x, point.y) == 1
  }
  var nativeRect: WindowManagementRect {
    WindowManagementRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
  }
}
extension WindowManagementRect {
  var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
extension Display {
  var nativeDisplay: WindowManagementDisplay {
    .init(
      frame: frame.nativeRect, visible_frame: visibleFrame.nativeRect,
      identifier: UInt64(displayIdentifier ?? 0), has_identifier: displayIdentifier == nil ? 0 : 1,
      is_main: isMain ? 1 : 0)
  }
}
