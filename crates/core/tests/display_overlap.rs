use window_management::*;

fn rect(x: f64, y: f64, width: f64, height: f64) -> Rect {
    Rect {
        x,
        y,
        width,
        height,
    }
}

fn display(frame: Rect, identifier: u64) -> Display {
    Display {
        frame,
        visible_frame: frame,
        identifier,
        has_identifier: 1,
        is_main: 0,
    }
}

#[test]
fn point_index_is_a_position_in_stable_order_not_the_input_index() {
    let right = display(rect(100.0, 0.0, 100.0, 100.0), 2);
    let left = display(rect(0.0, 0.0, 100.0, 100.0), 1);
    let fractional = display(rect(300.0, 0.0, f64::from_bits(1), 100.0), 3);
    for displays in [[right, fractional, left], [left, fractional, right]] {
        assert_eq!(index_containing_point(&displays, 0.0, 10.0), Some(0));
        assert_eq!(index_containing_point(&displays, 100.0, 10.0), Some(1));
        assert_eq!(index_containing_point(&displays, 300.0, 10.0), Some(2));
        assert_eq!(index_containing_point(&displays, 200.0, 10.0), None);
        assert_eq!(index_containing_point(&displays, f64::NAN, 10.0), None);
    }
    assert_eq!(index_containing_point(&[], 0.0, 0.0), None);
    assert_eq!(
        select_display(&[right, left], DisplayQuery::Point(100.0, 10.0), false),
        Some(0)
    );
    let identical_frame = Display {
        identifier: 1,
        ..right
    };
    let overlapping = [right, identical_frame];
    assert_eq!(index_containing_point(&overlapping, 100.0, 10.0), Some(0));
    assert_eq!(
        select_display(&overlapping, DisplayQuery::Point(100.0, 10.0), false),
        Some(1)
    );
}

#[test]
fn rounded_origin_distances_do_not_turn_representable_unequal_extents_into_ties() {
    for transpose in [false, true] {
        let axis = |x, width| {
            if transpose {
                rect(0.0, x, 1.0, width)
            } else {
                rect(x, 0.0, width, 1.0)
            }
        };
        let smaller = display(axis(-2.0, 4.0), 1);
        let larger = display(axis(4.0, 1.0), 2);
        let window = axis(1.0 + f64::EPSILON, 4.0);
        for displays in [[smaller, larger], [larger, smaller]] {
            let selected = select_display(&displays, DisplayQuery::ContainingWindow(window), false);
            assert_eq!(selected.map(|i| displays[i].identifier), Some(2));
            assert_eq!(
                placement_frame(
                    PlacementRequest {
                        placement: Placement::Fill {},
                        display: DisplayTarget::ContainingWindow {},
                        area: DisplayArea::Full,
                        inset: 0.0,
                    },
                    window,
                    &displays,
                    false,
                ),
                Some(larger.frame)
            );
            assert_eq!(
                movement_frame(
                    MoveRequest {
                        direction: CycleDirection::Next,
                        preserves_relative_position: false,
                    },
                    window,
                    &displays,
                    false,
                ),
                Some(smaller.frame)
            );
        }
    }
}

#[test]
fn intersection_dimensions_keep_residuals_smaller_than_one_f64_ulp() {
    for residual in [f64::EPSILON / 4.0, f64::from_bits(1)] {
        for transpose in [false, true] {
            let axis = |x, width| {
                if transpose {
                    rect(0.0, x, 1.0, width)
                } else {
                    rect(x, 0.0, width, 1.0)
                }
            };
            // The smaller intersection has exact width 1-residual, which cannot
            // itself be represented by an f64. The area must still rank below 1.
            let smaller = display(axis(-residual, 2.0), 1);
            let larger = display(axis(4.0, 1.0), 2);
            let window = axis(1.0, 4.0);
            for displays in [[smaller, larger], [larger, smaller]] {
                let selected =
                    select_display(&displays, DisplayQuery::ContainingWindow(window), false);
                assert_eq!(selected.map(|i| displays[i].identifier), Some(2));
            }
        }
    }
}

