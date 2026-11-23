//! Language projections. Normalization and request shapes remain in the shared core.
use window_management::{
    CycleDirection, Display, DisplayArea, DisplayTarget, MoveRequest, Placement, PlacementRequest,
    Rect,
};

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct PlacementValue {
    pub kind: u32,
    pub columns: i64,
    pub rows: i64,
    pub column: i64,
    pub row: i64,
    pub column_span: i64,
    pub row_span: i64,
    pub width_ratio: f64,
    pub height_ratio: f64,
}
impl PlacementValue {
    pub(super) fn read(self) -> Option<Placement> {
        Some(match self.kind {
            0 => Placement::Fill {},
            1 => Placement::Grid {
                columns: self.columns,
                rows: self.rows,
                column: self.column,
                row: self.row,
                column_span: self.column_span,
                row_span: self.row_span,
            },
            2 => Placement::Centered {
                width_ratio: self.width_ratio,
                height_ratio: self.height_ratio,
            },
            _ => return None,
        })
    }
    fn from(value: Placement) -> Self {
        match value {
            Placement::Fill {} => Self::default(),
            Placement::Grid {
                columns,
                rows,
                column,
                row,
                column_span,
                row_span,
            } => Self {
                kind: 1,
                columns,
                rows,
                column,
                row,
                column_span,
                row_span,
                ..Self::default()
            },
            Placement::Centered {
                width_ratio,
                height_ratio,
            } => Self {
                kind: 2,
                width_ratio,
                height_ratio,
                ..Self::default()
            },
        }
    }
}
#[repr(C)]
pub struct PlacementResult {
    pub code: u32,
    pub value: PlacementValue,
}
#[unsafe(no_mangle)]
pub extern "C" fn window_management_placement_normalize(value: PlacementValue) -> PlacementResult {
    match value.read() {
        Some(v) => PlacementResult {
            code: 0,
            value: PlacementValue::from(v.normalized()),
        },
        None => PlacementResult {
            code: 1,
            value: PlacementValue::default(),
        },
    }
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct SelectionValue {
    pub kind: u32,
    pub x: f64,
    pub y: f64,
    pub identifier: u64,
    pub index: i64,
}
impl SelectionValue {
    pub(super) fn read(self) -> Option<DisplayTarget> {
        Some(match self.kind {
            0 => DisplayTarget::Main {},
            1 => DisplayTarget::ContainingWindow {},
            2 => DisplayTarget::Point {
                x: self.x,
                y: self.y,
            },
            3 => DisplayTarget::DisplayIdentifier {
                display_identifier: self.identifier,
            },
            4 => DisplayTarget::OrderedIndex {
                ordered_index: self.index,
            },
            _ => return None,
        })
    }
    fn from(value: DisplayTarget) -> Self {
        match value {
            DisplayTarget::Main {} => Self::default(),
            DisplayTarget::ContainingWindow {} => Self {
                kind: 1,
                ..Self::default()
            },
            DisplayTarget::Point { x, y } => Self {
                kind: 2,
                x,
                y,
                ..Self::default()
            },
            DisplayTarget::DisplayIdentifier { display_identifier } => Self {
                kind: 3,
                identifier: display_identifier,
                ..Self::default()
            },
            DisplayTarget::OrderedIndex { ordered_index } => Self {
                kind: 4,
                index: ordered_index,
                ..Self::default()
            },
        }
    }
}
#[repr(C)]
pub struct SelectionResult {
    pub code: u32,
    pub value: SelectionValue,
}
#[unsafe(no_mangle)]
pub extern "C" fn window_management_display_target_normalize(
    value: SelectionValue,
) -> SelectionResult {
    match value.read() {
        Some(v) => SelectionResult {
            code: 0,
            value: SelectionValue::from(v.normalized()),
        },
        None => SelectionResult {
            code: 1,
            value: SelectionValue::default(),
        },
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn window_management_inset_normalize(value: f64) -> f64 {
    window_management::normalized_inset(value)
}

#[repr(C)]
pub struct PlacementRequestValue {
    pub placement: PlacementValue,
    pub display: SelectionValue,
    pub area: u32,
    pub inset: f64,
}
impl PlacementRequestValue {
    fn read(self) -> Option<PlacementRequest> {
        Some(PlacementRequest {
            placement: self.placement.read()?,
            display: self.display.read()?,
            area: match self.area {
                0 => DisplayArea::Visible,
                1 => DisplayArea::Full,
                _ => return None,
            },
            inset: self.inset,
        })
    }
}
#[repr(C)]
pub struct MoveRequestValue {
    pub direction: u32,
    pub preserves_relative_position: u32,
}
impl MoveRequestValue {
    fn read(self) -> Option<MoveRequest> {
        Some(MoveRequest {
            direction: match self.direction {
                0 => CycleDirection::Next,
                1 => CycleDirection::Previous,
                _ => return None,
            },
            preserves_relative_position: self.preserves_relative_position != 0,
        })
    }
}
/// # Safety
/// Nonempty displays must be readable/aligned for count values. No storage is retained.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn window_management_placement_resolve(
    request: PlacementRequestValue,
    window: Rect,
    display_data: *const Display,
    count: usize,
    fallback: u32,
) -> super::RectResult {
    let Some((r, s)) = request
        .read()
        .zip(unsafe { super::display_slice(display_data, count) })
    else {
        return super::RectResult {
            code: 1,
            frame: Rect::default(),
        };
    };
    window_management::placement_frame(r, window, s, fallback != 0).map_or(
        super::RectResult {
            code: 2,
            frame: Rect::default(),
        },
        |frame| super::RectResult { code: 0, frame },
    )
}
/// # Safety
/// Nonempty displays must be readable/aligned for count values. No storage is retained.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn window_management_movement_resolve(
    request: MoveRequestValue,
    window: Rect,
    display_data: *const Display,
    count: usize,
    fallback: u32,
) -> super::RectResult {
    let plan =
        unsafe { window_management_movement_plan(request, window, display_data, count, fallback) };
    super::RectResult {
        code: plan.code,
        frame: plan.frame,
    }
}

#[repr(C)]
pub struct MovementPlanResult {
    pub code: u32,
    pub requires_frame_write: u32,
    pub frame: Rect,
}

/// Resolve a movement and decide whether to write against normalized window coordinates.
/// # Safety
/// Nonempty displays must be readable/aligned for count values. No storage is retained.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn window_management_movement_plan(
    request: MoveRequestValue,
    window: Rect,
    display_data: *const Display,
    count: usize,
    fallback: u32,
) -> MovementPlanResult {
    let Some((r, s)) = request
        .read()
        .zip(unsafe { super::display_slice(display_data, count) })
    else {
        return MovementPlanResult {
            code: 1,
            requires_frame_write: 0,
            frame: Rect::default(),
        };
    };
    window_management::movement_plan(r, window, s, fallback != 0).map_or_else(
        || MovementPlanResult {
            code: 2,
            requires_frame_write: 0,
            frame: Rect::default(),
        },
        |plan| MovementPlanResult {
            code: 0,
            requires_frame_write: u32::from(plan.frame_to_write(window.normalized()).is_some()),
            frame: plan.frame,
        },
    )
}

