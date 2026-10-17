//! C-style FFI wrapper for use from JNI (Android).
//!
//! Exposes three functions that the JNI wrapper (`qttunnel_jni.c`)
//! calls:
//!
//! - `quick_tunnel_start(port)` → opaque `*mut QuickTunnelCtx`
//! - `quick_tunnel_url(ctx)` → public URL as a null-terminated C string
//! - `quick_tunnel_stop(ctx)` → stop + free the context
//!
//! The context owns a dedicated tokio runtime and the
//! `QuickTunnelHandle` returned by the manager. `quick_tunnel_start`
//! blocks until the tunnel is up (the manager resolves once the
//! first connection is registered with the edge) and then returns.
//!
//! Logs go to `logcat` via `__android_log_write` (tag `qttunnel`),
//! so they show up under `adb logcat -s qttunnel`.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

#[cfg(target_os = "android")]
use std::os::raw::c_int;
use std::ptr;

use tokio::runtime::Runtime;

use crate::manager::{QuickTunnelHandle, QuickTunnelManager};

/// Maximum length we allow for the public URL. Cloudflare's quick
/// tunnel hostnames are well under 128 chars; 512 gives plenty of
/// headroom without letting a corrupted string blow up the JNI side.
const URL_BUF_LEN: usize = 512;

/// Opaque context handed back to Kotlin as a `jlong`.
pub struct QuickTunnelCtx {
    runtime: Runtime,
    handle: Option<QuickTunnelHandle>,
    url_cstr: CString,
}

// ── Android logcat bridge ──────────────────────────────────────────────────

#[cfg(target_os = "android")]
extern "C" {
    fn __android_log_write(prio: c_int, tag: *const c_char, text: *const c_char) -> c_int;
}

#[cfg(target_os = "android")]
fn android_log(msg: &str) {
    const ANDROID_LOG_INFO: c_int = 4;
    if let (Ok(tag), Ok(text)) = (
        CString::new("qttunnel"),
        CString::new(msg.replace('\0', " ")),
    ) {
        unsafe {
            __android_log_write(ANDROID_LOG_INFO, tag.as_ptr(), text.as_ptr());
        }
    }
}

#[cfg(not(target_os = "android"))]
fn android_log(msg: &str) {
    eprintln!("[qttunnel] {msg}");
}

// ── FFI exports ────────────────────────────────────────────────────────────

/// Start a quick tunnel pointing at `127.0.0.1:<port>`.
///
/// Blocks until the tunnel is up (usually 5–15 s, occasionally
/// longer when the DoH resolver has to warm up), then returns an
/// opaque context pointer. Returns null on failure.
///
/// # Safety
/// `port` must be a valid TCP port. The returned pointer must be
/// passed to `quick_tunnel_stop` exactly once.
#[no_mangle]
pub extern "C" fn quick_tunnel_start(port: u16) -> *mut QuickTunnelCtx {
    android_log(&format!("quick_tunnel_start({port}) chiamata"));

    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .worker_threads(2)
        .build()
    {
        Ok(rt) => {
            android_log("Runtime tokio creato");
            rt
        }
        Err(e) => {
            android_log(&format!("ERRORE creazione runtime: {e}"));
            return ptr::null_mut();
        }
    };

    android_log("manager creato, chiamo start()...");
    let manager = QuickTunnelManager::new(port);

    let handle = match runtime.block_on(async move { manager.start().await }) {
        Ok(h) => h,
        Err(e) => {
            android_log(&format!("ERRORE start(): {e}"));
            return ptr::null_mut();
        }
    };

    android_log(&format!("start() OK, url={}", handle.url));

    let url_cstr = match CString::new(handle.url.clone()) {
        Ok(c) => c,
        Err(e) => {
            android_log(&format!("ERRORE CString url: {e}"));
            return ptr::null_mut();
        }
    };

    let ctx = Box::new(QuickTunnelCtx {
        runtime,
        handle: Some(handle),
        url_cstr,
    });

    android_log("ctx creato, ritorno puntatore");
    Box::into_raw(ctx)
}

/// Return the public URL as a null-terminated C string.
///
/// # Safety
/// `ctx` must be a pointer returned by `quick_tunnel_start`, not
/// yet passed to `quick_tunnel_stop`. Returns null if `ctx` is null.
#[no_mangle]
pub extern "C" fn quick_tunnel_url(ctx: *mut QuickTunnelCtx) -> *const c_char {
    if ctx.is_null() {
        return ptr::null();
    }
    let ctx = unsafe { &*ctx };
    ctx.url_cstr.as_ptr()
}

/// Stop the tunnel and free the context.
///
/// # Safety
/// `ctx` must be a pointer returned by `quick_tunnel_start`, and
/// must not be used after this call.
#[no_mangle]
pub extern "C" fn quick_tunnel_stop(ctx: *mut QuickTunnelCtx) {
    if ctx.is_null() {
        return;
    }
    android_log("quick_tunnel_stop chiamata");

    // Reconstitute the Box so it drops at the end of this function.
    let mut boxed = unsafe { Box::from_raw(ctx) };

    // Graceful shutdown on the owned runtime. If it fails or hangs,
    // we still drop the context (Drop on QuickTunnelHandle signals
    // the reactors to wind down).
    if let Some(handle) = boxed.handle.take() {
        let rt = &boxed.runtime;
        let _ = rt.block_on(async move {
            handle.shutdown().await
        });
    }

    android_log("quick_tunnel_stop completata");
    // `boxed` drops here, freeing runtime + url_cstr.
}

/// Free a C string returned by `quick_tunnel_url` (if the caller
/// decides to duplicate it). Provided for API symmetry; the JNI
/// wrapper typically just copies the bytes and doesn't call this.
///
/// # Safety
/// `s` must be a pointer returned by `quick_tunnel_url` (not
/// modified), or null.
#[no_mangle]
pub extern "C" fn quick_tunnel_free_string(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    unsafe {
        let _ = CString::from_raw(s);
    }
}

/// Verify the C string round-trips. Small helper to convince the
/// compiler we actually use `CStr` (avoids an unused import).
#[allow(dead_code)]
fn _touch_cstr(s: &CStr) -> usize {
    s.to_bytes().len()
}

/// URL buffer length constant exposed for the JNI wrapper.
#[no_mangle]
pub extern "C" fn quick_tunnel_url_buf_len() -> usize {
    URL_BUF_LEN
}