#[test]
fn degenerate_window_centers_do_not_round_onto_an_excluded_edge() {
    for (origin, size, boundary) in [
        (1.0_f64.next_down(), f64::EPSILON / 2.0, 1.0),
        (0.0, 3.0 * f64::from_bits(1), 2.0 * f64::from_bits(1)),
    ] {
        for transpose in [false, true] {
            let axis = |x, width| {
                if transpose {
                    rect(0.0, x, 1.0, width)
                } else {
                    rect(x, 0.0, width, 1.0)
                }
            };
            let before = display(axis(0.0, boundary), 1);
            let after = display(axis(boundary, boundary), 2);
            let window = if transpose {
                rect(0.5, origin, 0.0, size)
            } else {
                rect(origin, 0.5, size, 0.0)
            };
            for displays in [[before, after], [after, before]] {
                let selected =
                    select_display(&displays, DisplayQuery::ContainingWindow(window), false);
                assert_eq!(selected.map(|i| displays[i].identifier), Some(1));
                let placement = PlacementRequest {
                    placement: Placement::Fill {},
                    display: DisplayTarget::default(),
                    area: DisplayArea::Visible,
                    inset: 0.0,
                };
                assert_eq!(
                    placement_frame(placement, window, &displays, false),
                    Some(before.frame)
                );
                let point = if transpose {
                    (0.5, boundary)
                } else {
                    (boundary, 0.5)
                };
                assert_eq!(index_containing_point(&displays, point.0, point.1), Some(1));
            }
        }
    }
}

#[test]
fn equal_area_ties_use_the_exact_window_center() {
    let centered = display(rect(0.0, 0.25, 1.0, 0.5), 1);
    let earlier = display(rect(0.0, 0.0, 2.0, 0.5), 2);
    let window = rect(1.0_f64.next_down(), 0.0, f64::EPSILON / 2.0, 1.0);
    for transpose in [false, true] {
        let transpose_rect = |r: Rect| {
            if transpose {
                rect(r.y, r.x, r.height, r.width)
            } else {
                r
            }
        };
        let centered = display(transpose_rect(centered.frame), 1);
        let earlier = display(transpose_rect(earlier.frame), 2);
        for displays in [[earlier, centered], [centered, earlier]] {
            let selected = select_display(
                &displays,
                DisplayQuery::ContainingWindow(transpose_rect(window)),
                false,
            );
            assert_eq!(selected.map(|i| displays[i].identifier), Some(1));
        }
    }
}

#[test]
fn exact_containment_keeps_finite_extremes_and_half_open_edges() {
    let tiny = f64::from_bits(1);
    for (origin, size, inside, outside) in [
        (-f64::MAX, f64::MAX, -tiny, 0.0),
        (0.0, f64::MAX, f64::MAX.next_down(), f64::MAX),
        (2.0, 1.0 + f64::EPSILON, 3.0, 3.0_f64.next_up()),
        (-tiny, tiny, -tiny, 0.0),
    ] {
        for transpose in [false, true] {
            let (frame, inside, outside) = if transpose {
                (rect(0.0, origin, 1.0, size), (0.5, inside), (0.5, outside))
            } else {
                (rect(origin, 0.0, size, 1.0), (inside, 0.5), (outside, 0.5))
            };
            assert!(frame.contains(inside.0, inside.1));
            assert!(!frame.contains(outside.0, outside.1));
        }
    }
    assert!(rect(f64::MAX, 0.0, tiny, 1.0).contains(f64::MAX, 0.5));
    assert!(!rect(0.0, 0.0, 0.0, 1.0).contains(0.0, 0.5));
    for invalid in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
        assert!(!rect(invalid, invalid, invalid, invalid).contains(invalid, 0.0));
        assert!(!rect(0.0, 0.0, 1.0, 1.0).contains(0.0, invalid));
    }
}