/// Immutable owned JSON or UTF-8 diagnostic text. Views borrow this owner.
pub struct Json {
    code: u32,
    bytes: Vec<u8>,
}
#[repr(C)]
pub struct JsonView {
    pub code: u32,
    pub data: *const u8,
    pub length: usize,
}
impl Json {
    pub(super) fn from(result: Result<Vec<u8>, serde_json::Error>) -> Self {
        match result {
            Ok(bytes) => Self { code: 0, bytes },
            Err(e) => Self {
                code: 1,
                bytes: e.to_string().into_bytes(),
            },
        }
    }
    pub(super) fn invalid() -> Self {
        Self {
            code: 1,
            bytes: b"Invalid window JSON input or kind.".to_vec(),
        }
    }
    fn owned(value: Option<Result<Vec<u8>, serde_json::Error>>) -> *mut Self {
        let result = value.map_or_else(Self::invalid, Self::from);
        Box::into_raw(Box::new(result))
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn window_management_placement_json(value: PlacementValue) -> *mut Json {
    Json::owned(value.read().map(|v| serde_json::to_vec(&v.normalized())))
}
#[unsafe(no_mangle)]
pub extern "C" fn window_management_display_target_json(value: SelectionValue) -> *mut Json {
    Json::owned(value.read().map(|v| serde_json::to_vec(&v.normalized())))
}
#[unsafe(no_mangle)]
pub extern "C" fn window_management_placement_request_json(
    value: PlacementRequestValue,
) -> *mut Json {
    Json::owned(value.read().map(|v| serde_json::to_vec(&v.normalized())))
}
#[unsafe(no_mangle)]
pub extern "C" fn window_management_move_request_json(value: MoveRequestValue) -> *mut Json {
    Json::owned(value.read().map(|v| serde_json::to_vec(&v)))
}
/// # Safety
/// Input must be readable for length bytes. kind:0 placement,1 selection,2 placement request,
/// 3 move request.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn window_management_value_json(
    kind: u32,
    data: *const u8,
    length: usize,
) -> *mut Json {
    if data.is_null() || length == 0 || length > isize::MAX as usize {
        return Box::into_raw(Box::new(Json::invalid()));
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, length) };
    let result = match kind {
        0 => Json::from(
            serde_json::from_slice::<Placement>(bytes)
                .and_then(|v| serde_json::to_vec(&v.normalized())),
        ),
        1 => Json::from(
            serde_json::from_slice::<DisplayTarget>(bytes)
                .and_then(|v| serde_json::to_vec(&v.normalized())),
        ),
        2 => Json::from(
            serde_json::from_slice::<PlacementRequest>(bytes)
                .and_then(|v| serde_json::to_vec(&v.normalized())),
        ),
        3 => Json::from(
            serde_json::from_slice::<MoveRequest>(bytes).and_then(|v| serde_json::to_vec(&v)),
        ),
        _ => Json::invalid(),
    };
    Box::into_raw(Box::new(result))
}
/// # Safety
/// Owner must be null or live. Copy bytes before destroying the owner.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn window_management_json_view(owner: *const Json) -> JsonView {
    unsafe { owner.as_ref() }.map_or(
        JsonView {
            code: 1,
            data: std::ptr::null(),
            length: 0,
        },
        |v| JsonView {
            code: v.code,
            data: v.bytes.as_ptr(),
            length: v.bytes.len(),
        },
    )
}
/// # Safety
/// Owner must be null or exclusively owned, with all borrowed views finished.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn window_management_json_destroy(owner: *mut Json) {
    if !owner.is_null() {
        drop(unsafe { Box::from_raw(owner) });
    }
}
