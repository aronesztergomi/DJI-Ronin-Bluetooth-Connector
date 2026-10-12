//! C ABI over the `rs3` library, for the SwiftUI app.
//!
//! Every call is blocking and runs on a runtime owned by the handle, so the
//! Swift side never deals with async. Most calls are cheap (a BLE write is a
//! few hundred microseconds), but [`rs3_connect`] scans for several seconds —
//! call it off the main thread.
//!
//! Functions return `0` on success and a negative [`RS3Status`] otherwise. A
//! null handle is always an error, never a crash.

use std::ffi::{c_char, c_int, c_void};
use std::sync::Arc;
use std::time::Duration;

use rs3::{Direction, Gimbal, Position, Speeds};
use tokio::runtime::Runtime;

/// Status codes shared with Swift.
#[repr(i32)]
pub enum RS3Status {
    Ok = 0,
    NullHandle = -1,
    NotFound = -2,
    Bluetooth = -3,
    Timeout = -4,
    BadArgument = -5,
    Internal = -6,
}

/// Direction codes shared with Swift.
#[repr(i32)]
pub enum RS3Direction {
    Left = 0,
    Right = 1,
    Up = 2,
    Down = 3,
    RollLeft = 4,
    RollRight = 5,
}

pub struct RS3Handle {
    runtime: Runtime,
    gimbal: Arc<Gimbal>,
    keepalive: std::sync::Mutex<Option<rs3::KeepAlive>>,
}

fn status_for(err: &rs3::Error) -> c_int {
    use rs3::Error::*;
    match err {
        NotFound | NotAGimbal | NoAdapter => RS3Status::NotFound as c_int,
        Timeout => RS3Status::Timeout as c_int,
        Bluetooth(_) | NotConnected => RS3Status::Bluetooth as c_int,
        _ => RS3Status::Internal as c_int,
    }
}

fn direction_from(value: c_int) -> Option<Direction> {
    Some(match value {
        0 => Direction::Left,
        1 => Direction::Right,
        2 => Direction::Up,
        3 => Direction::Down,
        4 => Direction::RollLeft,
        5 => Direction::RollRight,
        _ => return None,
    })
}

macro_rules! with_handle {
    ($h:expr, $gimbal:ident, $body:expr) => {{
        let Some(handle) = (unsafe { ($h as *mut RS3Handle).as_ref() }) else {
            return RS3Status::NullHandle as c_int;
        };
        let $gimbal = handle.gimbal.clone();
        match handle.runtime.block_on($body) {
            Ok(_) => RS3Status::Ok as c_int,
            Err(e) => status_for(&e),
        }
    }};
}

/// Scan for a gimbal and connect to the first one found.
///
/// Blocks for up to ~10s. Returns null if none was found or Bluetooth is
/// unavailable. Free the result with [`rs3_disconnect`].
///
/// # Safety
/// The returned pointer must be freed exactly once with [`rs3_disconnect`].
#[no_mangle]
pub extern "C" fn rs3_connect() -> *mut c_void {
    let Ok(runtime) = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
    else {
        return std::ptr::null_mut();
    };
    match runtime.block_on(Gimbal::connect_first()) {
        Ok(gimbal) => Box::into_raw(Box::new(RS3Handle {
            runtime,
            gimbal: Arc::new(gimbal),
            keepalive: std::sync::Mutex::new(None),
        })) as *mut c_void,
        Err(_) => std::ptr::null_mut(),
    }
}

/// Disconnect and free the handle. Safe to call with null.
///
/// # Safety
/// `handle` must come from [`rs3_connect`] and must not be used afterwards.
#[no_mangle]
pub extern "C" fn rs3_disconnect(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    let handle = unsafe { Box::from_raw(handle as *mut RS3Handle) };
    let gimbal = handle.gimbal.clone();
    let _ = handle.runtime.block_on(gimbal.disconnect());
}

