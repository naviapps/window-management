use crate::coordinates::{frame_coordinate, hit_coordinate};
use std::ptr::{null, null_mut};
use window_management::{Display, MoveRequest, MovementPlan, PlacementRequest, Rect};
use windows_sys::Win32::{
    Foundation::*,
    Graphics::{Dwm::*, Gdi::*},
    UI::{HiDpi::*, WindowsAndMessaging::*},
};

/// Stable native identity checked before every requested operation. HWND reuse within
/// one PID/thread is still possible; validation is best effort, not an atomic guarantee.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WindowIdentity {
    pub handle: u64,
    pub process: u32,
    pub thread: u32,
}
/// Immutable metadata, owning its title independently of later native changes.
#[derive(Debug, Clone)]
pub struct WindowSnapshot {
    pub identity: WindowIdentity,
    pub frame: Rect,
    pub title: String,
    pub minimized: bool,
    pub maximized: bool,
}
/// Native window state. Callers choose a named state, never a Win32/ABI number.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WindowState {
    Normal,
    Minimized,
    Maximized,
}
/// An explicit native failure. Native codes are diagnostic, never permission-grant claims.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    InvalidInput,
    Unavailable,
    TargetChanged,
    Native(u32),
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for Error {}
struct DpiContext(DPI_AWARENESS_CONTEXT);
impl DpiContext {
    fn enter() -> Result<Self, Error> {
        let old =
            unsafe { SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) };
        if old.is_null() {
            Err(native_error())
        } else {
            Ok(Self(old))
        }
    }
}
impl Drop for DpiContext {
    fn drop(&mut self) {
        unsafe {
            SetThreadDpiAwarenessContext(self.0);
        }
    }
}
fn native_error() -> Error {
    Error::Native(unsafe { GetLastError() })
}
fn identity(hwnd: HWND) -> Result<WindowIdentity, Error> {
    let mut process = 0;
    let thread = unsafe { GetWindowThreadProcessId(hwnd, &mut process) };
    if thread == 0 || process == 0 {
        return Err(Error::Unavailable);
    }
    Ok(WindowIdentity {
        handle: hwnd as usize as u64,
        process,
        thread,
    })
}
fn input_handle(value: WindowIdentity) -> Result<HWND, Error> {
    let hwnd = value.handle as usize as HWND;
    if hwnd.is_null()
        || hwnd as usize as u64 != value.handle
        || value.process == 0
        || value.thread == 0
    {
        return Err(Error::InvalidInput);
    }
    Ok(hwnd)
}
fn verify_identity(hwnd: HWND, expected: WindowIdentity) -> Result<(), Error> {
    if identity(hwnd) != Ok(expected) {
        Err(Error::TargetChanged)
    } else {
        Ok(())
    }
}
fn checked(value: WindowIdentity) -> Result<HWND, Error> {
    let hwnd = input_handle(value)?;
    verify_identity(hwnd, value)?;
    Ok(hwnd)
}
fn window_failure(hwnd: HWND, expected: WindowIdentity) -> Error {
    let error = native_error();
    verify_identity(hwnd, expected).err().unwrap_or(error)
}
fn snapshot(hwnd: HWND, expected: Option<WindowIdentity>) -> Result<WindowSnapshot, Error> {
    snapshot_at(hwnd, expected, None)?.ok_or(Error::Unavailable)
}

fn snapshot_at(
    hwnd: HWND,
    expected: Option<WindowIdentity>,
    point: Option<(f64, f64)>,
) -> Result<Option<WindowSnapshot>, Error> {
    let identity = match expected {
        Some(expected) => {
            verify_identity(hwnd, expected)?;
            expected
        }
        None => identity(hwnd)?,
    };
    let mut rect = RECT::default();
    if unsafe { GetWindowRect(hwnd, &mut rect) } == 0 {
        return Err(window_failure(hwnd, identity));
    }
    let frame = Rect {
        x: rect.left as f64,
        y: rect.top as f64,
        width: (rect.right as i64 - rect.left as i64) as f64,
        height: (rect.bottom as i64 - rect.top as i64) as f64,
    };
    if point.is_some_and(|(x, y)| !frame.contains(x, y) || unsafe { IsIconic(hwnd) } != 0) {
        return Ok(None);
    }
    let length = unsafe { GetWindowTextLengthW(hwnd) }.clamp(0, 32767) as usize;
    let mut title = vec![0_u16; length + 1];
    let used =
        unsafe { GetWindowTextW(hwnd, title.as_mut_ptr(), title.len() as i32) }.max(0) as usize;
    let result = WindowSnapshot {
        identity,
        frame,
        title: String::from_utf16_lossy(&title[..used]),
        minimized: unsafe { IsIconic(hwnd) } != 0,
        maximized: unsafe { IsZoomed(hwnd) } != 0,
    };
    verify_identity(hwnd, identity)?;
    Ok((point.is_none() || !result.minimized).then_some(result))
}
/// Enumerate visible top-level windows in native z order, excluding tool and DWM-cloaked windows.
/// Windows invalidated during enumeration are skipped; failure to enumerate is reported.
pub fn windows() -> Result<Vec<WindowSnapshot>, Error> {
    enumerate_windows(None)
}

