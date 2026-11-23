// The shipped cdylib has no rlib for an integration test. Compile the same
// sources into the harness and exercise the C entry points as a consumer.
#[path = "../src/lib.rs"]
mod ffi;

use std::ffi::c_void;
use std::ptr;

#[repr(C)]
struct JsonView {
    code: u32,
    data: *const u8,
    length: usize,
}

unsafe extern "C" {
    fn window_management_value_json(kind: u32, input: *const u8, length: usize) -> *mut c_void;
    fn window_management_json_view(owner: *const c_void) -> JsonView;
    fn window_management_json_destroy(owner: *mut c_void);
    fn window_management_window_filter_compile(
        input: *const u8,
        length: usize,
        json_out: *mut *mut c_void,
    ) -> *mut c_void;
    fn window_management_window_filter_match_identity(
        owner: *const c_void,
        window: u64,
        process: i64,
    ) -> u32;
    fn window_management_window_filter_destroy(owner: *mut c_void);
}

struct OwnedJson(*mut c_void);

impl OwnedJson {
    fn parse(kind: u32, input: &[u8]) -> Self {
        Self::new(unsafe { window_management_value_json(kind, input.as_ptr(), input.len()) })
    }

    fn new(raw: *mut c_void) -> Self {
        assert!(!raw.is_null());
        Self(raw)
    }

    fn result(&self) -> (u32, &[u8]) {
        let view = unsafe { window_management_json_view(self.0) };
        assert!(!view.data.is_null() && view.length > 0);
        // The returned slice borrows the live owner.
        let bytes = unsafe { std::slice::from_raw_parts(view.data, view.length) };
        (view.code, bytes)
    }
}

impl Drop for OwnedJson {
    fn drop(&mut self) {
        unsafe { window_management_json_destroy(self.0) }
    }
}

struct OwnedFilter(*mut c_void);

impl OwnedFilter {
    fn compile(input: &[u8]) -> (Option<Self>, OwnedJson) {
        let mut json = ptr::null_mut();
        let owner = unsafe {
            window_management_window_filter_compile(input.as_ptr(), input.len(), &mut json)
        };
        (
            (!owner.is_null()).then(|| Self(owner)),
            OwnedJson::new(json),
        )
    }
}

impl Drop for OwnedFilter {
    fn drop(&mut self) {
        unsafe { window_management_window_filter_destroy(self.0) }
    }
}

const DISPLAY: &str = r#"{"kind":"point","x":-0.0,"y":5e-324}"#;

#[test]
fn copied_json_round_trips_after_the_input_and_owner_are_released() {
    assert_eq!(ffi::window_management_abi_version(), 6);
    let retained = OwnedJson::parse(1, DISPLAY.as_bytes());
    for (kind, input, canonical) in [
        (
            0,
            r#"{"kind":"grid","columns":0,"rows":2,"column":-1,"row":9,"columnSpan":9,"rowSpan":0}"#,
            r#"{"kind":"grid","columns":1,"rows":2,"column":0,"row":1,"columnSpan":1,"rowSpan":1}"#,
        ),
        (1, DISPLAY, DISPLAY),
        (
            2,
            r#"{"placement":{"kind":"fill"}}"#,
            r#"{"placement":{"kind":"fill"},"screen":{"kind":"containing-window"},"area":"visible","inset":0.0}"#,
        ),
        (
            3,
            r#"{"direction":"previous"}"#,
            r#"{"direction":"previous","preservesRelativePosition":true}"#,
        ),
    ] {
        for _ in 0..200 {
            let mut input = input.as_bytes().to_vec();
            let owner = OwnedJson::parse(kind, &input);
            input.fill(b'Z');
            drop(input);
            assert_eq!(owner.result(), (0, canonical.as_bytes()), "kind {kind}");
            let copy = owner.result().1.to_vec();
            drop(owner);

            let reparsed = OwnedJson::parse(kind, &copy);
            assert_eq!(reparsed.result(), (0, copy.as_slice()), "kind {kind}");
            assert_eq!(retained.result(), (0, DISPLAY.as_bytes()));
        }
    }
}