/// `1` when the link is up, `0` otherwise.
///
/// # Safety
/// `handle` must be null or a live handle from [`rs3_connect`].
#[no_mangle]
pub extern "C" fn rs3_is_connected(handle: *mut c_void) -> c_int {
    let Some(h) = (unsafe { (handle as *mut RS3Handle).as_ref() }) else {
        return 0;
    };
    let gimbal = h.gimbal.clone();
    c_int::from(h.runtime.block_on(async move { gimbal.is_connected().await }))
}

/// Write the version string into `buf` as NUL-terminated UTF-8.
///
/// # Safety
/// `buf` must be writable for `len` bytes.
#[no_mangle]
pub unsafe extern "C" fn rs3_version(handle: *mut c_void, buf: *mut c_char, len: usize) -> c_int {
    if buf.is_null() || len == 0 {
        return RS3Status::BadArgument as c_int;
    }
    let Some(h) = (unsafe { (handle as *mut RS3Handle).as_ref() }) else {
        return RS3Status::NullHandle as c_int;
    };
    let gimbal = h.gimbal.clone();
    match h.runtime.block_on(async move { gimbal.version().await }) {
        Ok(v) => {
            let text = v.to_string();
            let bytes = text.as_bytes();
            let n = bytes.len().min(len - 1);
            unsafe {
                std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf as *mut u8, n);
                *buf.add(n) = 0;
            }
            RS3Status::Ok as c_int
        }
        Err(e) => status_for(&e),
    }
}

/// Write the gimbal's advertised BLE name into `buf` as NUL-terminated UTF-8.
///
/// # Safety
/// `buf` must be writable for `len` bytes.
#[no_mangle]
pub unsafe extern "C" fn rs3_name(handle: *mut c_void, buf: *mut c_char, len: usize) -> c_int {
    if buf.is_null() || len == 0 {
        return RS3Status::BadArgument as c_int;
    }
    let Some(h) = (unsafe { (handle as *mut RS3Handle).as_ref() }) else {
        return RS3Status::NullHandle as c_int;
    };
    let bytes = h.gimbal.name().as_bytes();
    let n = bytes.len().min(len - 1);
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf as *mut u8, n);
        *buf.add(n) = 0;
    }
    RS3Status::Ok as c_int
}

/// One speed command. Call repeatedly (~10 Hz) to sustain motion.
///
/// # Safety
/// `handle` must be null or a live handle from [`rs3_connect`].
#[no_mangle]
pub extern "C" fn rs3_speed(handle: *mut c_void, yaw: i16, roll: i16, pitch: i16) -> c_int {
    with_handle!(handle, gimbal, async move {
        gimbal.speed(Speeds::new(yaw, roll, pitch)).await
    })
}

/// Zero every axis.
///
/// # Safety
/// `handle` must be null or a live handle from [`rs3_connect`].
#[no_mangle]
pub extern "C" fn rs3_stop(handle: *mut c_void) -> c_int {
    with_handle!(handle, gimbal, async move { gimbal.stop().await })
}

/// Hold a direction for `millis`, then stop. `direction` is [`RS3Direction`].
///
/// # Safety
/// `handle` must be null or a live handle from [`rs3_connect`].
#[no_mangle]
pub extern "C" fn rs3_nudge(
    handle: *mut c_void,
    direction: c_int,
    speed: i16,
    millis: u64,
) -> c_int {
    let Some(dir) = direction_from(direction) else {
        return RS3Status::BadArgument as c_int;
    };
    with_handle!(handle, gimbal, async move {
        gimbal.nudge(dir, speed, Duration::from_millis(millis)).await
    })
}

/// Move toward an absolute attitude, in tenths of a degree.
///
/// # Safety
/// `handle` must be null or a live handle from [`rs3_connect`].
#[no_mangle]
pub extern "C" fn rs3_goto(handle: *mut c_void, yaw: i16, roll: i16, pitch: i16) -> c_int {
    with_handle!(handle, gimbal, async move {
        gimbal.goto(Position::new(yaw, roll, pitch)).await
    })
}

/// Recentre the gimbal.
///
/// # Safety
/// `handle` must be null or a live handle from [`rs3_connect`].
#[no_mangle]
pub extern "C" fn rs3_recenter(handle: *mut c_void) -> c_int {
    with_handle!(handle, gimbal, async move { gimbal.recenter().await })
}

