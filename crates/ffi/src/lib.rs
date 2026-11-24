//! C ABI; input slices borrow caller storage only for the duration of a call.
use window_management::{Display, DisplayQuery, Rect};

pub const WINDOW_MANAGEMENT_ABI_VERSION: u32 = 6u32;

fn sized_buffer<T>(pointer: *const T, count: usize) -> bool {
    !pointer.is_null()
        && pointer.is_aligned()
        && count <= isize::MAX as usize / std::mem::size_of::<T>()
        && pointer
            .addr()
            .checked_add(count * std::mem::size_of::<T>())
            .is_some()
}
unsafe fn display_slice<'a>(pointer: *const Display, count: usize) -> Option<&'a [Display]> {
    if count == 0 {
        Some(&[])
    } else if sized_buffer(pointer, count) {
        Some(unsafe { std::slice::from_raw_parts(pointer, count) })
    } else {
        None
    }
}
#[repr(C)]
pub struct RectResult {
    pub code: u32,
    pub frame: Rect,
}
#[unsafe(no_mangle)]
pub extern "C" fn window_management_abi_version() -> u32 {
    WINDOW_MANAGEMENT_ABI_VERSION
}
#[unsafe(no_mangle)]
pub extern "C" fn window_management_rect_normalize(rect: Rect) -> Rect {
    rect.normalized()
}
/// Normalize bounds and reject non-finite points. Minimum edges are included,
/// and maximum edges are excluded.
#[unsafe(no_mangle)]
pub extern "C" fn window_management_rect_contains(rect: Rect, x: f64, y: f64) -> u32 {
    u32::from(rect.contains(x, y))
}
/// Placement kinds: 0 fill, 1 grid, 2 centered. Result codes: 0 success, 1 invalid kind.
/// Grid counts, indices, spans and ratios are clamped. Row zero starts at minimum y.
#[unsafe(no_mangle)]
pub extern "C" fn window_management_placement(
    placement: values::PlacementValue,
    area: Rect,
    inset: f64,
) -> RectResult {
    match placement.read() {
        Some(value) => RectResult {
            code: 0,
            frame: value.frame(area, inset),
        },
        None => RectResult {
            code: 1,
            frame: Rect::default(),
        },
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn window_management_move(
    window: Rect,
    source: Rect,
    target: Rect,
    preserves_position: u32,
) -> Rect {
    if preserves_position == 0 {
        window_management::center_preserving_size(window, target)
    } else {
        window_management::preserving_relative_position(window, source, target)
    }
}
/// Return the number of indices written, or zero for empty input or invalid buffers/capacity.
/// Output capacity must cover count.
///
/// # Safety
/// Nonnull buffers must be aligned and readable/writable for their declared counts.
/// Buffers must not overlap.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn window_management_display_order(
    displays: *const Display,
    count: usize,
    output: *mut usize,
    capacity: usize,
) -> usize {
    if count == 0 {
        return 0;
    }
    if !sized_buffer(displays, count) || !sized_buffer(output, count) || capacity < count {
        return 0;
    }
    let indices =
        window_management::ordered_indices(unsafe { std::slice::from_raw_parts(displays, count) });
    unsafe { std::ptr::copy_nonoverlapping(indices.as_ptr(), output, count) };
    count
}
/// Return the original-array index or -1 for no match or invalid input.
/// Kinds: 0 main, 1 greatest positive window overlap, 2 point in the display coordinate
/// space, 3 identifier, 4 ordered index. Kind 1 uses normalized full frames. Equal areas
/// prefer center containment, then stable order. Zero-width or zero-height windows use
/// center containment alone. Nonzero fallback allows the first ordered display when a valid
/// kind has no match.
///
/// # Safety
/// Displays must be aligned and readable for count values. Null is allowed for zero count.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn window_management_display_select(
    displays: *const Display,
    count: usize,
    kind: u32,
    window: Rect,
    x: f64,
    y: f64,
    identifier: u64,
    index: i64,
    fallback: u32,
) -> i64 {
    let target = match kind {
        0 => DisplayQuery::Main,
        1 => DisplayQuery::ContainingWindow(window),
        2 => DisplayQuery::Point(x, y),
        3 => DisplayQuery::Identifier(identifier),
        4 => DisplayQuery::OrderedIndex(index),
        _ => return -1,
    };
    let Some(displays) = (unsafe { display_slice(displays, count) }) else {
        return -1;
    };
    window_management::select_display(displays, target, fallback != 0).map_or(-1, |i| i as i64)
}
/// Return the position in stable display order or -1 for no match or invalid input.
/// Use the same borrowed buffer and half-open point rules as display selection.
///
/// # Safety
/// Displays must be aligned and readable for count values. Null is allowed for zero count.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn window_management_display_index_containing_point(
    displays: *const Display,
    count: usize,
    x: f64,
    y: f64,
) -> i64 {
    let Some(displays) = (unsafe { display_slice(displays, count) }) else {
        return -1;
    };
    window_management::index_containing_point(displays, x, y).map_or(-1, |i| i as i64)
}
#[unsafe(no_mangle)]
pub extern "C" fn window_management_display_adjacent(index: i64, previous: u32, count: i64) -> i64 {
    window_management::adjacent_index(index, previous != 0, count).map_or(-1, |i| i as i64)
}

mod snapshots;
mod values;
mod windows;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn malformed_counts_and_alignment_fail_without_reading_foreign_storage() {
        unsafe {
            let invalid = values::PlacementValue {
                kind: 99,
                ..Default::default()
            };
            assert_eq!(
                window_management_placement(invalid, Rect::default(), 0.0).code,
                1
            );
            let display = Display {
                frame: Rect::default(),
                visible_frame: Rect::default(),
                identifier: 0,
                has_identifier: 0,
                is_main: 1,
            };
            let mut output = 0;
            assert_eq!(
                window_management_display_order(&display, usize::MAX, &mut output, usize::MAX),
                0
            );
            assert_eq!(
                window_management_display_select(
                    &display,
                    usize::MAX,
                    0,
                    Rect::default(),
                    0.0,
                    0.0,
                    0,
                    0,
                    1
                ),
                -1
            );
            assert_eq!(
                window_management_display_order(std::ptr::null(), 0, std::ptr::null_mut(), 0),
                0
            );
            assert_eq!(
                window_management_display_index_containing_point(&display, usize::MAX, 0.0, 0.0),
                -1
            );
        }
    }
}
