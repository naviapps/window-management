import CWindowManagement
import CoreGraphics

extension CGRect {
  package var finiteStandardized: CGRect { window_management_rect_normalize(nativeRect).cgRect }
}