/// Send any recovered command.
///
/// # Safety
/// `payload` must be readable for `payload_len` bytes, or null with length 0.
#[no_mangle]
pub unsafe extern "C" fn rs3_raw(
    handle: *mut c_void,
    cmd_set: u8,
    cmd_id: u8,
    payload: *const u8,
    payload_len: usize,
) -> c_int {
    let body = if payload.is_null() || payload_len == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(payload, payload_len) }.to_vec()
    };
    with_handle!(handle, gimbal, async move {
        gimbal.raw(cmd_set, cmd_id, body).await
    })
}

/// Start a keep-alive probe every `millis` (0 stops it).
///
/// The link has been seen to survive ~30s of silence, so this is belt and
/// braces rather than a requirement — but the DJI app heartbeats every 500ms,
/// and a periodic probe also surfaces a dropped link promptly.
///
/// # Safety
/// `handle` must be null or a live handle from [`rs3_connect`].
#[no_mangle]
pub extern "C" fn rs3_set_keepalive(handle: *mut c_void, millis: u64) -> c_int {
    let Some(h) = (unsafe { (handle as *mut RS3Handle).as_ref() }) else {
        return RS3Status::NullHandle as c_int;
    };
    let Ok(mut slot) = h.keepalive.lock() else {
        return RS3Status::Internal as c_int;
    };
    if millis == 0 {
        *slot = None; // dropping the guard stops the task
        return RS3Status::Ok as c_int;
    }
    let gimbal = h.gimbal.clone();
    let _guard = h.runtime.enter();
    *slot = Some(gimbal.spawn_keepalive(Duration::from_millis(millis)));
    RS3Status::Ok as c_int
}

/// `1` when the most recent keep-alive probe succeeded.
///
/// # Safety
/// `handle` must be null or a live handle from [`rs3_connect`].
#[no_mangle]
pub extern "C" fn rs3_is_healthy(handle: *mut c_void) -> c_int {
    let Some(h) = (unsafe { (handle as *mut RS3Handle).as_ref() }) else {
        return 0;
    };
    match h.keepalive.lock() {
        Ok(slot) => match slot.as_ref() {
            Some(k) => c_int::from(k.is_healthy()),
            None => rs3_is_connected(handle),
        },
        Err(_) => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn null_handles_are_errors_not_crashes() {
        assert_eq!(
            rs3_speed(std::ptr::null_mut(), 0, 0, 0),
            RS3Status::NullHandle as c_int
        );
        assert_eq!(rs3_stop(std::ptr::null_mut()), RS3Status::NullHandle as c_int);
        assert_eq!(rs3_is_connected(std::ptr::null_mut()), 0);
        assert_eq!(rs3_is_healthy(std::ptr::null_mut()), 0);
        assert_eq!(
            rs3_set_keepalive(std::ptr::null_mut(), 500),
            RS3Status::NullHandle as c_int
        );
        rs3_disconnect(std::ptr::null_mut()); // must not panic
    }

    #[test]
    fn rejects_bad_arguments() {
        let mut buf = [0i8; 8];
        unsafe {
            assert_eq!(
                rs3_version(std::ptr::null_mut(), std::ptr::null_mut(), 0),
                RS3Status::BadArgument as c_int
            );
            assert_eq!(
                rs3_version(std::ptr::null_mut(), buf.as_mut_ptr(), buf.len()),
                RS3Status::NullHandle as c_int
            );
        }
        assert_eq!(
            rs3_nudge(std::ptr::null_mut(), 99, 100, 10),
            RS3Status::BadArgument as c_int
        );
    }

    #[test]
    fn direction_codes_match_the_swift_enum() {
        assert!(matches!(direction_from(0), Some(Direction::Left)));
        assert!(matches!(direction_from(3), Some(Direction::Down)));
        assert!(matches!(direction_from(5), Some(Direction::RollRight)));
        assert!(direction_from(6).is_none());
        assert!(direction_from(-1).is_none());
    }
}
