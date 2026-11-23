import CWindowManagement
import CoreGraphics

/// Reusable placement description for calculating a target window frame.
public enum WindowPlacement: Equatable, Hashable, Sendable {
  /// Fill the selected display area.
  case fill
  /// Rectangular region in a grid.
  ///
  /// Columns and rows advance from the area's minimum x and y coordinates. Row zero is at the
  /// bottom for AppKit coordinates and at the top for Accessibility coordinates.
  /// ``WindowPlacementCalculator`` clamps invalid
  /// column/row counts, indexes, and spans.
  case grid(columns: Int, rows: Int, column: Int, row: Int, columnSpan: Int, rowSpan: Int)
  /// Centered frame sized as a ratio of the selected display area.
  ///
  /// ``WindowPlacementCalculator`` clamps ratios to the `0...1` range.
  case centered(widthRatio: CGFloat, heightRatio: CGFloat)
}

extension WindowPlacement {
  /// Canonical executable grid values and ratios, normalized by Rust.
  public var normalized: Self {
    let result = window_management_placement_normalize(nativeValue)
    precondition(result.code == 0, "Unsupported native placement")
    return Self(nativeValue: result.value)
  }
  var nativeValue: WindowManagementPlacement {
    var value = WindowManagementPlacement()
    switch self {
    case .fill: break
    case .grid(let columns, let rows, let column, let row, let columnSpan, let rowSpan):
      value.kind = 1
      value.columns = Int64(columns)
      value.rows = Int64(rows)
      value.column = Int64(column)
      value.row = Int64(row)
      value.column_span = Int64(columnSpan)
      value.row_span = Int64(rowSpan)
    case .centered(let width, let height):
      value.kind = 2
      value.width_ratio = width
      value.height_ratio = height
    }
    return value
  }
  init(nativeValue v: WindowManagementPlacement) {
    switch v.kind {
    case 0: self = .fill
    case 1:
      self = .grid(
        columns: Int(v.columns), rows: Int(v.rows), column: Int(v.column), row: Int(v.row),
        columnSpan: Int(v.column_span), rowSpan: Int(v.row_span))
    case 2: self = .centered(widthRatio: v.width_ratio, heightRatio: v.height_ratio)
    default: preconditionFailure("Unsupported native placement")
    }
  }
}
