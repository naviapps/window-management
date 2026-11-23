import CWindowManagement
import CoreGraphics

/// Stable Rust-owned display ordering and explicit target/fallback resolution.
public enum DisplaySelector {
  /// Orders by minimum x, minimum y, dimensions and optional display identifier, retaining ties.
  public static func orderedDisplays(from displays: [Display]) -> [Display] {
    let native = displays.map(\.nativeDisplay)
    var indices = [Int](repeating: 0, count: displays.count)
    let count = native.withUnsafeBufferPointer { data in
      indices.withUnsafeMutableBufferPointer {
        window_management_display_order(data.baseAddress, data.count, $0.baseAddress, $0.count)
      }
    }
    precondition(count == displays.count, "Invalid native display order")
    return indices.map { displays[$0] }
  }
  /// Returns a selected display, defaulting to the first ordered display when no target matches.
  /// Pass `DisplayFallback.none` to reject an unmatched target.
  /// Containing-window selection uses greatest positive overlap with full display bounds;
  /// equal areas prefer center containment, then stable order. Zero-sized windows use the center.
  public static func display(
    for target: DisplayTarget, windowFrame: CGRect, in displays: [Display],
    fallback: DisplayFallback = .firstDisplay
  ) -> Display? {
    let kind: UInt32
    var x = 0.0
    var y = 0.0
    var identifier: UInt64 = 0
    var index: Int64 = 0
    switch target {
    case .main: kind = 0
    case .containingWindow: kind = 1
    case .point(let point):
      kind = 2
      x = point.x
      y = point.y
    case .displayIdentifier(let value):
      kind = 3
      identifier = UInt64(value)
    case .orderedIndex(let value):
      kind = 4
      index = Int64(value)
    }
    let fallbackCode: UInt32 =
      switch fallback {
      case .firstDisplay: 1
      case .none: 0
      }
    let selected = displays.map(\.nativeDisplay).withUnsafeBufferPointer {
      window_management_display_select(
        $0.baseAddress, $0.count, kind, windowFrame.nativeRect, x, y, identifier, index,
        fallbackCode)
    }
    return selected < 0 ? nil : displays[Int(selected)]
  }
  /// Returns an ordered display index containing a point; maximum edges are excluded.
  public static func index(containing point: CGPoint, in displays: [Display]) -> Int? {
    let selected = displays.map(\.nativeDisplay).withUnsafeBufferPointer {
      window_management_display_index_containing_point($0.baseAddress, $0.count, point.x, point.y)
    }
    return selected < 0 ? nil : Int(selected)
  }
  /// Wraps a signed starting index in either direction; empty/negative counts return `nil`.
  public static func adjacentIndex(
    from index: Int, direction: DisplayCycleDirection, displayCount: Int
  ) -> Int? {
    let previous: UInt32 =
      switch direction {
      case .next: 0
      case .previous: 1
      }
    let result = window_management_display_adjacent(Int64(index), previous, Int64(displayCount))
    return result < 0 ? nil : Int(result)
  }
}
