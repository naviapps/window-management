//! Deterministic window geometry and display selection. Native handles and host policy stay outside.
mod displays;
mod exact_geometry;
mod geometry;
mod requests;
mod snapshots;
pub use displays::{
    Display, DisplayQuery, adjacent_index, index_containing_point, ordered_indices, select_display,
};
pub use geometry::{Placement, Rect, center_preserving_size, preserving_relative_position};
pub use requests::{
    CycleDirection, DisplayArea, DisplayTarget, MoveRequest, MovementPlan, PlacementRequest,
    movement_frame, movement_plan, normalized_inset, placement_frame,
};
pub use snapshots::{SnapshotFilter, SnapshotIdentityMatch};