#[test]
fn invalid_json_returns_owned_utf8_diagnostics_without_disturbing_live_results() {
    let retained = OwnedJson::parse(1, DISPLAY.as_bytes());
    let invalid = [
        (
            0,
            br#"{"kind":"fill","kind":"fill"}"#.as_slice(),
            "duplicate field",
        ),
        (
            1,
            br#"{"kind":"point","x":0,"y":0,"extra":true}"#.as_slice(),
            "unknown field",
        ),
        (
            2,
            br#"{"placement":{"kind":"fill","extra":0}}"#.as_slice(),
            "unknown field",
        ),
        (
            3,
            br#"{"direction":"next","preservesRelativePosition":null}"#.as_slice(),
            "expected a boolean",
        ),
        (4, b"{}", "Invalid window JSON input or kind."),
        (2, b"", "Invalid window JSON input or kind."),
    ];
    for (kind, input, expected) in invalid {
        let failure = OwnedJson::parse(kind, input);
        let (status, bytes) = failure.result();
        assert_eq!(status, 1, "kind {kind}");
        let diagnostic = std::str::from_utf8(bytes).unwrap();
        assert!(diagnostic.contains(expected), "kind {kind}: {diagnostic}");
        drop(failure);
        assert_eq!(retained.result(), (0, DISPLAY.as_bytes()));
    }
    unsafe {
        let failure = OwnedJson::new(window_management_value_json(2, ptr::null(), 0));
        assert_eq!(
            failure.result(),
            (1, b"Invalid window JSON input or kind.".as_slice())
        );
        let missing = window_management_json_view(ptr::null());
        assert_eq!(missing.code, 1);
        assert!(missing.data.is_null());
        assert_eq!(missing.length, 0);
        window_management_json_destroy(ptr::null_mut());
    }
}

#[test]
fn compiled_filter_and_canonical_json_have_independent_owners() {
    let mut input =
        br#"{"includedOwnerApplicationIdentifiers":["\u00e9","e\u0301",""],"includedWindowIdentifiers":[18446744073709551615,0]}"#
            .to_vec();
    let (filter, json) = OwnedFilter::compile(&input);
    input.fill(b'Z');
    drop(input);
    drop(filter.unwrap());

    let canonical = concat!(
        r#"{"includedOwnerApplicationIdentifiers":["","é","é"],"#,
        r#""includedOwnerProcessIdentifiers":[],"includedWindowIdentifiers":[0,18446744073709551615],"#,
        r#""excludedOwnerApplicationIdentifiers":[],"excludedOwnerProcessIdentifiers":[],"excludedWindowIdentifiers":[]}"#,
    );
    assert_eq!(json.result(), (0, canonical.as_bytes()));
    let copied = json.result().1.to_vec();
    drop(json);
    let (filter, json) = OwnedFilter::compile(&copied);
    let filter = filter.unwrap();
    assert_eq!(json.result(), (0, copied.as_slice()));
    drop(json);
    assert_eq!(
        unsafe { window_management_window_filter_match_identity(filter.0, u64::MAX, 12) },
        3
    );
    assert_eq!(
        unsafe { window_management_window_filter_match_identity(filter.0, 42, 12) },
        0
    );
}

#[test]
fn malformed_filter_returns_only_an_owned_utf8_diagnostic() {
    for (input, expected) in [
        (
            b"{\"includedOwnerApplicationIdentifiers\":[\"\xff\"]}".as_slice(),
            "invalid unicode code point",
        ),
        (
            br#"{"includedWindowIdentifiers":[1],"includedWindowIdentifiers":[2]}"#.as_slice(),
            "duplicate field",
        ),
        (br#"{"unknown":true}"#.as_slice(), "unknown field"),
    ] {
        let (filter, failed) = OwnedFilter::compile(input);
        assert!(filter.is_none());
        let (status, bytes) = failed.result();
        assert_eq!(status, 1);
        assert!(std::str::from_utf8(bytes).unwrap().contains(expected));
    }
}

#[test]
fn point_lookup_uses_ordered_indices_and_direct_selection_uses_caller_slots() {
    use window_management::{Display, Rect};

    let display = |x| Display {
        frame: Rect {
            x,
            y: 0.0,
            width: 100.0,
            height: 80.0,
        },
        visible_frame: Rect::default(),
        identifier: 0,
        has_identifier: 0,
        is_main: 0,
    };
    let displays = [display(100.0), display(0.0)];
    for (x, y, ordered_index, caller_slot) in [
        (-0.0, 0.0, 0, 1),
        (50.0, 10.0, 0, 1),
        (100.0, 10.0, 1, 0),
        (150.0, 10.0, 1, 0),
        (200.0, 10.0, -1, -1),
        (50.0, 80.0, -1, -1),
        (50.0, -f64::MIN_POSITIVE, -1, -1),
        (f64::NAN, 10.0, -1, -1),
        (50.0, f64::INFINITY, -1, -1),
        (f64::NEG_INFINITY, 10.0, -1, -1),
    ] {
        assert_eq!(
            unsafe {
                ffi::window_management_display_index_containing_point(
                    displays.as_ptr(),
                    displays.len(),
                    x,
                    y,
                )
            },
            ordered_index,
            "point lookup at ({x}, {y})"
        );
        assert_eq!(
            unsafe {
                ffi::window_management_display_select(
                    displays.as_ptr(),
                    displays.len(),
                    2,
                    Rect::default(),
                    x,
                    y,
                    0,
                    0,
                    0,
                )
            },
            caller_slot,
            "direct point selection at ({x}, {y})"
        );
    }
    assert_eq!(
        unsafe { ffi::window_management_display_index_containing_point(ptr::null(), 0, 0.0, 0.0) },
        -1
    );
}
