use super::values::Json;
use window_management::{SnapshotFilter, SnapshotIdentityMatch};

/// Immutable selection, safe to query concurrently while its owner remains live.
pub struct WindowFilter(SnapshotFilter);

/// # Safety
/// Bytes must be readable for length. JSON output must be writable and must
/// not overlap input. It receives a separately owned canonical JSON result or
/// diagnostic; the compiled selection is null on rejection.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn window_management_window_filter_compile(
    data: *const u8,
    length: usize,
    json: *mut *mut Json,
) -> *mut WindowFilter {
    if !super::sized_buffer(json.cast_const(), 1) {
        return std::ptr::null_mut();
    }
    let (filter, result) = if length != 0 && super::sized_buffer(data, length) {
        let bytes = unsafe { std::slice::from_raw_parts(data, length) };
        match serde_json::from_slice::<SnapshotFilter>(bytes)
            .and_then(|filter| serde_json::to_vec(&filter).map(|bytes| (filter, bytes)))
        {
            Ok((filter, bytes)) => (Some(filter), Json::from(Ok(bytes))),
            Err(error) => (None, Json::from(Err(error))),
        }
    } else {
        (None, Json::invalid())
    };
    unsafe { json.write(Box::into_raw(Box::new(result))) };
    filter.map_or(std::ptr::null_mut(), |value| {
        Box::into_raw(Box::new(WindowFilter(value)))
    })
}

/// # Safety
/// Filter must remain live during the call. Returns 0 for excluded, 1 for included,
/// 2 for an invalid handle and 3 when application conditions still need evaluation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn window_management_window_filter_match_identity(
    filter: *const WindowFilter,
    window: u64,
    process: i64,
) -> u32 {
    let Some(filter) = (unsafe { filter.as_ref() }) else {
        return 2;
    };
    match filter.0.match_identity(window, process) {
        SnapshotIdentityMatch::Excluded => 0,
        SnapshotIdentityMatch::Included => 1,
        SnapshotIdentityMatch::RequiresApplicationIdentifier => 3,
    }
}

/// # Safety
/// Filter must remain live. Application is null/zero for missing, or readable
/// UTF-8 for length bytes; a nonnull zero-length view is a present empty ID.
/// Returns 1 for included, 0 for excluded and 2 for an invalid handle/view.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn window_management_window_filter_includes(
    filter: *const WindowFilter,
    window: u64,
    process: i64,
    application: *const u8,
    length: usize,
) -> u32 {
    let Some(filter) = (unsafe { filter.as_ref() }) else {
        return 2;
    };
    if length > isize::MAX as usize || (application.is_null() && length != 0) {
        return 2;
    }
    let application = if application.is_null() {
        None
    } else {
        let Ok(value) =
            std::str::from_utf8(unsafe { std::slice::from_raw_parts(application, length) })
        else {
            return 2;
        };
        Some(value)
    };
    u32::from(filter.0.includes(window, process, application))
}

/// # Safety
/// Filter must be null or exclusively owned, with no concurrent queries remaining.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn window_management_window_filter_destroy(filter: *mut WindowFilter) {
    if !filter.is_null() {
        drop(unsafe { Box::from_raw(filter) });
    }
}
