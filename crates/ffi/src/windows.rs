//! Windows desktop results with explicit unsupported status for other operating systems.
use std::ptr::null;
use window_management::{Display, Rect};
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Identity {
    pub handle: u64,
    pub process: u32,
    pub thread: u32,
}
#[cfg(windows)]
impl From<window_management_windows::WindowIdentity> for Identity {
    fn from(value: window_management_windows::WindowIdentity) -> Self {
        Self {
            handle: value.handle,
            process: value.process,
            thread: value.thread,
        }
    }
}
#[repr(C)]
pub struct IdentityResult {
    pub code: u32,
    pub native_error: u32,
    pub identity: Identity,
}
#[repr(C)]
pub struct WindowView {
    pub identity: Identity,
    pub frame: Rect,
    pub title: *const u8,
    pub title_length: usize,
    pub minimized: u32,
    pub maximized: u32,
}
struct Window {
    identity: Identity,
    frame: Rect,
    title: String,
    minimized: bool,
    maximized: bool,
}
/// Owned query result. Destroy it exactly once; copy borrowed views before destruction.
pub struct Query {
    code: u32,
    native_error: u32,
    windows: Vec<Window>,
    displays: Vec<Display>,
}
#[repr(C)]
pub struct QueryView {
    /// Status: 0 success, 1 unsupported OS, 2 invalid input, 3 unavailable,
    /// 4 target identity changed, 5 native failure.
    pub code: u32,
    /// GetLastError value for native failures.
    pub native_error: u32,
    pub count: usize,
    pub displays: *const Display,
    pub display_count: usize,
}
impl Query {
    fn failed(code: u32, native_error: u32) -> Self {
        Self {
            code,
            native_error,
            windows: vec![],
            displays: vec![],
        }
    }
    #[cfg(windows)]
    fn windows(
        result: Result<
            Vec<window_management_windows::WindowSnapshot>,
            window_management_windows::Error,
        >,
    ) -> Self {
        match result {
            Ok(values) => Self {
                code: 0,
                native_error: 0,
                windows: values
                    .into_iter()
                    .map(|w| Window {
                        identity: w.identity.into(),
                        frame: w.frame,
                        title: w.title,
                        minimized: w.minimized,
                        maximized: w.maximized,
                    })
                    .collect(),
                displays: vec![],
            },
            Err(e) => Self::error(e),
        }
    }
    #[cfg(windows)]
    fn error(error: window_management_windows::Error) -> Self {
        let (code, native_error) = error_status(error);
        Self::failed(code, native_error)
    }
}
#[cfg(windows)]
fn error_status(error: window_management_windows::Error) -> (u32, u32) {
    use window_management_windows::Error;
    match error {
        Error::InvalidInput => (2, 0),
        Error::Unavailable => (3, 0),
        Error::TargetChanged => (4, 0),
        Error::Native(code) => (5, code),
    }
}
/// Capture the foreground HWND, process and thread without reading window metadata.
/// Status: 0 success, 1 unsupported OS, 3 unavailable owner, 4 foreground changed.
/// Identity is zeroed on failure. The returned value needs no destruction.
#[unsafe(no_mangle)]
pub extern "C" fn window_management_windows_foreground_identity() -> IdentityResult {
    #[cfg(windows)]
    let result = match window_management_windows::foreground_window_identity() {
        Ok(identity) => IdentityResult {
            code: 0,
            native_error: 0,
            identity: identity.into(),
        },
        Err(error) => {
            let (code, native_error) = error_status(error);
            IdentityResult {
                code,
                native_error,
                identity: Identity::default(),
            }
        }
    };
    #[cfg(not(windows))]
    let result = IdentityResult {
        code: 1,
        native_error: 0,
        identity: Identity::default(),
    };
    result
}
/// Return an owned query. Kinds: 0 visible windows, 1 foreground, 2 known identity,
/// 3 root window at a physical point, 4 visible non-minimized bounds containing a
/// physical point in native z order. Physical-point queries sample the pixel containing
/// the fractional coordinates. For kind 4, an invalid point yields zero results.
#[unsafe(no_mangle)]
pub extern "C" fn window_management_windows_query(
    kind: u32,
    identity: Identity,
    x: f64,
    y: f64,
) -> *mut Query {
    #[cfg(windows)]
    let result = {
        use window_management_windows as win;
        let value = win::WindowIdentity {
            handle: identity.handle,
            process: identity.process,
            thread: identity.thread,
        };
        Query::windows(match kind {
            0 => win::windows(),
            1 => win::foreground_window().map(|w| vec![w]),
            2 => win::window(value).map(|w| vec![w]),
            3 => win::window_at(x, y).map(|w| vec![w]),
            4 => win::windows_at(x, y),
            _ => Err(win::Error::InvalidInput),
        })
    };
    #[cfg(not(windows))]
    let result = {
        let _ = (kind, identity, x, y);
        Query::failed(1, 0)
    };
    Box::into_raw(Box::new(result))
}
#[unsafe(no_mangle)]
pub extern "C" fn window_management_windows_displays() -> *mut Query {
    #[cfg(windows)]
    let result = match window_management_windows::displays() {
        Ok(displays) => Query {
            code: 0,
            native_error: 0,
            windows: vec![],
            displays,
        },
        Err(e) => Query::error(e),
    };
    #[cfg(not(windows))]
    let result = Query::failed(1, 0);
    Box::into_raw(Box::new(result))
}
/// Execute a command and return an owned result. Operations: 0 set frame, 1 restore,
/// 2 minimize, 3 maximize, 4 post close request.
/// Native identity is rechecked, but handle reuse is not atomically prevented.
#[unsafe(no_mangle)]
pub extern "C" fn window_management_windows_command(
    identity: Identity,
    operation: u32,
    frame: Rect,
) -> *mut Query {
    #[cfg(windows)]
    let result = {
        use window_management_windows as win;
        let value = win::WindowIdentity {
            handle: identity.handle,
            process: identity.process,
            thread: identity.thread,
        };
        Query::windows(match operation {
            0 => win::set_frame(value, frame).map(|w| vec![w]),
            1..=3 => {
                let state = match operation {
                    1 => win::WindowState::Normal,
                    2 => win::WindowState::Minimized,
                    _ => win::WindowState::Maximized,
                };
                win::set_state(value, state).map(|w| vec![w])
            }
            4 => win::request_close(value).map(|_| vec![]),
            _ => Err(win::Error::InvalidInput),
        })
    };
    #[cfg(not(windows))]
    let result = {
        let _ = (identity, operation, frame);
        Query::failed(1, 0)
    };
    Box::into_raw(Box::new(result))
}
/// Apply a shared JSON request and return an owned result. Kinds: 0 placement request,
/// 1 move request. Nonzero fallback permits the first ordered display. Native identity
/// is rechecked before setting a frame.
///
/// # Safety
/// Nonempty input must be readable for length bytes. No storage is retained.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn window_management_windows_request(
    identity: Identity,
    kind: u32,
    data: *const u8,
    length: usize,
    fallback: u32,
) -> *mut Query {
    #[cfg(windows)]
    let result = {
        use window_management_windows as win;
        let value = win::WindowIdentity {
            handle: identity.handle,
            process: identity.process,
            thread: identity.thread,
        };
        if data.is_null() || length == 0 || length > isize::MAX as usize {
            Query::failed(2, 0)
        } else {
            let bytes = unsafe { std::slice::from_raw_parts(data, length) };
            Query::windows(match kind {
                0 => serde_json::from_slice::<window_management::PlacementRequest>(bytes)
                    .map_err(|_| win::Error::InvalidInput)
                    .and_then(|r| win::place(value, r, fallback != 0))
                    .map(|w| vec![w]),
                1 => serde_json::from_slice::<window_management::MoveRequest>(bytes)
                    .map_err(|_| win::Error::InvalidInput)
                    .and_then(|r| win::move_to_adjacent_display(value, r, fallback != 0))
                    .map(|w| vec![w]),
                _ => Err(win::Error::InvalidInput),
            })
        }
    };
    #[cfg(not(windows))]
    let result = {
        let _ = (identity, kind, data, length, fallback);
        Query::failed(1, 0)
    };
    Box::into_raw(Box::new(result))
}
/// # Safety
/// Query must be null or immutable/live. All returned views borrow it until destruction.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn window_management_windows_query_view(query: *const Query) -> QueryView {
    unsafe { query.as_ref() }.map_or(
        QueryView {
            code: 2,
            native_error: 0,
            count: 0,
            displays: null(),
            display_count: 0,
        },
        |q| QueryView {
            code: q.code,
            native_error: q.native_error,
            count: q.windows.len(),
            displays: q.displays.as_ptr(),
            display_count: q.displays.len(),
        },
    )
}
/// # Safety
/// Query must be null or immutable/live. Returned UTF-8 title borrows its query.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn window_management_windows_query_window(
    query: *const Query,
    index: usize,
) -> WindowView {
    unsafe { query.as_ref() }
        .and_then(|q| q.windows.get(index))
        .map_or(
            WindowView {
                identity: Identity {
                    handle: 0,
                    process: 0,
                    thread: 0,
                },
                frame: Rect::default(),
                title: null(),
                title_length: 0,
                minimized: 0,
                maximized: 0,
            },
            |w| WindowView {
                identity: w.identity,
                frame: w.frame,
                title: w.title.as_ptr(),
                title_length: w.title.len(),
                minimized: u32::from(w.minimized),
                maximized: u32::from(w.maximized),
            },
        )
}
/// # Safety
/// Query must be null or exclusively owned and destroyed exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn window_management_windows_query_destroy(query: *mut Query) {
    if !query.is_null() {
        drop(unsafe { Box::from_raw(query) })
    }
}
