use window_management::{
    Display, DisplayArea, DisplayQuery, DisplayTarget, Placement, PlacementRequest, Rect,
    SnapshotFilter, index_containing_point, placement_frame, select_display,
};

fn rect(x: f64, y: f64, width: f64, height: f64) -> Rect {
    Rect {
        x,
        y,
        width,
        height,
    }
}

fn main() {
    let filter = SnapshotFilter {
        included_owner_process_identifiers: [12, i64::MIN].into(),
        included_window_identifiers: [42, u64::MAX].into(),
        ..SnapshotFilter::default()
    };
    assert!(filter.includes(u64::MAX, i64::MIN, None));
    assert!(filter.includes(42, 12, None));
    let smallest = f64::from_bits(1);
    assert_eq!(
        Placement::Fill {}.frame(rect(0.0, 0.0, 3.0 * smallest, 7.0 * smallest), 1.0),
        rect(2.0 * smallest, 2.0 * smallest, 0.0, 4.0 * smallest)
    );
    let displays = [
        Display {
            frame: rect(1000.0, 0.0, 600.0, 500.0),
            visible_frame: rect(1000.0, 20.0, 600.0, 480.0),
            identifier: 2,
            has_identifier: 1,
            is_main: 0,
        },
        Display {
            frame: rect(0.0, 0.0, 800.0, 600.0),
            visible_frame: rect(0.0, 40.0, 800.0, 560.0),
            identifier: 1,
            has_identifier: 1,
            is_main: 1,
        },
    ];
    // The center is in the gap, but the right display has greater overlap.
    let window = rect(600.0, 80.0, 640.0, 200.0);
    assert_eq!(
        select_display(&displays, DisplayQuery::ContainingWindow(window), false),
        Some(0)
    );
    assert_eq!(index_containing_point(&displays, 1000.0, 80.0), Some(1));
    let mirrored = Display {
        frame: rect(-0.0, -0.0, 800.0, 600.0),
        identifier: 9,
        ..displays[1]
    };
    assert_eq!(
        select_display(
            &[displays[1], mirrored],
            DisplayQuery::Point(10.0, 10.0),
            false
        ),
        Some(0)
    );

    let request = PlacementRequest {
        placement: Placement::Grid {
            columns: 2,
            rows: 1,
            column: 1,
            row: 0,
            column_span: 1,
            row_span: 1,
        },
        display: DisplayTarget::ContainingWindow {},
        area: DisplayArea::Visible,
        inset: 10.0,
    };
    assert_eq!(
        placement_frame(request, window, &displays, false),
        Some(rect(1300.0, 30.0, 290.0, 460.0))
    );

    let removed = PlacementRequest {
        display: DisplayTarget::DisplayIdentifier {
            display_identifier: 99,
        },
        ..request
    };
    assert_eq!(placement_frame(removed, window, &displays, false), None);
    assert_eq!(
        placement_frame(removed, window, &displays, true),
        Some(rect(400.0, 50.0, 390.0, 540.0))
    );
    println!(
        "Standalone Rust Git WindowManagement consumer passed placement and display selection."
    );
}
