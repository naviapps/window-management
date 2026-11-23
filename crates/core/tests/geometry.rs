use window_management::*;
fn rect(x: f64, y: f64, width: f64, height: f64) -> Rect {
    Rect {
        x,
        y,
        width,
        height,
    }
}

#[test]
fn rectangle_normalization_has_canonical_origins_and_extents() {
    for (raw, once) in [
        (
            rect(800.0, 600.0, -800.0, -600.0),
            rect(0.0, 0.0, 800.0, 600.0),
        ),
        (
            rect(800.0, 600.0, -780.0, -560.0),
            rect(20.0, 40.0, 780.0, 560.0),
        ),
        (
            rect(f64::NAN, f64::INFINITY, f64::NEG_INFINITY, f64::NAN),
            Rect::default(),
        ),
        (
            rect(f64::MAX, -f64::MAX, f64::MAX, -f64::MAX),
            rect(f64::MAX, -f64::MAX, 0.0, f64::MAX),
        ),
    ] {
        assert_eq!(raw.normalized(), once);
        assert_eq!(once.normalized(), once);
    }
}

#[test]
fn placement_clamps_grid_inset_and_ratios() {
    let area = rect(-100.0, 20.0, 800.0, 600.0);
    assert_eq!(
        Placement::Grid {
            columns: 2,
            rows: 2,
            column: 1,
            row: 0,
            column_span: 9,
            row_span: 1
        }
        .frame(area, 0.0),
        rect(300.0, 20.0, 400.0, 300.0)
    );
    assert_eq!(
        Placement::Centered {
            width_ratio: 0.5,
            height_ratio: 0.5
        }
        .frame(area, 0.0),
        rect(100.0, 170.0, 400.0, 300.0)
    );
    assert_eq!(
        Placement::Fill {}.frame(area, f64::INFINITY),
        rect(200.0, 320.0, 200.0, 0.0)
    );
    assert_eq!(
        Placement::Centered {
            width_ratio: f64::NAN,
            height_ratio: f64::INFINITY
        }
        .frame(area, 0.0),
        rect(300.0, 20.0, 0.0, 600.0)
    );
}

#[test]
fn placement_normalizes_bounds_and_limits_fill_inset() {
    let area = rect(10.0, 20.0, 300.0, 200.0);
    let reversed = rect(310.0, 220.0, -300.0, -200.0);
    for bounds in [area, reversed] {
        for (inset, expected) in [
            (10.0, rect(20.0, 30.0, 280.0, 180.0)),
            (-50.0, area),
            (f64::NAN, area),
            (500.0, rect(110.0, 120.0, 100.0, 0.0)),
            (f64::MAX, rect(110.0, 120.0, 100.0, 0.0)),
            (f64::INFINITY, rect(110.0, 120.0, 100.0, 0.0)),
        ] {
            assert_eq!(Placement::Fill {}.frame(bounds, inset), expected);
        }
    }
    let invalid = rect(f64::INFINITY, f64::NAN, f64::INFINITY, f64::NEG_INFINITY);
    assert_eq!(Placement::Fill {}.frame(invalid, 0.0), Rect::default());
    let centered = Placement::Centered {
        width_ratio: 0.5,
        height_ratio: 0.4,
    };
    assert_eq!(centered.frame(invalid, 0.0), Rect::default());
    assert_eq!(
        centered.frame(rect(0.0, 0.0, 200.0, 100.0), 0.0),
        rect(50.0, 30.0, 100.0, 40.0)
    );
    for (width_ratio, height_ratio) in [(2.0, -1.0), (f64::INFINITY, f64::NAN)] {
        assert_eq!(
            Placement::Centered {
                width_ratio,
                height_ratio
            }
            .frame(rect(0.0, 0.0, 200.0, 100.0), 0.0),
            rect(0.0, 50.0, 200.0, 0.0)
        );
    }
}

#[test]
fn oversized_insets_collapse_subnormal_dimensions_at_the_rounded_midpoint() {
    let smallest = f64::from_bits(1);
    for (width, inset, remaining_width, remaining_height) in [
        (3.0 * smallest, 1.0, 0.0, 4.0 * smallest),
        (5.0 * smallest, 1.0, 0.0, 2.0 * smallest),
        (5.0 * smallest, 2.0 * smallest, smallest, 3.0 * smallest),
    ] {
        let area = rect(0.0, 0.0, width, 7.0 * smallest);
        assert_eq!(
            Placement::Fill {}.frame(area, inset),
            rect(
                2.0 * smallest,
                2.0 * smallest,
                remaining_width,
                remaining_height
            )
        );
    }
    assert_eq!(
        Placement::Fill {}.frame(
            rect(-smallest, smallest, 3.0 * smallest, 7.0 * smallest),
            1.0
        ),
        rect(0.0, 2.0 * smallest, 0.0, 4.0 * smallest)
    );
}

