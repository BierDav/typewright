#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
mod disk;
mod repository;
#[cfg(target_os = "macos")]
mod mac;

use std::{path::PathBuf, sync::{Arc, Mutex}};
use serde_json::{Value, json};
use tauri::{Emitter, Manager};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_opener::OpenerExt;
use tauri_plugin_deep_link::DeepLinkExt;

#[tauri::command]
fn theme(window: tauri::WebviewWindow, theme: String) -> Result<(), String> {
    window.set_theme(match theme.as_str() { "light" => Some(tauri::Theme::Light), "dark" => Some(tauri::Theme::Dark), _ => None }).map_err(|e| e.to_string())
}

#[tauri::command]
fn window_control(window: tauri::WebviewWindow, action: String) {
    #[cfg(target_os = "macos")]
    mac::window_control(window, action);
    #[cfg(not(target_os = "macos"))]
    let _ = (window, action);
}

#[tauri::command]
fn zoom_window(window: tauri::WebviewWindow) -> Result<(), String> {
    if window.is_maximized().map_err(|e| e.to_string())? { window.unmaximize() } else { window.maximize() }.map_err(|e| e.to_string())
}

#[tauri::command]
fn drag_window(window: tauri::WebviewWindow) -> Result<(), String> { window.start_dragging().map_err(|e| e.to_string()) }

#[tauri::command]
fn open_url(app: tauri::AppHandle, url: String) -> Result<(), String> {
    let parsed = tauri::Url::parse(&url).map_err(|e| e.to_string())?;
    if !matches!(parsed.scheme(), "https" | "http" | "mailto") { return Err("Unsupported URL".into()); }
    app.opener().open_url(url, None::<&str>).map_err(|e| e.to_string())
}

#[tauri::command]
fn reveal(disk: tauri::State<'_, Arc<disk::Disk>>, path: PathBuf) -> Result<(), String> {
    let path = path.canonicalize().map_err(disk::error)?;
    if !path.starts_with(&disk.root) { return Err("EACCES".into()); }
    tauri_plugin_opener::reveal_item_in_dir(path).map_err(|e| e.to_string())
}

#[derive(Default)]
struct PackageFolder(Mutex<Option<PathBuf>>);

#[tauri::command]
async fn package_folder(app: tauri::AppHandle, chosen: tauri::State<'_, PackageFolder>) -> Result<Value, String> {
    let selected = tauri::async_runtime::spawn_blocking(move || app.dialog().file().blocking_pick_folder()).await.map_err(|e| e.to_string())?;
    let Some(folder) = selected else { return Ok(Value::Null) };
    let folder = folder.into_path().map_err(|e| e.to_string())?.canonicalize().map_err(disk::error)?;
    let mut candidates = vec![folder.clone()];
    for entry in std::fs::read_dir(&folder).map_err(disk::error)? {
        let entry = entry.map_err(disk::error)?;
        if entry.path().is_dir() && !entry.file_name().to_string_lossy().starts_with('.') { candidates.push(entry.path()); }
    }
    let manifests: Vec<Value> = candidates.into_iter().filter_map(|target| std::fs::read_to_string(target.join("typst.toml")).ok().map(|toml| json!({ "target": target, "toml": toml }))).collect();
    *chosen.0.lock().unwrap() = Some(folder.clone());
    Ok(json!({ "folder": folder, "manifests": manifests }))
}

fn namespace(name: &str) -> Result<(), String> {
    if name.is_empty() || name == "preview" || !name.chars().enumerate().all(|(i, c)| c == '_' || c.is_ascii_alphabetic() || i > 0 && (c.is_ascii_digit() || c == '-')) { return Err("Invalid package namespace".into()); }
    Ok(())
}

fn symlink(from: &std::path::Path, to: &std::path::Path) -> std::io::Result<()> {
    #[cfg(unix)]
    { std::os::unix::fs::symlink(from, to) }
    #[cfg(windows)]
    { junction::create(from, to) }
}

