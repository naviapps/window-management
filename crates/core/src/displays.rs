use crate::{Rect, exact_geometry::ExactRect};
/// Immutable display metadata. The identifier belongs to its native platform.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct Display {
    /// Full display area.
    pub frame: Rect,
    /// Usable area excluding native system surfaces.
    pub visible_frame: Rect,
    /// Native display identifier when present.
    pub identifier: u64,
    /// Whether identifier is present (zero is a valid native identifier).
    pub has_identifier: u32,
    /// Whether this is the primary display.
    pub is_main: u32,
}
/// Native-independent display selection request.
#[derive(Debug, Clone, Copy)]
pub enum DisplayQuery {
    Main,
    /// Greatest positive overlap with the window. Equal areas prefer center containment,
    /// then stable display order. Zero-sized windows use center containment alone.
    ContainingWindow(Rect),
    Point(f64, f64),
    Identifier(u64),
    OrderedIndex(i64),
}

fn containing_window(displays: &[Display], indices: &[usize], window: Rect) -> Option<usize> {
    let window = ExactRect::new(window);
    if window.is_empty() {
        return indices
            .iter()
            .position(|&i| ExactRect::new(displays[i].frame).contains_center(&window));
    }
    let mut selected = None;
    let mut best = None;
    for (position, &i) in indices.iter().enumerate() {
        let frame = ExactRect::new(displays[i].frame);
        if let Some(area) = window.overlap_area(&frame) {
            let score = (area, frame.contains_center(&window));
            if best.as_ref().is_none_or(|best| &score > best) {
                best = Some(score);
                selected = Some(position);
            }
        }
    }
    selected
}
/// Stable left-to-right, then increasing-y order, followed by size and identifier.
/// Signed zeros compare as equal coordinates.
pub fn ordered_indices(displays: &[Display]) -> Vec<usize> {
    let mut indices: Vec<_> = (0..displays.len()).collect();
    indices.sort_by(|&a, &b| {
        let a = displays[a];
        let b = displays[b];
        let x = a.frame.normalized();
        let y = b.frame.normalized();
        (x.x, x.y, x.width, x.height)
            .partial_cmp(&(y.x, y.y, y.width, y.height))
            .expect("normalized display frames are finite")
            .then((b.has_identifier != 0).cmp(&(a.has_identifier != 0)))
            .then_with(|| {
                if a.has_identifier != 0 && b.has_identifier != 0 {
                    a.identifier.cmp(&b.identifier)
                } else {
                    std::cmp::Ordering::Equal
                }
            })
    });
    indices
}
pub(crate) fn select_ordered_index(
    displays: &[Display],
    indices: &[usize],
    target: DisplayQuery,
) -> Option<usize> {
    match target {
        DisplayQuery::Main => indices.iter().position(|&i| displays[i].is_main != 0),
        DisplayQuery::ContainingWindow(rect) => containing_window(displays, indices, rect),
        DisplayQuery::Point(x, y) => indices
            .iter()
            .position(|&i| displays[i].frame.contains(x, y)),
        DisplayQuery::Identifier(id) => indices
            .iter()
            .position(|&i| displays[i].has_identifier != 0 && displays[i].identifier == id),
        DisplayQuery::OrderedIndex(index) => {
            usize::try_from(index).ok().filter(|&i| i < indices.len())
        }
    }
}
/// Return an index into the original slice. Fallback selects the first ordered display only when requested.
pub fn select_display(displays: &[Display], target: DisplayQuery, fallback: bool) -> Option<usize> {
    let indices = ordered_indices(displays);
    let position =
        select_ordered_index(displays, &indices, target).or_else(|| fallback.then_some(0))?;
    indices.get(position).copied()
}
/// Return the index in stable display order containing a point, without fallback.
pub fn index_containing_point(displays: &[Display], x: f64, y: f64) -> Option<usize> {
    let indices = ordered_indices(displays);
    select_ordered_index(displays, &indices, DisplayQuery::Point(x, y))
}
/// Wrap a signed starting index in either direction, with no result for an empty display list.
pub fn adjacent_index(index: i64, previous: bool, count: i64) -> Option<usize> {
    if count <= 0 {
        return None;
    }
    let index = index.rem_euclid(count);
    Some(if previous {
        if index == 0 { count - 1 } else { index - 1 }
    } else if index == count - 1 {
        0
    } else {
        index + 1
    } as usize)
}