/// Enumerate non-minimized visible top-level windows whose bounds contain a physical point.
/// Results retain native z order. Bounds do not model a window's input region.
pub fn windows_at(x: f64, y: f64) -> Result<Vec<WindowSnapshot>, Error> {
    let (Some(x), Some(y)) = (hit_coordinate(x), hit_coordinate(y)) else {
        return Ok(Vec::new());
    };
    enumerate_windows(Some((f64::from(x), f64::from(y))))
}

fn enumerate_windows(point: Option<(f64, f64)>) -> Result<Vec<WindowSnapshot>, Error> {
    struct Enumeration {
        point: Option<(f64, f64)>,
        windows: Vec<WindowSnapshot>,
    }

    let _dpi = DpiContext::enter()?;
    let mut state = Enumeration {
        point,
        windows: Vec::new(),
    };
    unsafe extern "system" fn collect(hwnd: HWND, data: LPARAM) -> i32 {
        let mut cloaked = 0_u32;
        let cloak_known = unsafe {
            DwmGetWindowAttribute(
                hwnd,
                DWMWA_CLOAKED as u32,
                &mut cloaked as *mut _ as *mut _,
                std::mem::size_of::<u32>() as u32,
            )
        } >= 0;
        if unsafe { IsWindowVisible(hwnd) } != 0
            && unsafe { GetWindowLongPtrW(hwnd, GWL_EXSTYLE) } as u32 & WS_EX_TOOLWINDOW == 0
            && !(cloak_known && cloaked != 0)
        {
            let state = unsafe { &mut *(data as *mut Enumeration) };
            if let Ok(Some(value)) = snapshot_at(hwnd, None, state.point) {
                state.windows.push(value);
            }
        }
        1
    }
    if unsafe { EnumWindows(Some(collect), &mut state as *mut _ as LPARAM) } == 0 {
        return Err(native_error());
    }
    Ok(state.windows)
}
/// Query a known window only while its captured PID/thread match before and after sampling.
pub fn window(value: WindowIdentity) -> Result<WindowSnapshot, Error> {
    let _dpi = DpiContext::enter()?;
    snapshot(input_handle(value)?, Some(value))
}
/// Capture the foreground window's identity without reading window metadata or changing DPI context.
/// No foreground owner returns `Unavailable`. A change of foreground window during capture
/// returns `TargetChanged`.
pub fn foreground_window_identity() -> Result<WindowIdentity, Error> {
    let hwnd = unsafe { GetForegroundWindow() };
    if hwnd.is_null() {
        return Err(Error::Unavailable);
    }
    let owner = identity(hwnd);
    if unsafe { GetForegroundWindow() } != hwnd {
        return Err(Error::TargetChanged);
    }
    owner
}
/// Capture the foreground window's current identity without activating anything.
pub fn foreground_window() -> Result<WindowSnapshot, Error> {
    let _dpi = DpiContext::enter()?;
    snapshot(unsafe { GetForegroundWindow() }, None)
}
/// Resolve the root native window at a physical virtual-desktop point.
/// Fractional coordinates sample the pixel containing the point, including at negative origins.
pub fn window_at(x: f64, y: f64) -> Result<WindowSnapshot, Error> {
    let _dpi = DpiContext::enter()?;
    let point = POINT {
        x: hit_coordinate(x).ok_or(Error::InvalidInput)?,
        y: hit_coordinate(y).ok_or(Error::InvalidInput)?,
    };
    let hwnd = unsafe { WindowFromPoint(point) };
    if hwnd.is_null() {
        return Err(Error::Unavailable);
    }
    snapshot(unsafe { GetAncestor(hwnd, GA_ROOT) }, None)
}
/// Enumerate full/usable monitor areas without changing global DPI settings.
pub fn displays() -> Result<Vec<Display>, Error> {
    let _dpi = DpiContext::enter()?;
    let mut values = Vec::new();
    unsafe extern "system" fn collect(
        monitor: HMONITOR,
        _: HDC,
        _: *mut RECT,
        data: LPARAM,
    ) -> i32 {
        let mut info = MONITORINFO {
            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        if unsafe { GetMonitorInfoW(monitor, &mut info) } != 0 {
            let rect = |r: RECT| Rect {
                x: r.left as f64,
                y: r.top as f64,
                width: (r.right as i64 - r.left as i64) as f64,
                height: (r.bottom as i64 - r.top as i64) as f64,
            };
            unsafe { &mut *(data as *mut Vec<Display>) }.push(Display {
                frame: rect(info.rcMonitor),
                visible_frame: rect(info.rcWork),
                identifier: monitor as usize as u64,
                has_identifier: 1,
                is_main: u32::from(info.dwFlags & MONITORINFOF_PRIMARY != 0),
            });
        }
        1
    }
    if unsafe {
        EnumDisplayMonitors(
            null_mut(),
            null(),
            Some(collect),
            &mut values as *mut _ as LPARAM,
        )
    } == 0
    {
        return Err(native_error());
    }
    if values.is_empty() {
        return Err(Error::Unavailable);
    }
    Ok(values)
}
/// Set a finite frame while retaining activation and z order. Returns the actual
/// native frame, which can differ when an application imposes size constraints.
pub fn set_frame(value: WindowIdentity, frame: Rect) -> Result<WindowSnapshot, Error> {
    let _dpi = DpiContext::enter()?;
    let hwnd = checked(value)?;
    if frame.width < 0.0 || frame.height < 0.0 {
        return Err(Error::InvalidInput);
    }
    let (x, y, w, h) = (
        frame_coordinate(frame.x).ok_or(Error::InvalidInput)?,
        frame_coordinate(frame.y).ok_or(Error::InvalidInput)?,
        frame_coordinate(frame.width).ok_or(Error::InvalidInput)?,
        frame_coordinate(frame.height).ok_or(Error::InvalidInput)?,
    );
    if unsafe { SetWindowPos(hwnd, null_mut(), x, y, w, h, SWP_NOZORDER | SWP_NOACTIVATE) } == 0 {
        return Err(window_failure(hwnd, value));
    }
    window(value)
}
/// Place a captured window using the same request resolution as other adapters.
pub fn place(
    value: WindowIdentity,
    request: PlacementRequest,
    fallback: bool,
) -> Result<WindowSnapshot, Error> {
    let current = window(value)?;
    let displays = displays()?;
    let frame = window_management::placement_frame(request, current.frame, &displays, fallback)
        .ok_or(Error::Unavailable)?;
    set_frame(value, frame)
}
/// Move a captured window between displays without changing the global DPI context.
pub fn move_to_adjacent_display(
    value: WindowIdentity,
    request: MoveRequest,
    fallback: bool,
) -> Result<WindowSnapshot, Error> {
    let current = window(value)?;
    let displays = displays()?;
    let plan = window_management::movement_plan(request, current.frame, &displays, fallback)
        .ok_or(Error::Unavailable)?;
    apply_movement(
        current,
        plan,
        |identity| checked(identity).map(|_| ()),
        set_frame,
    )
}

fn apply_movement(
    current: WindowSnapshot,
    plan: MovementPlan,
    revalidate: impl FnOnce(WindowIdentity) -> Result<(), Error>,
    write_frame: impl FnOnce(WindowIdentity, Rect) -> Result<WindowSnapshot, Error>,
) -> Result<WindowSnapshot, Error> {
    let Some(frame) = plan.frame_to_write(current.frame) else {
        revalidate(current.identity)?;
        return Ok(current);
    };
    write_frame(current.identity, frame)
}

#[cfg(test)]
#[path = "movement_tests.rs"]
mod movement_tests;
/// Request minimize, maximize or restore using native placement behavior.
/// Native placement state is read back instead of treating request acceptance as completed UI work.
/// Request a native state change and sample its immediate result. Callers that
/// need to observe completion must query the window again after asynchronous UI work.
pub fn set_state(value: WindowIdentity, state: WindowState) -> Result<WindowSnapshot, Error> {
    let _dpi = DpiContext::enter()?;
    let hwnd = checked(value)?;
    let mut placement = WINDOWPLACEMENT {
        length: std::mem::size_of::<WINDOWPLACEMENT>() as u32,
        ..Default::default()
    };
    if unsafe { GetWindowPlacement(hwnd, &mut placement) } == 0 {
        return Err(window_failure(hwnd, value));
    }
    placement.showCmd = match state {
        WindowState::Normal => SW_SHOWNOACTIVATE as u32,
        WindowState::Minimized => SW_SHOWMINNOACTIVE as u32,
        WindowState::Maximized => SW_SHOWMAXIMIZED as u32,
    };
    verify_identity(hwnd, value)?;
    if unsafe { SetWindowPlacement(hwnd, &placement) } == 0 {
        return Err(window_failure(hwnd, value));
    }
    window(value)
}

/// Post an ordinary close request after checking native identity. Success means
/// accepted by the native queue, not that the application closed or saved data.
pub fn request_close(value: WindowIdentity) -> Result<(), Error> {
    let hwnd = checked(value)?;
    if unsafe { PostMessageW(hwnd, WM_CLOSE, 0, 0) } == 0 {
        Err(window_failure(hwnd, value))
    } else {
        Ok(())
    }
}