#[tauri::command]
fn link_packages(disk: tauri::State<'_, Arc<disk::Disk>>, chosen: tauri::State<'_, PackageFolder>, namespace: String, folder: PathBuf, packages: Vec<Value>) -> Result<(), String> {
    self::namespace(&namespace)?;
    let folder = folder.canonicalize().map_err(disk::error)?;
    if chosen.0.lock().unwrap().as_ref() != Some(&folder) { return Err("Choose the package folder first".into()); }
    let destination = disk.root.join("packages").join(namespace);
    if destination.symlink_metadata().is_ok() { return Err("This namespace already exists".into()); }
    std::fs::create_dir_all(destination.parent().unwrap()).map_err(disk::error)?;
    if packages.is_empty() { return symlink(&folder, &destination).map_err(disk::error); }
    std::fs::create_dir(&destination).map_err(disk::error)?;
    let result = (|| {
        std::fs::write(destination.join(".typewright-link"), folder.to_string_lossy().as_bytes()).map_err(disk::error)?;
        for package in packages {
            let name = package["name"].as_str().ok_or("Missing package name")?;
            let version = package["version"].as_str().ok_or("Missing package version")?;
            if name.is_empty() || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-') || version.split('.').count() != 3 || !version.split('.').all(|s| !s.is_empty() && s.chars().all(|c| c.is_ascii_digit())) { return Err("Invalid package manifest".into()); }
            let target = PathBuf::from(package["target"].as_str().ok_or("Missing target")?).canonicalize().map_err(disk::error)?;
            if target != folder && target.parent() != Some(&folder) { return Err("Invalid package target".into()); }
            let parent = destination.join(name);
            std::fs::create_dir_all(&parent).map_err(disk::error)?;
            symlink(&target, &parent.join(version)).map_err(disk::error)?;
        }
        Ok(())
    })();
    if result.is_err() { let _ = std::fs::remove_dir_all(destination); }
    result
}

#[tauri::command]
fn package_links(disk: tauri::State<'_, Arc<disk::Disk>>) -> Vec<String> {
    std::fs::read_dir(disk.root.join("packages")).into_iter().flatten().filter_map(Result::ok).filter(|e| e.path().is_symlink() || e.path().join(".typewright-link").is_file()).map(|e| e.file_name().to_string_lossy().into_owned()).collect()
}

#[tauri::command]
fn unlink_packages(disk: tauri::State<'_, Arc<disk::Disk>>, namespace: String) -> Result<(), String> {
    self::namespace(&namespace)?;
    let target = disk.root.join("packages").join(namespace);
    if target.is_symlink() {
        #[cfg(unix)]
        std::fs::remove_file(target).map_err(disk::error)?;
        #[cfg(windows)]
        junction::delete(target).map_err(disk::error)?;
    } else if target.join(".typewright-link").is_file() { std::fs::remove_dir_all(target).map_err(disk::error)?; }
    else { return Err("Not a linked namespace".into()); }
    Ok(())
}

#[cfg(not(target_os = "macos"))]
#[tauri::command]
async fn native_passkey() -> Result<Value, String> { Err("Native passkeys are not available on this platform".into()) }
#[cfg(target_os = "macos")]
use mac::native_passkey;

