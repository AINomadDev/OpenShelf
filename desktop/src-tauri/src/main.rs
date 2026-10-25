#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
use openshelf_core::{mount, providers, quota, store::{self, Paths, Space}};
use serde::Serialize;
use std::{collections::HashMap, process::{Command, Stdio}, time::{SystemTime, UNIX_EPOCH}};

const USAGE_TTL_SECS: u64 = 6 * 3600;

#[derive(Serialize)]
struct View { space: Space, running: bool, usage: Option<quota::Usage>, quota: Option<quota::Quota>, provider: Option<&'static providers::Provider> }

fn now() -> u64 { SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs()) }

fn view(paths: &Paths, space: Space, usage: &HashMap<String, quota::Usage>) -> View {
    let provider = providers::find(&space.provider);
    let u = usage.get(&space.id).cloned();
    let q = u.as_ref().map(|u| quota::quota(u.used, u.total.or(provider.and_then(|p| p.free_tier))));
    View { running: mount::is_running(paths, &space), space, usage: u, quota: q, provider }
}

#[tauri::command]
async fn catalogue() -> &'static [providers::Provider] { providers::PROVIDERS }

#[tauri::command]
async fn list_spaces() -> Result<Vec<View>, String> {
    let paths = Paths::system();
    let usage = store::load_usage(&paths);
    Ok(store::load_spaces(&paths)?.into_iter().map(|s| view(&paths, s, &usage)).collect())
}

#[tauri::command]
async fn add_space(provider: String, title: String, root: String, read_only: bool, archive: bool, fields: HashMap<String, String>) -> Result<(), String> {
    let paths = Paths::system();
    let p = providers::find(&provider).ok_or("Unknown provider.")?;
    let config = providers::build_config(p, &fields)?;
    let mut spaces = store::load_spaces(&paths)?;
    let space = store::new_space(&paths, &spaces, &provider, &title, &root, read_only, archive)?;
    let mut text = format!("[{}]\n", mount::remote_name(&space));
    for (k, v) in config { text.push_str(&format!("{k} = {v}\n")); }
    store::write_private(&paths.conf(&space.id), &text).map_err(|e| e.to_string())?;
    spaces.push(space);
    store::save_spaces(&paths, &spaces)
}

fn find_space(paths: &Paths, id: &str) -> Result<Space, String> {
    store::load_spaces(paths)?.into_iter().find(|s| s.id == id).ok_or_else(|| "Space not found.".into())
}

#[tauri::command]
async fn start_space(id: String) -> Result<(), String> { let p = Paths::system(); mount::start(&p, &find_space(&p, &id)?) }

#[tauri::command]
async fn stop_space(id: String) -> Result<(), String> { let p = Paths::system(); mount::stop(&p, &find_space(&p, &id)?) }

#[tauri::command]
async fn remove_space(id: String) -> Result<(), String> {
    let p = Paths::system();
    let space = find_space(&p, &id)?;
    if mount::is_running(&p, &space) { return Err("Disconnect this space before removing it.".into()); }
    let rest: Vec<Space> = store::load_spaces(&p)?.into_iter().filter(|s| s.id != id).collect();
    store::save_spaces(&p, &rest)?;
    let _ = std::fs::remove_file(p.conf(&id));
    Ok(())
}

#[tauri::command]
async fn transfers(id: String) -> Result<(u32, u32), String> {
    let p = Paths::system();
    let s = mount::stats(&p, &find_space(&p, &id)?)?;
    Ok((s.disk_cache.uploads_in_progress, s.disk_cache.uploads_queued))
}

/// Object storage has no quota API, so usage comes from `rclone size`, which is billed as list requests; hence the cache.
#[tauri::command]
async fn refresh_usage(id: String, force: bool) -> Result<(), String> {
    let p = Paths::system();
    let space = find_space(&p, &id)?;
    let mut usage = store::load_usage(&p);
    if !force && usage.get(&id).map_or(false, |u| now().saturating_sub(u.updated) < USAGE_TTL_SECS) { return Ok(()); }
    let out = Command::new(mount::rclone_path())
        .args(["size", "--json", &mount::remote_path(&space), "--config", &p.conf(&id).to_string_lossy()])
        .stdin(Stdio::null()).output().map_err(|_| "rclone was not found.".to_string())?;
    let fresh = quota::from_size(&String::from_utf8_lossy(&out.stdout), now()).ok_or("Could not read usage.")?;
    usage.insert(id, fresh);
    store::save_usage(&p, &usage);
    Ok(())
}

#[tauri::command]
async fn clean_junk(id: String) -> Result<(), String> {
    let p = Paths::system();
    let space = find_space(&p, &id)?;
    if mount::is_running(&p, &space) { return Err("Disconnect this space before cleaning junk files.".into()); }
    let out = Command::new(mount::rclone_path()).args(mount::junk_cleanup_args(&space, &p)).stdin(Stdio::null()).output().map_err(|_| "rclone was not found.".to_string())?;
    if out.status.success() { Ok(()) } else { Err("Could not clean junk files. Check your connection and credentials.".into()) }
}

#[tauri::command]
async fn open_url(url: String) -> Result<(), String> {
    let allowed = providers::PROVIDERS.iter().any(|p| !p.console_url.is_empty() && p.console_url == url);
    if !allowed { return Err("That link is not allowed.".into()); }
    #[cfg(target_os = "windows")]
    let mut cmd = { let mut c = Command::new("rundll32"); c.args(["url.dll,FileProtocolHandler", &url]); c };
    #[cfg(target_os = "macos")]
    let mut cmd = { let mut c = Command::new("open"); c.arg(&url); c };
    #[cfg(all(unix, not(target_os = "macos")))]
    let mut cmd = { let mut c = Command::new("xdg-open"); c.arg(&url); c };
    cmd.spawn().map(|_| ()).map_err(|e| e.to_string())
}

#[tauri::command]
async fn open_folder(id: String) -> Result<(), String> {
    let p = Paths::system();
    let space = find_space(&p, &id)?;
    if !mount::is_running(&p, &space) { return Err("Connect the drive first.".into()); }
    #[cfg(target_os = "windows")]
    let mut cmd = Command::new("explorer");
    #[cfg(target_os = "macos")]
    let mut cmd = Command::new("open");
    #[cfg(all(unix, not(target_os = "macos")))]
    let mut cmd = Command::new("xdg-open");
    cmd.arg(&space.mount_path).spawn().map(|_| ()).map_err(|e| e.to_string())
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![catalogue, list_spaces, add_space, start_space, stop_space, remove_space, transfers, refresh_usage, clean_junk, open_url, open_folder])
        .run(tauri::generate_context!())
        .expect("failed to run OpenShelf");
}