#[test]
fn point_queries_and_zero_size_windows_keep_positive_fractional_display_extents() {
    for (frame, point) in [
        (rect(1.0, 1.0, 1e-200, 1e-200), (1.0, 1.0)),
        (rect(2.0, 0.0, 1.0 + f64::EPSILON, 1.0), (3.0, 0.0)),
    ] {
        assert!(frame.contains(point.0, point.1));
        let displays = [display(frame, 1)];
        assert_eq!(
            select_display(&displays, DisplayQuery::Point(point.0, point.1), false),
            Some(0)
        );
        assert_eq!(
            select_display(
                &displays,
                DisplayQuery::ContainingWindow(rect(point.0, point.1, 0.0, 0.0)),
                false,
            ),
            Some(0)
        );
    }
    let unit = rect(2.0, 0.0, 1.0, 1.0);
    assert!(!unit.contains(3.0, 0.0));
    assert!(!unit.contains(2.0, 1.0));
}

#[test]
fn rounded_origin_distances_preserve_points_and_overlap_before_maximum_edges() {
    let inside = f64::from_bits(1.0_f64.to_bits() - 1);
    for (frame, x, y, window) in [
        (
            rect(-1.0, 0.0, 2.0, 1.0),
            inside,
            0.5,
            rect(inside, 0.5, 1.0, 0.25),
        ),
        (
            rect(0.0, -1.0, 1.0, 2.0),
            0.5,
            inside,
            rect(0.5, inside, 0.25, 1.0),
        ),
    ] {
        let displays = [display(frame, 1)];
        assert!(frame.contains(x, y));
        for query in [
            DisplayQuery::Point(x, y),
            DisplayQuery::ContainingWindow(rect(x, y, 0.0, 0.0)),
            DisplayQuery::ContainingWindow(window),
        ] {
            assert_eq!(select_display(&displays, query, false), Some(0));
        }
    }
}

#[test]
fn placement_and_movement_resolve_a_window_whose_center_is_in_a_display_gap() {
    let left = display(rect(-400.0, -100.0, 200.0, 300.0), 1);
    let right = display(rect(100.0, -100.0, 300.0, 300.0), 2);
    let window = rect(-250.0, -50.0, 450.0, 100.0);
    let displays = [right, left];
    assert_eq!(
        select_display(&displays, DisplayQuery::ContainingWindow(window), false),
        Some(0)
    );
    let placement = PlacementRequest {
        placement: Placement::Fill {},
        display: DisplayTarget::ContainingWindow {},
        area: DisplayArea::Visible,
        inset: 0.0,
    };
    assert_eq!(
        placement_frame(placement, window, &displays, false),
        Some(right.frame)
    );
    for direction in [CycleDirection::Next, CycleDirection::Previous] {
        assert_eq!(
            movement_frame(
                MoveRequest {
                    direction,
                    preserves_relative_position: false
                },
                window,
                &displays,
                false,
            ),
            Some(rect(-400.0, 0.0, 200.0, 100.0))
        );
    }
}

#[test]
fn greatest_overlap_wins_even_when_another_display_contains_the_center() {
    let left = display(rect(-400.0, -200.0, 300.0, 400.0), 1);
    let right = display(rect(-100.0, -10.0, 300.0, 20.0), 2);
    let window = rect(-250.0, -100.0, 400.0, 200.0);
    assert_eq!(
        select_display(
            &[right, left],
            DisplayQuery::ContainingWindow(window),
            false
        ),
        Some(1)
    );
}

