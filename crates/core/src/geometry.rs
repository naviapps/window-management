use crate::exact_geometry::ExactRect;
use serde::{Deserialize, Serialize};
/// Rectangle in a caller-selected coordinate space. All operations use one consistent space.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Rect {
    /// Minimum x after normalization.
    pub x: f64,
    /// Minimum y after normalization.
    pub y: f64,
    /// Nonnegative width after normalization.
    pub width: f64,
    /// Nonnegative height after normalization.
    pub height: f64,
}
impl Rect {
    /// Normalize negative sizes and invalid scalars without producing infinite edges.
    pub fn normalized(self) -> Self {
        fn axis(origin: f64, size: f64) -> (f64, f64) {
            let mut origin = if origin.is_finite() { origin } else { 0.0 };
            let size = if size.is_finite() { size } else { 0.0 };
            if size < 0.0 {
                let shifted = origin + size;
                origin = if shifted.is_finite() {
                    shifted
                } else {
                    -f64::MAX
                };
            }
            let size = size.abs();
            let size = if (origin + size).is_finite() {
                size
            } else {
                (f64::MAX - origin).max(0.0)
            };
            (origin, size)
        }
        let (x, width) = axis(self.x, self.width);
        let (y, height) = axis(self.y, self.height);
        Self {
            x,
            y,
            width,
            height,
        }
    }
    /// Include minimum edges and exclude maximum edges, matching native viewport conventions.
    pub fn contains(self, x: f64, y: f64) -> bool {
        x.is_finite() && y.is_finite() && ExactRect::new(self).contains(x, y)
    }
}
/// Requested window placement. Grid row zero starts at the area's minimum y.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "kebab-case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum Placement {
    /// Fill the supplied area.
    Fill {},
    /// Clamp grid counts, indices and spans to a valid cell region.
    /// A full span keeps the entire normalized, inset extent on that axis.
    Grid {
        columns: i64,
        rows: i64,
        column: i64,
        row: i64,
        column_span: i64,
        row_span: i64,
    },
    /// Center a rectangle using ratios clamped to 0...1.
    Centered { width_ratio: f64, height_ratio: f64 },
}
pub(crate) fn clamp(value: f64, maximum: f64) -> f64 {
    if value.is_nan() {
        0.0
    } else {
        value.max(0.0).min(maximum)
    }
}
fn grid_proportion(extent: f64, part: i64, count: i64) -> f64 {
    if part == count {
        return extent;
    }
    let (part, count) = (part as f64, count as f64);
    let scaled = extent * part;
    // Multiply before division to preserve subnormal extents and exact half pixels.
    if scaled.is_finite() {
        scaled / count
    } else {
        extent * (part / count)
    }
}
impl Placement {
    /// Canonical executable values, also used by storage and language adapters.
    pub fn normalized(self) -> Self {
        match self {
            Self::Fill {} => Self::Fill {},
            Self::Centered {
                width_ratio,
                height_ratio,
            } => Self::Centered {
                width_ratio: clamp(width_ratio, 1.0),
                height_ratio: clamp(height_ratio, 1.0),
            },
            Self::Grid {
                columns,
                rows,
                column,
                row,
                column_span,
                row_span,
            } => {
                let columns = columns.max(1);
                let rows = rows.max(1);
                let column = column.clamp(0, columns - 1);
                let row = row.clamp(0, rows - 1);
                Self::Grid {
                    columns,
                    rows,
                    column,
                    row,
                    column_span: column_span.clamp(1, columns - column),
                    row_span: row_span.clamp(1, rows - row),
                }
            }
        }
    }
    /// Resolve finite geometry after normalizing bounds and clamping the uniform inset.
    pub fn frame(self, bounds: Rect, inset: f64) -> Rect {
        let mut a = bounds.normalized();
        // Clamp the combined inset before halving so a subnormal dimension can collapse exactly.
        let reduction = clamp(2.0 * inset, a.width.min(a.height));
        a.x = reduction.mul_add(0.5, a.x);
        a.y = reduction.mul_add(0.5, a.y);
        a.width -= reduction;
        a.height -= reduction;
        match self.normalized() {
            Self::Fill {} => a,
            Self::Centered {
                width_ratio,
                height_ratio,
            } => {
                let width = a.width * width_ratio;
                let height = a.height * height_ratio;
                Rect {
                    x: a.x + (a.width - width) / 2.0,
                    y: a.y + (a.height - height) / 2.0,
                    width,
                    height,
                }
            }
            Self::Grid {
                columns,
                rows,
                column,
                row,
                column_span,
                row_span,
            } => Rect {
                x: a.x + grid_proportion(a.width, column, columns),
                y: a.y + grid_proportion(a.height, row, rows),
                width: grid_proportion(a.width, column_span, columns),
                height: grid_proportion(a.height, row_span, rows),
            },
        }
        .normalized()
    }
}
/// Center the window, shrinking only dimensions exceeding the target area.
pub fn center_preserving_size(window: Rect, target: Rect) -> Rect {
    let window = window.normalized();
    let target = target.normalized();
    let width = window.width.min(target.width);
    let height = window.height.min(target.height);
    Rect {
        x: target.x + (target.width - width) / 2.0,
        y: target.y + (target.height - height) / 2.0,
        width,
        height,
    }
    .normalized()
}
/// Preserve normalized position between usable areas, clamping oversize windows to the target.
pub fn preserving_relative_position(window: Rect, source: Rect, target: Rect) -> Rect {
    let window = window.normalized();
    let source = source.normalized();
    let target = target.normalized();
    let progress = |offset, available| {
        if available > 0.0 {
            clamp(offset / available, 1.0)
        } else {
            0.5
        }
    };
    let x = progress(window.x - source.x, source.width - window.width);
    let y = progress(window.y - source.y, source.height - window.height);
    let width = window.width.min(target.width);
    let height = window.height.min(target.height);
    Rect {
        x: target.x + x * (target.width - width),
        y: target.y + y * (target.height - height),
        width,
        height,
    }
    .normalized()
}