#[test]
fn grid_rows_start_at_minimum_y_and_clamp_invalid_inputs() {
    let area = rect(0.0, 0.0, 300.0, 200.0);
    for (row, span, expected) in [
        (0, 2, rect(100.0, 0.0, 200.0, 100.0)),
        (1, 1, rect(100.0, 100.0, 100.0, 100.0)),
    ] {
        assert_eq!(
            Placement::Grid {
                columns: 3,
                rows: 2,
                column: 1,
                row,
                column_span: span,
                row_span: 1,
            }
            .frame(area, 0.0),
            expected
        );
    }
    assert_eq!(
        Placement::Grid {
            columns: 0,
            rows: -1,
            column: -10,
            row: 99,
            column_span: 99,
            row_span: 99,
        }
        .frame(area, 0.0),
        area
    );
}

#[test]
fn full_grid_spans_match_fill_without_rounding_or_losing_subnormal_extents() {
    let smallest = f64::from_bits(1);
    for (area, columns, rows, inset) in [
        (rect(0.0, 0.0, 100.0, 100.0), 11, 11, 0.0),
        (rect(0.0, 0.0, smallest, smallest), 2, 2, 0.0),
        (rect(0.0, 0.0, 3.0 * smallest, 3.0 * smallest), 2, 2, 0.0),
        (
            rect(-smallest, smallest, 5.0 * smallest, 7.0 * smallest),
            3,
            5,
            2.0 * smallest,
        ),
    ] {
        let grid = Placement::Grid {
            columns,
            rows,
            column: 0,
            row: 0,
            column_span: columns,
            row_span: rows,
        };
        assert_eq!(
            grid.frame(area, inset),
            Placement::Fill {}.frame(area, inset)
        );
    }
}

#[test]
fn grid_preserves_representable_subnormal_spans_and_offsets() {
    let smallest = f64::from_bits(1);
    let grid = Placement::Grid {
        columns: 8,
        rows: 8,
        column: 4,
        row: 4,
        column_span: 4,
        row_span: 4,
    };
    assert_eq!(
        grid.frame(rect(0.0, 0.0, 2.0 * smallest, 2.0 * smallest), 0.0),
        rect(smallest, smallest, smallest, smallest)
    );
}
#[test]
fn grid_proportions_keep_half_pixels_and_avoid_intermediate_overflow() {
    let half_pixels = Placement::Grid {
        columns: 10,
        rows: 10,
        column: 7,
        row: 0,
        column_span: 1,
        row_span: 7,
    };
    assert_eq!(
        half_pixels.frame(rect(0.0, 0.0, 45.0, 45.0), 0.0),
        rect(31.5, 0.0, 4.5, 31.5)
    );
    let large = Placement::Grid {
        columns: 8,
        rows: 8,
        column: 4,
        row: 4,
        column_span: 4,
        row_span: 4,
    };
    let half = f64::MAX / 2.0;
    assert_eq!(
        large.frame(rect(0.0, 0.0, f64::MAX, f64::MAX), 0.0),
        rect(half, half, half, half)
    );
}
#[test]
fn movement_preserves_size_and_relative_progress() {
    let source = rect(0.0, 0.0, 1000.0, 800.0);
    let target = rect(-500.0, 200.0, 400.0, 400.0);
    assert_eq!(
        preserving_relative_position(rect(400.0, 300.0, 200.0, 200.0), source, target),
        rect(-400.0, 300.0, 200.0, 200.0)
    );
    assert_eq!(
        center_preserving_size(rect(0.0, 0.0, 900.0, 200.0), target),
        rect(-500.0, 300.0, 400.0, 200.0)
    );
    assert_eq!(
        preserving_relative_position(
            rect(50.0, 100.0, 100.0, 100.0),
            rect(0.0, 0.0, 200.0, 200.0),
            rect(300.0, 400.0, 400.0, 300.0),
        ),
        rect(450.0, 600.0, 100.0, 100.0)
    );
    assert_eq!(
        center_preserving_size(
            rect(0.0, 0.0, 120.0, 80.0),
            rect(100.0, 200.0, 300.0, 200.0),
        ),
        rect(190.0, 260.0, 120.0, 80.0)
    );
}

