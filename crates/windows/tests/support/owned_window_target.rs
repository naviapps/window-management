use std::{
    env, fs,
    io::{self, Write as _},
    path::PathBuf,
    ptr::{null, null_mut},
};

use windows_sys::{
    Win32::{
        Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM},
        Graphics::{
            Dwm::{DWMWA_CLOAK, DwmSetWindowAttribute},
            Gdi::{
                BeginPaint, COLOR_WINDOW, DT_CALCRECT, DT_CENTER, DT_WORDBREAK, DrawTextW,
                EndPaint, FillRect, HBRUSH, HDC, PAINTSTRUCT, SetBkMode, TRANSPARENT, UpdateWindow,
            },
        },
        UI::{
            HiDpi::{DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetThreadDpiAwarenessContext},
            WindowsAndMessaging::{
                CS_HREDRAW, CS_VREDRAW, CreateWindowExW, DefWindowProcW, DispatchMessageW,
                GetClientRect, GetMessageW, GetWindowThreadProcessId, MINMAXINFO, MSG,
                PostQuitMessage, RegisterClassW, SW_SHOW, SetForegroundWindow, SetTimer,
                ShowWindow, TranslateMessage, WM_DESTROY, WM_GETMINMAXINFO, WM_PAINT,
                WM_PRINTCLIENT, WM_TIMER, WNDCLASSW, WS_OVERLAPPEDWINDOW,
            },
        },
    },
    core::PCWSTR,
};

#[link(name = "kernel32")]
unsafe extern "system" {
    fn GetModuleHandleW(module: PCWSTR) -> HINSTANCE;
}

const CLOAK_TIMER: usize = 1;
const WINDOW_BACKGROUND: HBRUSH = (COLOR_WINDOW + 1) as HBRUSH;

pub fn run() -> io::Result<()> {
    let mut args = env::args_os().skip(1);
    let ready = args
        .next()
        .map(PathBuf::from)
        .filter(|path| path.is_absolute() && path.extension().is_some_and(|ext| ext == "json"))
        .filter(|_| args.next().is_none())
        .ok_or_else(|| io::Error::other("Provide the owned absolute ready JSON path."))?;
    let temporary = ready.with_extension("json.tmp");
    let cloak = ready.with_extension("json.cloak");

    let mut process = 0;
    let (window, thread) = unsafe {
        if SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2).is_null() {
            return Err(io::Error::last_os_error());
        }
        let instance = GetModuleHandleW(null());
        if instance.is_null() {
            return Err(io::Error::last_os_error());
        }
        let class = wide("WindowManagement.OwnedTarget");
        if RegisterClassW(&WNDCLASSW {
            style: CS_HREDRAW | CS_VREDRAW,
            lpfnWndProc: Some(window_proc),
            hInstance: instance,
            hbrBackground: WINDOW_BACKGROUND,
            lpszClassName: class.as_ptr(),
            ..WNDCLASSW::default()
        }) == 0
        {
            return Err(io::Error::last_os_error());
        }
        let title = wide("WindowManagement acceptance — λ 日本");
        let window = CreateWindowExW(
            0,
            class.as_ptr(),
            title.as_ptr(),
            WS_OVERLAPPEDWINDOW,
            80,
            80,
            480,
            360,
            null_mut(),
            null_mut(),
            instance,
            null(),
        );
        if window.is_null() {
            return Err(io::Error::last_os_error());
        }
        ShowWindow(window, SW_SHOW);
        UpdateWindow(window);
        SetForegroundWindow(window);
        let thread = GetWindowThreadProcessId(window, &mut process);
        if thread == 0 || SetTimer(window, CLOAK_TIMER, 25, None) == 0 {
            return Err(io::Error::last_os_error());
        }
        (window, thread)
    };
    {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        write!(
            file,
            "{{\"Handle\":{},\"Process\":{process},\"Thread\":{thread}}}",
            window as usize
        )?;
    }
    // Publish only after the independent window exists and its message loop is ready.
    fs::rename(temporary, ready)?;

    let mut message = MSG::default();
    let mut cloaked = false;
    loop {
        match unsafe { GetMessageW(&mut message, null_mut(), 0, 0) } {
            -1 => return Err(io::Error::last_os_error()),
            0 => return Ok(()),
            _ => {}
        }
        if message.hwnd == window && message.message == WM_TIMER && message.wParam == CLOAK_TIMER {
            let requested = fs::exists(&cloak)?;
            if requested != cloaked {
                let value = i32::from(requested);
                let result = unsafe {
                    DwmSetWindowAttribute(
                        window,
                        DWMWA_CLOAK as u32,
                        (&raw const value).cast(),
                        size_of::<i32>() as u32,
                    )
                };
                if result != 0 {
                    return Err(io::Error::other(format!(
                        "Owned DWM cloak request failed ({result:#010x})."
                    )));
                }
                cloaked = requested;
            }
        } else {
            unsafe {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
    }
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

fn paint(window: HWND, dc: HDC) {
    let mut client = RECT::default();
    let label = wide(
        "Owned native acceptance target\r\nWindow geometry and state are controlled from a separate process.",
    );
    unsafe {
        if dc.is_null() || GetClientRect(window, &mut client) == 0 {
            return;
        }
        FillRect(dc, &client, WINDOW_BACKGROUND);
        SetBkMode(dc, TRANSPARENT as i32);
        let mut text = client;
        let flags = DT_CENTER | DT_WORDBREAK;
        let height = DrawTextW(dc, label.as_ptr(), -1, &mut text, DT_CALCRECT | flags);
        client.top = (client.bottom - height).max(0) / 2;
        DrawTextW(dc, label.as_ptr(), -1, &mut client, flags);
    }
}

unsafe extern "system" fn window_proc(
    window: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match message {
        WM_GETMINMAXINFO => unsafe {
            DefWindowProcW(window, message, wparam, lparam);
            let info = &mut *(lparam as *mut MINMAXINFO);
            info.ptMinTrackSize.x = info.ptMinTrackSize.x.max(160);
            info.ptMinTrackSize.y = info.ptMinTrackSize.y.max(120);
            0
        },
        WM_PAINT => unsafe {
            let mut state = PAINTSTRUCT::default();
            paint(window, BeginPaint(window, &mut state));
            EndPaint(window, &state);
            0
        },
        WM_PRINTCLIENT => {
            paint(window, wparam as HDC);
            0
        }
        WM_DESTROY => {
            unsafe { PostQuitMessage(0) };
            0
        }
        _ => unsafe { DefWindowProcW(window, message, wparam, lparam) },
    }
}
