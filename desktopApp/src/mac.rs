use block2::RcBlock;
use objc2::MainThreadMarker;
use objc2_app_kit::{NSEvent, NSEventMask, NSEventModifierFlags, NSWindow, NSWindowButton};
use tauri::Emitter;

pub fn traffic_lights(window: tauri::WebviewWindow, visible: bool) {
    let _ = window.clone().run_on_main_thread(move || {
        let Some(mtm) = MainThreadMarker::new() else { return };
        let Ok(ptr) = window.ns_window() else { return };
        let window = unsafe { &*(ptr as *const NSWindow) };
        for kind in [NSWindowButton::CloseButton, NSWindowButton::MiniaturizeButton, NSWindowButton::ZoomButton] {
            if let Some(button) = window.standardWindowButton(kind) { button.setHidden(!visible); }
        }
        let _ = mtm;
    });
}

pub fn watch_scroll(window: &tauri::WebviewWindow) {
    traffic_lights(window.clone(), false);
    let handle = window.clone();
    let handler = RcBlock::new(move |event: std::ptr::NonNull<NSEvent>| -> *mut NSEvent {
        let event = event.as_ptr();
        let Some(mtm) = MainThreadMarker::new() else { return event };
        let event_ref = unsafe { &*event };
        let Ok(ptr) = handle.ns_window() else { return event };
        if event_ref.window(mtm).as_ref().map(|w| &**w as *const NSWindow as usize) != Some(ptr as usize) || event_ref.modifierFlags().contains(NSEventModifierFlags::Control) || !event_ref.hasPreciseScrollingDeltas() { return event; }
        let native = unsafe { &*(ptr as *const NSWindow) };
        let location = event_ref.locationInWindow();
        let height = native.contentView().map(|v| v.frame().size.height).unwrap_or_default();
        let direction = if event_ref.isDirectionInvertedFromDevice() { 1. } else { -1. };
        let _ = handle.emit("scroll-phase", serde_json::json!({
            "phase": event_ref.phase().0, "momentum": event_ref.momentumPhase().0,
            "dx": event_ref.scrollingDeltaX() * direction, "dy": event_ref.scrollingDeltaY(),
            "x": location.x, "y": height - location.y
        }));
        event
    });
    // AppKit retains the block for the life of this process's event monitor.
    let _monitor = unsafe { NSEvent::addLocalMonitorForEventsMatchingMask_handler(NSEventMask::ScrollWheel, &handler) };
}

unsafe extern "C" {
    fn tw_desktop_hover_buttons(window: *mut std::ffi::c_void, x: f64, y: f64, width: f64, height: f64);
    fn tw_desktop_window_control(window: *mut std::ffi::c_void, action: *const std::ffi::c_char);
    fn tw_desktop_account(input: *const std::ffi::c_char) -> *mut std::ffi::c_char;
    fn free(ptr: *mut std::ffi::c_void);
    fn tw_desktop_passkeys_available() -> bool;
    fn tw_desktop_passkey(window: *mut std::ffi::c_void, mode: *const std::ffi::c_char, name: *const std::ffi::c_char,
                         context: *mut std::ffi::c_void, reply: extern "C" fn(*mut std::ffi::c_void, *const std::ffi::c_char));
}

pub fn passkeys_available() -> bool { unsafe { tw_desktop_passkeys_available() } }

#[tauri::command]
pub async fn native_passkey(window: tauri::WebviewWindow, mode: String, name: String) -> Result<serde_json::Value, String> {
    if !matches!(mode.as_str(), "create" | "get") { return Err("Invalid passkey request".into()); }
    let (tx, rx) = tokio::sync::oneshot::channel::<Result<serde_json::Value, String>>();
    extern "C" fn reply(context: *mut std::ffi::c_void, value: *const std::ffi::c_char) {
        let sender = unsafe { Box::from_raw(context as *mut tokio::sync::oneshot::Sender<Result<serde_json::Value, String>>) };
        let result = if value.is_null() { Err("Empty passkey response".into()) } else {
            serde_json::from_slice(unsafe { std::ffi::CStr::from_ptr(value) }.to_bytes()).map_err(|e| e.to_string())
        };
        let _ = sender.send(result);
    }
    window.clone().run_on_main_thread(move || {
        let Ok(ptr) = window.ns_window() else { let _ = tx.send(Err("The window is closed".into())); return };
        let Ok(mode) = std::ffi::CString::new(mode) else { let _ = tx.send(Err("Invalid mode".into())); return };
        let Ok(name) = std::ffi::CString::new(name) else { let _ = tx.send(Err("Invalid name".into())); return };
        unsafe { tw_desktop_passkey(ptr, mode.as_ptr(), name.as_ptr(), Box::into_raw(Box::new(tx)).cast(), reply) };
    }).map_err(|e| e.to_string())?;
    let value = rx.await.map_err(|e| e.to_string())??;
    if let Some(error) = value.get("error").and_then(serde_json::Value::as_str) { return Err(error.into()); }
    Ok(value)
}

pub fn native_account(request: String) -> Result<serde_json::Value, String> {
    let input = std::ffi::CString::new(request).map_err(|e| e.to_string())?;
    unsafe {
        let ptr = tw_desktop_account(input.as_ptr());
        if ptr.is_null() { return Err("No keychain response".into()); }
        let result = serde_json::from_slice(std::ffi::CStr::from_ptr(ptr).to_bytes()).map_err(|e| e.to_string());
        free(ptr.cast());
        result
    }
}

pub fn window_control(window: tauri::WebviewWindow, action: String) {
    let _ = window.clone().run_on_main_thread(move || {
        let Ok(ptr) = window.ns_window() else { return };
        let Ok(action) = std::ffi::CString::new(action) else { return };
        unsafe { tw_desktop_window_control(ptr, action.as_ptr()); }
    });
}

pub fn hover_buttons(window: tauri::WebviewWindow, x: f64, y: f64, width: f64, height: f64) {
    let _ = window.clone().run_on_main_thread(move || {
        let Ok(ptr) = window.ns_window() else { return };
        unsafe { tw_desktop_hover_buttons(ptr, x, y, width, height); }
    });
}