fn main() {
    let mut context = tauri::generate_context!();
    context.package_info_mut().name = "Typewright".into();
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| {
            if let Some(window) = app.get_webview_window("main") { let _ = window.unminimize(); let _ = window.set_focus(); }
        }))
        .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_window_state::Builder::default().build())
        .menu(|app| {
            let menu = tauri::menu::Menu::default(app)?;
            #[cfg(debug_assertions)]
            {
                let toggle = tauri::menu::MenuItemBuilder::with_id("devtools", "Toggle Developer Tools").accelerator("CmdOrCtrl+Alt+I").build(app)?;
                let developer = tauri::menu::SubmenuBuilder::new(app, "Developer").item(&toggle).build()?;
                menu.append(&developer)?;
            }
            Ok(menu)
        })
        .on_menu_event(|app, event| {
            #[cfg(debug_assertions)]
            if event.id().as_ref() == "devtools" {
                if let Some(window) = app.get_webview_window("main") {
                    if window.is_devtools_open() { window.close_devtools(); } else { window.open_devtools(); }
                }
            }
            let _ = (app, event);
        })
        .manage(PackageFolder::default())
        .invoke_handler(tauri::generate_handler![disk::disk_op, disk::disk_read, disk::disk_write, repository::repository, theme, hover_buttons, window_control, zoom_window, drag_window, open_url, reveal, package_folder, link_packages, package_links, unlink_packages, native_passkey, native_account])
        .setup(|app| {
            let data = if cfg!(target_os = "linux") { app.path().config_dir()? } else { app.path().data_dir()? };
            let root = std::env::var_os("TYPEWRIGHT_LIBRARY").map(PathBuf::from).unwrap_or(data.join("Typewright Desktop"));
            let disk = Arc::new(disk::Disk::new(root)?);
            app.manage(repository::Repository::new(disk.root.join("Spaces")));
            app.manage(disk.watch(app.handle().clone())?);
            app.manage(disk.clone());
            #[cfg(target_os = "macos")]
            let native_passkey = mac::passkeys_available();
            #[cfg(not(target_os = "macos"))]
            let native_passkey = false;
            let config = json!({ "library": disk.root, "platform": if cfg!(target_os = "macos") { "darwin" } else if cfg!(windows) { "win32" } else { "linux" }, "nativeScroll": cfg!(target_os = "macos"), "nativePasskey": native_passkey });
            let window_config = app.config().app.windows[0].clone();
            let mut builder = tauri::WebviewWindowBuilder::from_config(app, &window_config)?
                .initialization_script(format!("window.__TYPEWRIGHT_NATIVE__ = {config};"));
            #[cfg(target_os = "macos")]
            { builder = builder.title_bar_style(tauri::TitleBarStyle::Overlay).hidden_title(true).traffic_light_position(tauri::LogicalPosition::new(20., 20.)); }
            let handle = app.handle().clone();
            builder = builder.on_navigation(move |url| {
                if matches!(url.scheme(), "tauri" | "blob") || matches!(url.host_str(), Some("localhost" | "tauri.localhost")) { return true; }
                if matches!(url.scheme(), "https" | "http" | "mailto") { let _ = handle.opener().open_url(url.to_string(), None::<&str>); }
                false
            });
            let handle = app.handle().clone();
            builder = builder.on_new_window(move |url, _| {
                if url.scheme() == "blob" { return tauri::webview::NewWindowResponse::Allow; }
                if matches!(url.scheme(), "https" | "http" | "mailto") { let _ = handle.opener().open_url(url.to_string(), None::<&str>); }
                tauri::webview::NewWindowResponse::Deny
            });
            let window = builder.build()?;
            window.set_title("Typewright")?;
            #[cfg(target_os = "macos")]
            mac::watch_scroll(&window);
            let handle = app.handle().clone();
            app.deep_link().on_open_url(move |event| {
                for url in event.urls() { let _ = handle.emit("passkey-link", url.as_str()); }
                if let Some(window) = handle.get_webview_window("main") { let _ = window.unminimize(); let _ = window.set_focus(); }
            });
            #[cfg(any(windows, target_os = "linux"))]
            app.deep_link().register_all()?;
            Ok(())
        })
        .run(context)
        .expect("Couldn't run Typewright");
}

#[tauri::command]
fn native_account(request: String) -> Result<serde_json::Value, String> {
    #[cfg(target_os = "macos")]
    { mac::native_account(request) }
    #[cfg(not(target_os = "macos"))]
    { let _ = request; Ok(serde_json::Value::Null) }
}

#[tauri::command]
fn hover_buttons(window: tauri::WebviewWindow, x: f64, y: f64, width: f64, height: f64) {
    #[cfg(target_os = "macos")]
    mac::hover_buttons(window, x, y, width, height);
    #[cfg(not(target_os = "macos"))]
    let _ = (window, x, y, width, height);
}