#[test]
fn movement_normalizes_reversed_and_nonfinite_frames() {
    let window = rect(50.0, 50.0, 80.0, 60.0);
    let source = rect(0.0, 0.0, 200.0, 200.0);
    let target = rect(300.0, 0.0, 100.0, 100.0);
    let expected = rect(308.3333333333333, 14.285714285714286, 80.0, 60.0);
    assert_eq!(
        preserving_relative_position(window, source, target),
        expected
    );
    assert_eq!(
        preserving_relative_position(
            rect(130.0, 110.0, -80.0, -60.0),
            rect(200.0, 200.0, -200.0, -200.0),
            rect(400.0, 100.0, -100.0, -100.0),
        ),
        expected
    );
    assert_eq!(
        preserving_relative_position(rect(f64::INFINITY, f64::NAN, 80.0, 60.0), source, target),
        rect(300.0, 0.0, 80.0, 60.0)
    );
    let invalid = rect(f64::INFINITY, f64::NAN, f64::INFINITY, f64::NEG_INFINITY);
    assert_eq!(center_preserving_size(window, invalid), Rect::default());
    assert_eq!(
        preserving_relative_position(window, source, invalid),
        Rect::default()
    );
    let target = rect(100.0, 200.0, 300.0, 200.0);
    assert_eq!(
        center_preserving_size(rect(0.0, 0.0, f64::INFINITY, f64::NAN), target),
        rect(250.0, 300.0, 0.0, 0.0)
    );
    for (window, target) in [
        (
            rect(0.0, 0.0, 500.0, 500.0),
            rect(100.0, 100.0, 300.0, 200.0),
        ),
        (
            rect(500.0, 500.0, -500.0, -500.0),
            rect(400.0, 300.0, -300.0, -200.0),
        ),
    ] {
        assert_eq!(
            center_preserving_size(window, target),
            rect(100.0, 100.0, 300.0, 200.0)
        );
    }
}

#[test]
fn movement_centers_when_the_source_has_no_available_range() {
    let source = rect(0.0, 0.0, 100.0, 100.0);
    let target = rect(200.0, 300.0, 300.0, 500.0);
    assert_eq!(
        preserving_relative_position(source, source, target),
        rect(300.0, 500.0, 100.0, 100.0)
    );
}
#[test]
fn extreme_inputs_never_produce_nonfinite_edges() {
    let values = [-f64::MAX, -1.0, 0.0, 1.0, f64::MAX, f64::NAN, f64::INFINITY];
    for x in values {
        for width in values {
            let r = rect(x, x, width, width).normalized();
            assert!(
                [r.x, r.y, r.width, r.height, r.x + r.width, r.y + r.height]
                    .iter()
                    .all(|v| v.is_finite())
            );
        }
    }
}
#[test]
fn display_order_and_targets_are_explicit() {
    let a = Display {
        frame: rect(0.0, 0.0, 100.0, 100.0),
        visible_frame: rect(0.0, 0.0, 100.0, 90.0),
        identifier: 0,
        has_identifier: 1,
        is_main: 1,
    };
    let b = Display {
        frame: rect(-100.0, 0.0, 100.0, 100.0),
        identifier: 2,
        is_main: 0,
        ..a
    };
    let displays = [a, b];
    assert_eq!(ordered_indices(&displays), [1, 0]);
    for query in [
        DisplayQuery::Main,
        DisplayQuery::ContainingWindow(rect(10.0, 10.0, 20.0, 20.0)),
        DisplayQuery::Point(0.0, 10.0),
        DisplayQuery::Identifier(0),
        DisplayQuery::OrderedIndex(1),
    ] {
        assert_eq!(
            select_display(&displays, query, false),
            Some(0),
            "{query:?}"
        );
        assert_eq!(select_display(&displays, query, true), Some(0), "{query:?}");
    }
}

