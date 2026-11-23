use window_management::*;
#[test]
fn request_json_round_trip_preserves_finite_coordinate_bits() {
    let coordinate = f64::from_bits(9_223_372_036_854_775_808.0_f64.to_bits() - 1);
    for (x, y) in [
        (coordinate, -coordinate),
        (-0.0, f64::from_bits(1)),
        (f64::MAX, -f64::MAX),
    ] {
        let request = PlacementRequest {
            placement: Placement::Fill {},
            display: DisplayTarget::Point { x, y },
            area: DisplayArea::Visible,
            inset: 0.0,
        }
        .normalized();
        let bytes = serde_json::to_vec(&request).unwrap();
        let restored: PlacementRequest = serde_json::from_slice(&bytes).unwrap();
        let DisplayTarget::Point {
            x: read_x,
            y: read_y,
        } = restored.display
        else {
            panic!("expected point target");
        };
        assert_eq!(
            (read_x.to_bits(), read_y.to_bits()),
            (x.to_bits(), y.to_bits())
        );
    }
}
#[test]
fn requests_share_storage_defaults_and_normalization() {
    let r: PlacementRequest = serde_json::from_str(r#"{"placement":{"kind":"fill"}}"#).unwrap();
    assert_eq!(r.display, DisplayTarget::ContainingWindow {});
    assert_eq!(r.area, DisplayArea::Visible);
    assert_eq!(r.inset, 0.0);
    let saved: PlacementRequest = serde_json::from_str(
        r#"{"placement":{"kind":"fill"},"screen":{"kind":"display-identifier","displayIdentifier":18446744073709551615}}"#,
    )
    .unwrap();
    assert_eq!(
        saved.display,
        DisplayTarget::DisplayIdentifier {
            display_identifier: u64::MAX
        }
    );
    let encoded = serde_json::to_value(saved).unwrap();
    assert_eq!(encoded["screen"]["displayIdentifier"], u64::MAX);
    assert!(encoded.get("display").is_none());
    let r = PlacementRequest {
        placement: Placement::Centered {
            width_ratio: f64::INFINITY,
            height_ratio: f64::NAN,
        },
        display: DisplayTarget::Point {
            x: f64::INFINITY,
            y: f64::NEG_INFINITY,
        },
        area: DisplayArea::Full,
        inset: f64::NAN,
    }
    .normalized();
    assert_eq!(
        r.placement,
        Placement::Centered {
            width_ratio: 1.0,
            height_ratio: 0.0
        }
    );
    assert_eq!(r.display, DisplayTarget::Point { x: 0.0, y: 0.0 });
    assert_eq!(r.inset, 0.0);
    assert!(serde_json::to_vec(&r).is_ok());
}

#[test]
fn placement_requests_round_trip_canonical_tagged_payloads() {
    for (placement, screen, area) in [
        (
            r#"{"kind":"grid","columns":2,"rows":3,"column":1,"row":2,"columnSpan":1,"rowSpan":1}"#,
            r#"{"kind":"ordered-index","orderedIndex":2}"#,
            "full",
        ),
        (
            r#"{"kind":"centered","widthRatio":0.7,"heightRatio":0.5}"#,
            r#"{"kind":"main"}"#,
            "visible",
        ),
        (
            r#"{"kind":"fill"}"#,
            r#"{"kind":"point","x":10.0,"y":20.0}"#,
            "full",
        ),
    ] {
        let input =
            format!(r#"{{"placement":{placement},"screen":{screen},"area":"{area}","inset":6.0}}"#);
        let request = serde_json::from_str::<PlacementRequest>(&input).unwrap();
        let expected = serde_json::from_str::<serde_json::Value>(&input).unwrap();
        assert_eq!(serde_json::to_value(request).unwrap(), expected);
    }
}

#[test]
fn placement_request_storage_rejects_invalid_fields() {
    for invalid in [
        // The request has one required field and three non-null optional fields.
        r#"{"screen":{"kind":"containing-window"},"area":"visible","inset":0}"#,
        r#"{"placement":null}"#,
        r#"{"placement":{"kind":"fill"},"screen":null}"#,
        r#"{"placement":{"kind":"fill"},"area":null}"#,
        r#"{"placement":{"kind":"fill"},"inset":null}"#,
        r#"{"placement":{"kind":"fill"},"metadata":{}}"#,
        r#"{"placement":{"kind":"fill"},"display":{"kind":"main"}}"#,
        r#"{"placement":{"kind":"fill"},"inset":1,"inset":2}"#,
        // Each placement and screen kind accepts only its own associated fields.
        r#"{"placement":{"kind":"fill","column":1}}"#,
        r#"{"placement":{"kind":"fill","columns":2}}"#,
        r#"{"placement":{"kind":"grid","columns":2,"rows":3,"column":1,"row":2,"columnSpan":1,"rowSpan":1,"widthRatio":0.7}}"#,
        r#"{"placement":{"kind":"centered","widthRatio":0.7,"heightRatio":0.5,"column":1}}"#,
        r#"{"placement":{"kind":"fill","metadata":{}}}"#,
        r#"{"placement":{"kind":"fill","extra":0}}"#,
        r#"{"placement":{"kind":"fill"},"screen":{"kind":"main","x":10}}"#,
        r#"{"placement":{"kind":"fill"},"screen":{"kind":"containing-window","orderedIndex":2}}"#,
        r#"{"placement":{"kind":"fill"},"screen":{"kind":"point","x":10,"y":20,"displayIdentifier":7}}"#,
        r#"{"placement":{"kind":"fill"},"screen":{"kind":"ordered-index","orderedIndex":2,"x":10}}"#,
        r#"{"placement":{"kind":"fill"},"screen":{"kind":"containing-window","metadata":{}}}"#,
    ] {
        assert!(
            serde_json::from_str::<PlacementRequest>(invalid).is_err(),
            "accepted invalid placement request {invalid}"
        );
    }
}

#[test]
fn movement_request_storage_uses_canonical_directions_and_relative_position() {
    for (input, name, direction, preserves_relative_position) in [
        (
            r#"{"direction":"next"}"#,
            "next",
            CycleDirection::Next,
            true,
        ),
        (
            r#"{"direction":"previous"}"#,
            "previous",
            CycleDirection::Previous,
            true,
        ),
        (
            r#"{"direction":"next","preservesRelativePosition":true}"#,
            "next",
            CycleDirection::Next,
            true,
        ),
        (
            r#"{"direction":"next","preservesRelativePosition":false}"#,
            "next",
            CycleDirection::Next,
            false,
        ),
        (
            r#"{"direction":"previous","preservesRelativePosition":true}"#,
            "previous",
            CycleDirection::Previous,
            true,
        ),
        (
            r#"{"preservesRelativePosition": false, "direction": "previous" }"#,
            "previous",
            CycleDirection::Previous,
            false,
        ),
    ] {
        let request = MoveRequest {
            direction,
            preserves_relative_position,
        };
        assert_eq!(serde_json::from_str::<MoveRequest>(input).unwrap(), request);
        let canonical = serde_json::to_string(&request).unwrap();
        assert_eq!(
            canonical,
            format!(
                r#"{{"direction":"{name}","preservesRelativePosition":{preserves_relative_position}}}"#
            )
        );
        assert_eq!(
            serde_json::from_str::<MoveRequest>(&canonical).unwrap(),
            request
        );
    }
}

#[test]
fn movement_request_storage_rejects_invalid_fields_and_bytes() {
    for invalid in [
        br#"{"preservesRelativePosition":true}"#.as_slice(),
        br#"{"direction":null}"#,
        br#"{"direction":0}"#,
        br#"{"direction":"NEXT"}"#,
        br#"{"direction":"left"}"#,
        br#"{"direction":"next","preservesRelativePosition":null}"#,
        br#"{"direction":"next","preservesRelativePosition":1}"#,
        br#"{"direction":"next","preservesRelativePosition":"false"}"#,
        br#"{"direction":"next","metadata":{}}"#,
        br#"{"direction":"next","direction":"previous"}"#,
        br#"{"direction":"next","preservesRelativePosition":true,"preservesRelativePosition":false}"#,
        br#"{"direction":"next","preserves_relative_position":false}"#,
        br#"{"direction":"next"} {}"#,
        b"{\"direction\":\"\xff\"}",
    ] {
        assert!(
            serde_json::from_slice::<MoveRequest>(invalid).is_err(),
            "accepted invalid movement request {invalid:?}"
        );
    }
}

#[test]
fn complete_resolution_preserves_order_usable_areas_and_explicit_missing_targets() {
    let displays = [
        Display {
            frame: Rect {
                x: 200.0,
                y: 0.0,
                width: 200.0,
                height: 120.0,
            },
            visible_frame: Rect {
                x: 200.0,
                y: 20.0,
                width: 200.0,
                height: 100.0,
            },
            identifier: 2,
            has_identifier: 1,
            is_main: 0,
        },
        Display {
            frame: Rect {
                x: 0.0,
                y: 0.0,
                width: 200.0,
                height: 120.0,
            },
            visible_frame: Rect {
                x: 0.0,
                y: 0.0,
                width: 200.0,
                height: 100.0,
            },
            identifier: 1,
            has_identifier: 1,
            is_main: 1,
        },
    ];
    let window = Rect {
        x: 100.0,
        y: 50.0,
        width: 50.0,
        height: 25.0,
    };
    let request = PlacementRequest {
        placement: Placement::Fill {},
        display: DisplayTarget::DisplayIdentifier {
            display_identifier: 2,
        },
        area: DisplayArea::Visible,
        inset: 10.0,
    };
    assert_eq!(
        placement_frame(request, window, &displays, false),
        Some(Rect {
            x: 210.0,
            y: 30.0,
            width: 180.0,
            height: 80.0
        })
    );
    let missing = PlacementRequest {
        display: DisplayTarget::DisplayIdentifier {
            display_identifier: 99,
        },
        ..request
    };
    assert_eq!(placement_frame(missing, window, &displays, false), None);
    assert_eq!(
        placement_frame(missing, window, &displays, true),
        Some(Rect {
            x: 10.0,
            y: 10.0,
            width: 180.0,
            height: 80.0
        })
    );
    let movement = MoveRequest {
        direction: CycleDirection::Next,
        preserves_relative_position: true,
    };
    assert_eq!(
        movement_frame(movement, window, &displays, false),
        Some(Rect {
            x: 300.0,
            y: 70.0,
            width: 50.0,
            height: 25.0
        })
    );
    let outside = Rect { x: 900.0, ..window };
    assert_eq!(movement_frame(movement, outside, &displays, false), None);
    assert!(movement_frame(movement, outside, &displays, true).is_some());
    assert_eq!(movement_frame(movement, window, &[], true), None);
    assert_eq!(placement_frame(request, window, &[], true), None);
}

#[test]
fn movement_on_the_only_display_leaves_the_frame_unchanged() {
    let display = Display {
        frame: Rect {
            width: 100.0,
            height: 80.0,
            ..Rect::default()
        },
        visible_frame: Rect {
            y: 10.0,
            width: 100.0,
            height: 70.0,
            ..Rect::default()
        },
        identifier: 1,
        has_identifier: 1,
        is_main: 1,
    };
    let overhanging = Rect {
        x: -120.0,
        y: 0.0,
        width: 140.0,
        height: 60.0,
    };
    let offscreen = Rect {
        x: 300.0,
        y: 300.0,
        width: 40.0,
        height: 30.0,
    };
    for direction in [CycleDirection::Next, CycleDirection::Previous] {
        for (preserves_relative_position, x, y) in [(true, 60.0, 50.0), (false, 30.0, 30.0)] {
            let request = MoveRequest {
                direction,
                preserves_relative_position,
            };
            for fallback in [false, true] {
                assert_eq!(
                    movement_frame(request, overhanging, &[display], fallback),
                    Some(overhanging)
                );
                let plan = movement_plan(request, overhanging, &[display], fallback).unwrap();
                assert_eq!(plan.frame_to_write(overhanging), None);
            }
            assert_eq!(movement_plan(request, offscreen, &[display], false), None);
            let plan = movement_plan(request, offscreen, &[display], true).unwrap();
            assert_eq!(
                plan.frame_to_write(offscreen),
                Some(Rect { x, y, ..offscreen })
            );
        }
    }
}

#[test]
fn movement_decision_keeps_raw_and_normalized_comparison_and_mirrored_writes() {
    let area = Rect {
        width: 100.0,
        height: 100.0,
        ..Rect::default()
    };
    let display = Display {
        frame: area,
        visible_frame: area,
        identifier: 1,
        has_identifier: 1,
        is_main: 1,
    };
    let raw = Rect {
        x: 60.0,
        y: 60.0,
        width: -20.0,
        height: -20.0,
    };
    let expected = raw.normalized();
    let request = MoveRequest {
        direction: CycleDirection::Next,
        preserves_relative_position: true,
    };
    let single = movement_plan(request, raw, &[display], false).unwrap();
    assert_eq!(single.frame, expected);
    assert_eq!(single.frame_to_write(expected), None);
    assert_eq!(single.frame_to_write(raw), Some(expected));

    let mirrored = Display {
        identifier: 2,
        is_main: 0,
        ..display
    };
    let multiple = movement_plan(request, raw, &[display, mirrored], false).unwrap();
    assert_eq!(multiple.frame_to_write(expected), Some(expected));
    assert_eq!(movement_plan(request, raw, &[], true), None);
}
