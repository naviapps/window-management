use crate::displays::select_ordered_index;
use crate::{
    Display, DisplayQuery, Placement, Rect, adjacent_index, center_preserving_size,
    ordered_indices, preserving_relative_position, select_display,
};
use serde::{Deserialize, Serialize};

/// Persistable selection rule. Identifiers belong to their platform and are not portable IDs.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "kebab-case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum DisplayTarget {
    Main {},
    /// Greatest positive window overlap, with the same tie and zero-size rules as DisplayQuery.
    ContainingWindow {},
    Point {
        x: f64,
        y: f64,
    },
    DisplayIdentifier {
        display_identifier: u64,
    },
    OrderedIndex {
        ordered_index: i64,
    },
}
impl DisplayTarget {
    pub fn normalized(self) -> Self {
        match self {
            Self::Point { x, y } => Self::Point {
                x: finite(x),
                y: finite(y),
            },
            Self::OrderedIndex { ordered_index } => Self::OrderedIndex {
                ordered_index: ordered_index.max(0),
            },
            _ => self,
        }
    }
    /// Supply the current window only when resolving a request, not when persisting one.
    pub fn target(self, window: Rect) -> DisplayQuery {
        match self.normalized() {
            Self::Main {} => DisplayQuery::Main,
            Self::ContainingWindow {} => DisplayQuery::ContainingWindow(window),
            Self::Point { x, y } => DisplayQuery::Point(x, y),
            Self::DisplayIdentifier { display_identifier } => {
                DisplayQuery::Identifier(display_identifier)
            }
            Self::OrderedIndex { ordered_index } => DisplayQuery::OrderedIndex(ordered_index),
        }
    }
}
impl Default for DisplayTarget {
    fn default() -> Self {
        Self::ContainingWindow {}
    }
}
fn finite(value: f64) -> f64 {
    if value.is_finite() { value } else { 0.0 }
}
/// Canonical inset for stored requests. Non-finite and negative inputs become zero.
pub fn normalized_inset(value: f64) -> f64 {
    finite(value).max(0.0)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DisplayArea {
    Full,
    #[default]
    Visible,
}

/// Reusable placement request. Call `normalized` before serializing untrusted direct values.
/// Serde rejects unknown fields and explicit nulls; omitted optional fields take these defaults.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PlacementRequest {
    pub placement: Placement,
    // The versioned storage key is independent of the public API's display terminology.
    #[serde(default, rename = "screen")]
    pub display: DisplayTarget,
    #[serde(default)]
    pub area: DisplayArea,
    #[serde(default)]
    pub inset: f64,
}
impl PlacementRequest {
    pub fn normalized(self) -> Self {
        Self {
            placement: self.placement.normalized(),
            display: self.display.normalized(),
            area: self.area,
            inset: normalized_inset(self.inset),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum CycleDirection {
    Next,
    Previous,
}
fn default_true() -> bool {
    true
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MoveRequest {
    pub direction: CycleDirection,
    #[serde(default = "default_true")]
    pub preserves_relative_position: bool,
}

/// Resolve a complete placement without querying an OS. A missing target remains explicit.
pub fn placement_frame(
    request: PlacementRequest,
    window: Rect,
    displays: &[Display],
    fallback: bool,
) -> Option<Rect> {
    let r = request.normalized();
    let selected = &displays[select_display(displays, r.display.target(window), fallback)?];
    let area = match r.area {
        DisplayArea::Full => selected.frame,
        DisplayArea::Visible => selected.visible_frame,
    };
    Some(r.placement.frame(area, r.inset))
}

/// Resolve an adjacent-display move in the same coordinate space as the supplied display frames.
/// The source uses the same greatest-overlap selection as a containing-window placement.
/// A window already on the only display keeps its normalized frame.
pub fn movement_frame(
    request: MoveRequest,
    window: Rect,
    displays: &[Display],
    fallback: bool,
) -> Option<Rect> {
    movement_plan(request, window, displays, fallback).map(|plan| plan.frame)
}

/// A resolved adjacent-display move and its native frame-write decision.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MovementPlan {
    /// Resolved frame in the same coordinate space as the input displays.
    pub frame: Rect,
    only_display: bool,
}

impl MovementPlan {
    /// Returns the frame to write. The adapter supplies the current frame in the
    /// representation its native operation compares. An equal frame still
    /// requests a write when cycling across multiple displays.
    pub fn frame_to_write(self, current: Rect) -> Option<Rect> {
        (!self.only_display || self.frame != current).then_some(self.frame)
    }
}

/// Resolve an adjacent-display move without issuing a native frame write.
pub fn movement_plan(
    request: MoveRequest,
    window: Rect,
    displays: &[Display],
    fallback: bool,
) -> Option<MovementPlan> {
    let target = DisplayQuery::ContainingWindow(window);
    let order = ordered_indices(displays);
    let only_display = order.len() == 1;
    let source = match select_ordered_index(displays, &order, target) {
        Some(_) if only_display => {
            return Some(MovementPlan {
                frame: window.normalized(),
                only_display,
            });
        }
        Some(position) => position,
        None if fallback && !order.is_empty() => 0,
        None => return None,
    };
    let next = adjacent_index(
        source as i64,
        request.direction == CycleDirection::Previous,
        order.len() as i64,
    )?;
    let from = displays[order[source]].visible_frame;
    let to = displays[order[next]].visible_frame;
    let frame = if request.preserves_relative_position {
        preserving_relative_position(window, from, to)
    } else {
        center_preserving_size(window, to)
    };
    Some(MovementPlan {
        frame,
        only_display,
    })
}