#[test]
fn equal_overlaps_prefer_center_containment_then_stable_display_order() {
    let left = display(rect(-100.0, 0.0, 100.0, 100.0), 1);
    let right = display(rect(0.0, 0.0, 100.0, 100.0), 2);
    assert_eq!(
        select_display(
            &[left, right],
            DisplayQuery::ContainingWindow(rect(-50.0, 0.0, 100.0, 100.0)),
            false
        ),
        Some(1)
    );
    let left = display(rect(-200.0, 0.0, 100.0, 100.0), 1);
    let right = display(rect(100.0, 0.0, 100.0, 100.0), 2);
    let window = rect(-150.0, 0.0, 300.0, 100.0);
    assert_eq!(
        select_display(
            &[right, left],
            DisplayQuery::ContainingWindow(window),
            false
        ),
        Some(1)
    );
    assert_eq!(
        select_display(
            &[left, right],
            DisplayQuery::ContainingWindow(window),
            false
        ),
        Some(0)
    );
}

#[test]
fn overlap_comparison_does_not_overflow_or_underflow() {
    let placement = PlacementRequest {
        placement: Placement::Fill {},
        display: DisplayTarget::default(),
        area: DisplayArea::Visible,
        inset: 0.0,
    };
    for scale in [1e307, 1e-200, f64::from_bits(1)] {
        let left = display(rect(-8.0 * scale, -8.0 * scale, scale, 4.0 * scale), 1);
        let right = display(rect(scale, -8.0 * scale, 2.0 * scale, 4.0 * scale), 2);
        let window = rect(-8.0 * scale, -8.0 * scale, 12.0 * scale, 8.0 * scale);
        let displays = [left, right];
        assert_eq!(
            select_display(&displays, DisplayQuery::ContainingWindow(window), false),
            Some(1),
            "scale {scale}"
        );
        assert_eq!(
            placement_frame(placement, window, &displays, false),
            Some(right.frame)
        );
    }
}

#[test]
fn unequal_areas_do_not_become_ties_through_float_multiplication() {
    let epsilon = f64::EPSILON;
    let smaller = display(rect(0.0, 0.0, 1.0 + epsilon, 1.0 - epsilon), 1);
    let larger = display(rect(2.0, 0.0, 1.0, 1.0), 2);
    let window = rect(0.0, 0.0, 3.0, 1.0);
    assert_eq!(
        select_display(
            &[smaller, larger],
            DisplayQuery::ContainingWindow(window),
            false
        ),
        Some(1)
    );
}

#[test]
fn positive_subpixel_windows_at_nonzero_origins_keep_their_overlap() {
    let current = display(rect(-100.0, -100.0, 200.0, 200.0), 1);
    let next = display(rect(200.0, -100.0, 200.0, 200.0), 2);
    let displays = [next, current];
    let placement = PlacementRequest {
        placement: Placement::Fill {},
        display: DisplayTarget::ContainingWindow {},
        area: DisplayArea::Visible,
        inset: 0.0,
    };
    let movement = MoveRequest {
        direction: CycleDirection::Next,
        preserves_relative_position: false,
    };
    for origin in [-1.0, 1.0] {
        for size in [1e-200, f64::from_bits(1)] {
            let window = rect(origin, origin, size, size);
            assert_eq!(
                select_display(&displays, DisplayQuery::ContainingWindow(window), false),
                Some(1)
            );
            assert_eq!(
                placement_frame(placement, window, &displays, false),
                Some(current.frame)
            );
            assert_eq!(
                movement_frame(movement, window, &displays, false),
                Some(rect(300.0, 0.0, size, size))
            );
        }
    }
}

#[test]
fn contained_display_dimensions_do_not_round_unequal_areas_into_ties() {
    let smaller = display(rect(0.0, 0.0, 1.0, 1.0), 1);
    let window = rect(0.0, 0.0, 8.0, 8.0);
    for (width, height) in [(1.0 + f64::EPSILON, 1.0), (1.0, 1.0 + f64::EPSILON)] {
        let larger = display(rect(2.0, 2.0, width, height), 2);
        for (displays, expected) in [([smaller, larger], 1), ([larger, smaller], 0)] {
            assert_eq!(
                select_display(&displays, DisplayQuery::ContainingWindow(window), false),
                Some(expected)
            );
            let placement = PlacementRequest {
                placement: Placement::Fill {},
                display: DisplayTarget::default(),
                area: DisplayArea::Visible,
                inset: 0.0,
            };
            assert_eq!(
                placement_frame(placement, window, &displays, false),
                Some(larger.frame)
            );
        }
    }
}

