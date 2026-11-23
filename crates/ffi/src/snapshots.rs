use window_management::{SnapshotFilter, SnapshotIdentityMatch};

/// Immutable selection, safe to query concurrently while its owner remains live.
pub struct WindowFilter(SnapshotFilter);

/// # Safety
/// Bytes must be readable for length. Construction copies all configuration;
/// invalid/unknown/duplicate JSON fields return null without native OS effects.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn window_management_window_filter_create(
    data: *const u8,
    length: usize,
) -> *mut WindowFilter {
    if data.is_null() || length == 0 || length > isize::MAX as usize {
        return std::ptr::null_mut();
    }
    let Ok(value) = serde_json::from_slice(unsafe { std::slice::from_raw_parts(data, length) })
    else {
        return std::ptr::null_mut();
    };
    Box::into_raw(Box::new(WindowFilter(value)))
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