#[test]
fn missing_display_queries_fall_back_only_to_the_first_ordered_display() {
    let left = Display {
        frame: rect(-100.0, 0.0, 100.0, 80.0),
        visible_frame: rect(-100.0, 10.0, 100.0, 70.0),
        identifier: 1,
        has_identifier: 1,
        is_main: 0,
    };
    let right = Display {
        frame: rect(0.0, 0.0, 100.0, 80.0),
        visible_frame: rect(0.0, 0.0, 100.0, 80.0),
        has_identifier: 0,
        ..left
    };
    let displays = [right, left];
    for query in [
        DisplayQuery::Main,
        DisplayQuery::ContainingWindow(rect(500.0, 500.0, 100.0, 100.0)),
        DisplayQuery::Point(500.0, 500.0),
        DisplayQuery::Point(100.0, 0.0),
        DisplayQuery::Point(f64::NAN, 10.0),
        DisplayQuery::Identifier(99),
        DisplayQuery::OrderedIndex(9),
        DisplayQuery::OrderedIndex(-1),
    ] {
        assert_eq!(select_display(&displays, query, false), None, "{query:?}");
        assert_eq!(select_display(&displays, query, true), Some(1), "{query:?}");
        assert_eq!(select_display(&[], query, false), None, "{query:?}");
        assert_eq!(select_display(&[], query, true), None, "{query:?}");
    }
}

#[test]
fn display_order_treats_signed_zeros_as_equal_coordinates() {
    let primary = Display {
        frame: rect(0.0, 0.0, 100.0, 100.0),
        visible_frame: rect(0.0, 10.0, 100.0, 90.0),
        identifier: 1,
        has_identifier: 1,
        is_main: 1,
    };
    let larger = Display {
        frame: rect(-0.0, -0.0, 200.0, 100.0),
        identifier: 0,
        ..primary
    };
    let higher_identifier = Display {
        frame: rect(-0.0, 0.0, 100.0, 100.0),
        identifier: 9,
        ..primary
    };
    let missing_identifier = Display {
        frame: rect(0.0, -0.0, 100.0, 100.0),
        has_identifier: 0,
        ..primary
    };
    let duplicate_identifier = Display {
        frame: rect(-0.0, -0.0, 100.0, 100.0),
        visible_frame: rect(0.0, 20.0, 100.0, 80.0),
        ..primary
    };
    let displays = [
        primary,
        larger,
        higher_identifier,
        missing_identifier,
        duplicate_identifier,
    ];
    assert_eq!(ordered_indices(&displays), [0, 4, 2, 3, 1]);
    for query in [
        DisplayQuery::OrderedIndex(0),
        DisplayQuery::Point(10.0, 10.0),
        DisplayQuery::ContainingWindow(rect(10.0, 10.0, 20.0, 20.0)),
    ] {
        assert_eq!(select_display(&displays, query, false), Some(0));
        assert_eq!(select_display(&displays, query, true), Some(0));
    }
    assert_eq!(
        select_display(&displays, DisplayQuery::Identifier(99), true),
        Some(0)
    );
    assert_eq!(index_containing_point(&displays, 150.0, 10.0), Some(4));
    assert_eq!(ordered_indices(&[duplicate_identifier, primary]), [0, 1]);
}

#[test]
fn adjacent_index_wraps_signed_inputs_in_both_directions() {
    for (index, count, next, previous) in [
        (0, 3, 1, 2),
        (2, 3, 0, 1),
        (5, 3, 0, 1),
        (-5, 3, 2, 0),
        (i64::MIN, 3, 2, 0),
        (i64::MAX, 3, 2, 0),
        (i64::MIN, 1, 0, 0),
        (i64::MAX, 1, 0, 0),
    ] {
        assert_eq!(adjacent_index(index, false, count), Some(next));
        assert_eq!(adjacent_index(index, true, count), Some(previous));
    }
}

#[test]
fn adjacent_index_rejects_nonpositive_display_counts() {
    for count in [0, -1, i64::MIN] {
        assert_eq!(adjacent_index(i64::MAX, false, count), None);
        assert_eq!(adjacent_index(i64::MIN, true, count), None);
    }
}

#[test]
#[cfg(target_pointer_width = "64")]
fn adjacent_index_preserves_results_at_the_maximum_signed_count() {
    let count = i64::MAX;
    let last = usize::try_from(count - 1).unwrap();
    for (index, next, previous) in [
        (0, 1, last),
        (count - 1, 0, last - 1),
        (i64::MIN, 0, last - 1),
        (i64::MAX, 1, last),
    ] {
        assert_eq!(adjacent_index(index, false, count), Some(next));
        assert_eq!(adjacent_index(index, true, count), Some(previous));
    }
}
