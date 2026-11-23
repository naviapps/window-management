use super::*;
use window_management::CycleDirection;

#[test]
fn redundant_move_revalidates_the_capture_without_writing() {
    let identity = WindowIdentity {
        handle: 12,
        process: 34,
        thread: 56,
    };
    let frame = Rect {
        width: 10.0,
        height: 20.0,
        ..Rect::default()
    };
    let display = Display {
        frame,
        visible_frame: frame,
        identifier: 1,
        has_identifier: 1,
        is_main: 1,
    };
    let plan = window_management::movement_plan(
        MoveRequest {
            direction: CycleDirection::Next,
            preserves_relative_position: true,
        },
        frame,
        &[display],
        false,
    )
    .unwrap();
    let snapshot = WindowSnapshot {
        identity,
        frame,
        title: "Captured title".into(),
        minimized: false,
        maximized: false,
    };
    for result in [Ok(()), Err(Error::TargetChanged)] {
        let actual = apply_movement(
            snapshot.clone(),
            plan,
            |observed| {
                assert_eq!(observed, identity);
                result
            },
            |_, _| panic!("Redundant move tried to set the frame"),
        );
        match result {
            Ok(()) => {
                let retained = actual.unwrap();
                assert_eq!(retained.identity, identity);
                assert_eq!(retained.frame, frame);
                assert_eq!(retained.title, snapshot.title);
            }
            Err(expected) => assert_eq!(actual.unwrap_err(), expected),
        }
    }
}