#[test]
fn adjacent_edges_require_positive_overlap_on_each_axis() {
    for origin in [-4.0, 0.0] {
        for transpose in [false, true] {
            let frame = if transpose {
                rect(0.0, origin + 1.0, 1.0, 1.0)
            } else {
                rect(origin + 1.0, 0.0, 1.0, 1.0)
            };
            let displays = [display(frame, 1)];
            for size in [1.0_f64.next_down(), 1.0, 1.0_f64.next_up()] {
                let window = if transpose {
                    rect(0.0, origin, 1.0, size)
                } else {
                    rect(origin, 0.0, size, 1.0)
                };
                assert_eq!(
                    select_display(&displays, DisplayQuery::ContainingWindow(window), false),
                    (size > 1.0).then_some(0)
                );
            }
        }
    }
}

#[test]
fn overflowing_origin_distances_remain_disjoint() {
    let half = f64::MAX / 2.0;
    let near = display(rect(-f64::MAX, -f64::MAX, half, half), 1);
    let far = display(rect(half, half, half, half), 2);
    let window = rect(-f64::MAX, -f64::MAX, f64::MAX, f64::MAX);
    assert_eq!(
        select_display(&[far], DisplayQuery::ContainingWindow(window), false),
        None
    );
    assert_eq!(
        select_display(&[far, near], DisplayQuery::ContainingWindow(window), false),
        Some(1)
    );
}

#[test]
fn degenerate_windows_keep_point_semantics_and_empty_displays_do_not_overlap() {
    let empty = display(rect(-100.0, 0.0, 0.0, 100.0), 1);
    let right = display(rect(0.0, -100.0, 100.0, 200.0), 2);
    for window in [rect(25.0, 0.0, 0.0, 0.0), rect(25.0, -50.0, 0.0, 100.0)] {
        assert_eq!(
            select_display(
                &[empty, right],
                DisplayQuery::ContainingWindow(window),
                false
            ),
            Some(1)
        );
    }
    assert_eq!(
        select_display(
            &[empty, right],
            DisplayQuery::ContainingWindow(rect(-100.0, 0.0, 100.0, 10.0)),
            false
        ),
        None
    );
}

#[test]
fn removed_displays_and_non_overlapping_windows_still_require_explicit_fallback() {
    let remaining = display(rect(-400.0, -100.0, 200.0, 300.0), 1);
    let window = rect(100.0, -50.0, 100.0, 100.0);
    let displays = [remaining];
    for query in [
        DisplayQuery::ContainingWindow(window),
        DisplayQuery::Identifier(2),
    ] {
        assert_eq!(select_display(&displays, query, false), None);
        assert_eq!(select_display(&displays, query, true), Some(0));
        assert_eq!(select_display(&[], query, true), None);
    }
    let movement = MoveRequest {
        direction: CycleDirection::Next,
        preserves_relative_position: false,
    };
    assert_eq!(movement_frame(movement, window, &displays, false), None);
    assert_eq!(
        movement_frame(movement, window, &displays, true),
        Some(rect(-350.0, 0.0, 100.0, 100.0))
    );
}

#[test]
fn reversed_dimensions_use_the_same_normalized_overlap() {
    let left = display(rect(-400.0, -100.0, 200.0, 300.0), 1);
    let right = display(rect(400.0, 200.0, -300.0, -300.0), 2);
    let window = rect(200.0, 50.0, -450.0, -100.0);
    assert_eq!(
        select_display(
            &[right, left],
            DisplayQuery::ContainingWindow(window),
            false
        ),
        Some(0)
    );
}
