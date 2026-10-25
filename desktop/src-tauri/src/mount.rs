use crate::store::{write_private, Paths, Space};
use serde::{Deserialize, Serialize};
use std::{fs, path::PathBuf, process::{Command, Stdio}};

#[derive(Serialize, Deserialize)]
struct State { pid: u32, password: String }

#[derive(Deserialize, Debug)]
pub struct VfsStats { #[serde(rename = "diskCache")] pub disk_cache: DiskCache }
#[derive(Deserialize, Debug)]
pub struct DiskCache {
    #[serde(rename = "bytesUsed")] pub bytes_used: u64,
    #[serde(rename = "uploadsInProgress")] pub uploads_in_progress: u32,
    #[serde(rename = "uploadsQueued")] pub uploads_queued: u32,
    #[serde(rename = "erroredFiles")] pub errored_files: u32,
    #[serde(rename = "outOfSpace")] pub out_of_space: bool,
}
impl VfsStats {
    pub fn can_unmount(&self) -> bool {
        let d = &self.disk_cache;
        d.uploads_in_progress == 0 && d.uploads_queued == 0 && d.errored_files == 0 && !d.out_of_space
    }
}

pub fn rclone_path() -> PathBuf {
    if let Ok(p) = std::env::var("OPENSHELF_RCLONE") { return PathBuf::from(p); }
    let name = if cfg!(windows) { "rclone.exe" } else { "rclone" };
    if let Some(dir) = std::env::current_exe().ok().and_then(|e| e.parent().map(|d| d.to_path_buf())) {
        let bundled = dir.join(name);
        if bundled.exists() { return bundled; }
    }
    PathBuf::from(name)
}

pub fn remote_name(space: &Space) -> String { format!("openshelf-{}", space.id) }

/// Deletes macOS metadata clutter; mounts cannot filter these at write time.
pub fn junk_cleanup_args(space: &Space, paths: &Paths) -> Vec<String> {
    ["delete".to_string(), remote_path(space), "--include".into(), "._*".into(), "--include".into(), ".DS_Store".into(),
     "--config".into(), paths.conf(&space.id).to_string_lossy().into()].to_vec()
}

pub fn remote_path(space: &Space) -> String { format!("{}:{}", remote_name(space), space.root) }

/// Archive mode keeps downloaded files cached longer and caches directory listings, so repeat access is not re-billed.
pub fn mount_args(space: &Space, paths: &Paths) -> Vec<String> {
    let mut args: Vec<String> = ["mount".to_string(), remote_path(space), space.mount_path.clone(),
        "--config".into(), paths.conf(&space.id).to_string_lossy().into(),
        "--cache-dir".into(), paths.cache(&space.id).to_string_lossy().into(),
        "--vfs-cache-mode".into(), "full".into(), "--vfs-cache-max-size".into(), "5G".into(),
        "--vfs-cache-min-free-space".into(), "10G".into(), "--vfs-cache-poll-interval".into(), "10s".into(),
        "--vfs-cache-max-age".into(), (if space.archive { "72h" } else { "1h" }).into(),
        "--vfs-read-chunk-size".into(), "8M".into(), "--vfs-read-chunk-size-limit".into(), "64M".into(),
        "--buffer-size".into(), "8M".into(), "--rc".into(), "--rc-addr".into(), format!("127.0.0.1:{}", space.port),
        "--log-level".into(), "NOTICE".into(), "--log-file".into(), paths.log(&space.id).to_string_lossy().into()].to_vec();
    if space.archive { args.extend(["--dir-cache-time".into(), "30m".into(), "--vfs-read-ahead".into(), "0".into()]); }
    if space.read_only { args.push("--read-only".into()); }
    args
}

fn load_state(paths: &Paths, id: &str) -> Option<State> {
    serde_json::from_str(&fs::read_to_string(paths.state(id)).ok()?).ok()
}

fn pid_alive(pid: u32) -> bool {
    #[cfg(unix)]
    { Command::new("kill").args(["-0", &pid.to_string()]).stdout(Stdio::null()).stderr(Stdio::null()).status().map_or(false, |s| s.success()) }
    #[cfg(windows)]
    {
        Command::new("tasklist").args(["/FI", &format!("PID eq {pid}"), "/NH"]).output()
            .map_or(false, |o| String::from_utf8_lossy(&o.stdout).contains(&pid.to_string()))
    }
}

/// A drive is running while the detached rclone process recorded for it is alive.
pub fn is_running(paths: &Paths, space: &Space) -> bool {
    match load_state(paths, &space.id) {
        Some(s) if pid_alive(s.pid) => true,
        Some(_) => { let _ = fs::remove_file(paths.state(&space.id)); false }
        None => false,
    }
}

pub fn start(paths: &Paths, space: &Space) -> Result<(), String> {
    if is_running(paths, space) { return Ok(()); }
    fs::create_dir_all(paths.base.join("logs")).map_err(|e| e.to_string())?;
    fs::create_dir_all(paths.cache(&space.id)).map_err(|e| e.to_string())?;
    let mount = PathBuf::from(&space.mount_path);
    // WinFsp needs a path that does not exist yet; FUSE needs an existing empty directory.
    if cfg!(windows) { if mount.exists() && fs::read_dir(&mount).map_or(false, |mut d| d.next().is_some()) { return Err("Mount folder must be empty.".into()); } }
    else {
        fs::create_dir_all(&mount).map_err(|e| e.to_string())?;
        if fs::read_dir(&mount).map_err(|e| e.to_string())?.next().is_some() { return Err("Mount folder must be empty.".into()); }
    }
    let password = format!("{}{}", uuid::Uuid::new_v4(), uuid::Uuid::new_v4());
    let mut cmd = Command::new(rclone_path());
    cmd.args(mount_args(space, paths)).env("RCLONE_RC_USER", "openshelf").env("RCLONE_RC_PASS", &password)
        .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    // Detach so the drive and its uploads keep running after OpenShelf is closed or updated.
    #[cfg(unix)]
    { use std::os::unix::process::CommandExt; cmd.process_group(0); }
    #[cfg(windows)]
    { use std::os::windows::process::CommandExt; cmd.creation_flags(0x0000_0008 | 0x0000_0200); }
    let child = cmd.spawn().map_err(|_| "rclone was not found. Install rclone (and WinFsp on Windows or FUSE on Linux).".to_string())?;
    let state = serde_json::to_string(&State { pid: child.id(), password }).map_err(|e| e.to_string())?;
    write_private(&paths.state(&space.id), &state).map_err(|e| e.to_string())
}

fn rc(paths: &Paths, space: &Space, command: &str) -> Result<String, String> {
    let state = load_state(paths, &space.id).ok_or("Drive is not running.")?;
    let out = Command::new(rclone_path()).args(["rc", command, "--url", &format!("http://127.0.0.1:{}", space.port)])
        .env("RCLONE_RC_USER", "openshelf").env("RCLONE_RC_PASS", state.password).stdin(Stdio::null()).output().map_err(|e| e.to_string())?;
    if out.status.success() { Ok(String::from_utf8_lossy(&out.stdout).to_string()) } else { Err("Transfer status is unavailable.".into()) }
}

pub fn stats(paths: &Paths, space: &Space) -> Result<VfsStats, String> {
    serde_json::from_str(&rc(paths, space, "vfs/stats")?).map_err(|_| "Transfer status is unavailable.".to_string())
}

/// Refuses to stop unless uploads are idle, then asks rclone to flush and unmount itself.
pub fn stop(paths: &Paths, space: &Space) -> Result<(), String> {
    let stats = stats(paths, space).map_err(|_| "Wait for transfer status before disconnecting.".to_string())?;
    if !stats.can_unmount() { return Err("Uploads are still running. Wait for them to finish before disconnecting.".into()); }
    rc(paths, space, "core/quit").map(|_| ())?;
    for _ in 0..50 {
        if !is_running(paths, space) { let _ = fs::remove_file(paths.state(&space.id)); return Ok(()); }
        std::thread::sleep(std::time::Duration::from_millis(200));
    }
    Err("Drive is busy. Close files and folders using it, then retry.".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn space(archive: bool, read_only: bool) -> Space {
        Space { id: "abc".into(), provider: "r2".into(), title: "T".into(), root: "bucket/p".into(), read_only, archive, port: 55740, mount_path: "/tmp/m".into() }
    }
    fn paths() -> Paths { Paths { base: PathBuf::from("/tmp/base"), mounts: PathBuf::from("/tmp/m") } }
    #[test]
    fn archive_mode_changes_caching() {
        let a = mount_args(&space(true, false), &paths());
        assert_eq!(a[a.iter().position(|x| x == "--vfs-cache-max-age").unwrap() + 1], "72h");
        assert!(a.contains(&"--dir-cache-time".to_string()));
        let l = mount_args(&space(false, false), &paths());
        assert_eq!(l[l.iter().position(|x| x == "--vfs-cache-max-age").unwrap() + 1], "1h");
        assert!(!l.contains(&"--dir-cache-time".to_string()));
    }
    #[test]
    fn read_only_and_loopback_control_port() {
        let a = mount_args(&space(true, true), &paths());
        assert!(a.contains(&"--read-only".to_string()) && a.contains(&"127.0.0.1:55740".to_string()));
        assert!(!a.iter().any(|x| x.contains("openshelf") && x.contains("pass")));
    }
    #[test]
    fn junk_cleanup_only_targets_metadata() {
        let a = junk_cleanup_args(&space(true, false), &paths());
        assert!(a[0] == "delete" && a.contains(&"._*".to_string()) && a.contains(&".DS_Store".to_string()));
    }
    #[test]
    fn unmount_guard() {
        let busy: VfsStats = serde_json::from_str(r#"{"diskCache":{"bytesUsed":1,"uploadsInProgress":1,"uploadsQueued":0,"erroredFiles":0,"outOfSpace":false}}"#).unwrap();
        let idle: VfsStats = serde_json::from_str(r#"{"diskCache":{"bytesUsed":1,"uploadsInProgress":0,"uploadsQueued":0,"erroredFiles":0,"outOfSpace":false}}"#).unwrap();
        assert!(!busy.can_unmount() && idle.can_unmount());
    }
}
