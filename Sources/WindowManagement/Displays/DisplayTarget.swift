import CWindowManagement
import CoreGraphics

/// Selects a display from a display list.
public enum DisplayTarget: Equatable, Hashable, Sendable {
  /// The system's primary display.
  case main
  /// The display with the greatest positive overlap with the target window.
  /// Equal areas prefer center containment, then stable display order.
  /// Zero-sized windows use center containment alone.
  case containingWindow
  /// The display containing a point.
  case point(CGPoint)
  /// The display matching a platform-native display identifier.
  case displayIdentifier(UInt64)
  /// A display by `DisplaySelector`'s deterministic ordered index.
  case orderedIndex(Int)
}
extension DisplayTarget {
  /// Canonical point and ordered index values, normalized by Rust.
  public var normalized: Self {
    let result = window_management_display_target_normalize(nativeValue)
    precondition(result.code == 0, "Unsupported native display target")
    let v = result.value
    switch v.kind {
    case 0: return .main
    case 1: return .containingWindow
    case 2: return .point(.init(x: v.x, y: v.y))
    case 3: return .displayIdentifier(v.identifier)
    case 4: return .orderedIndex(Int(v.index))
    default: preconditionFailure("Unsupported native display target")
    }
  }
  var nativeValue: WindowManagementDisplayTarget {
    var v = WindowManagementDisplayTarget()
    switch self {
    case .main: break
    case .containingWindow: v.kind = 1
    case .point(let point):
      v.kind = 2
      v.x = point.x
      v.y = point.y
    case .displayIdentifier(let id):
      v.kind = 3
      v.identifier = id
    case .orderedIndex(let index):
      v.kind = 4
      v.index = Int64(index)
    }
    return v
  }
}
