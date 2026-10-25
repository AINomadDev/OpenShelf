use crate::quota::Usage;
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, fs, path::{Path, PathBuf}};

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Space {
    pub id: String,
    pub provider: String,
    pub title: String,
    pub root: String,
    pub read_only: bool,
    pub archive: bool,
    pub port: u16,
    pub mount_path: String,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub note: String,
}

pub struct Paths { pub base: PathBuf, pub mounts: PathBuf }

impl Paths {
    pub fn system() -> Paths {
        let base = dirs::config_dir().unwrap_or_else(|| PathBuf::from(".")).join("OpenShelf");
        let mounts = dirs::home_dir().unwrap_or_else(|| PathBuf::from(".")).join("OpenShelf");
        Paths { base, mounts }
    }
    pub fn spaces(&self) -> PathBuf { self.base.join("spaces.json") }
    pub fn usage(&self) -> PathBuf { self.base.join("usage.json") }
    pub fn conf(&self, id: &str) -> PathBuf { self.base.join("accounts").join(format!("{id}.conf")) }
    pub fn state(&self, id: &str) -> PathBuf { self.base.join("state").join(format!("{id}.json")) }
    pub fn log(&self, id: &str) -> PathBuf { self.base.join("logs").join(format!("{id}.log")) }
    pub fn cache(&self, id: &str) -> PathBuf {
        dirs::cache_dir().unwrap_or_else(|| self.base.join("cache")).join("OpenShelf").join(id)
    }
}

/// Writes a file readable only by the current user from the moment it exists.
pub fn write_private(path: &Path, contents: &str) -> std::io::Result<()> {
    if let Some(dir) = path.parent() { fs::create_dir_all(dir)?; }
    let _ = fs::remove_file(path);
    #[cfg(unix)]
    {
        use std::{io::Write, os::unix::fs::OpenOptionsExt};
        let mut file = fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(path)?;
        file.write_all(contents.as_bytes())
    }
    #[cfg(not(unix))]
    { fs::write(path, contents) }
}

pub fn load_spaces(paths: &Paths) -> Result<Vec<Space>, String> {
    match fs::read_to_string(paths.spaces()) {
        Ok(text) => serde_json::from_str(&text).map_err(|_| "Saved spaces could not be loaded safely. Your cloud files and credentials have not been changed.".to_string()),
        Err(_) => Ok(vec![]),
    }
}

pub fn save_spaces(paths: &Paths, spaces: &[Space]) -> Result<(), String> {
    let text = serde_json::to_string_pretty(spaces).map_err(|e| e.to_string())?;
    write_private(&paths.spaces(), &text).map_err(|e| e.to_string())
}

pub fn load_usage(paths: &Paths) -> HashMap<String, Usage> {
    fs::read_to_string(paths.usage()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
}

pub fn save_usage(paths: &Paths, usage: &HashMap<String, Usage>) {
    if let Ok(text) = serde_json::to_string(usage) { let _ = write_private(&paths.usage(), &text); }
}

pub fn valid_title(title: &str) -> Result<String, String> {
    let t = title.trim();
    let bad = t.is_empty() || t.chars().count() > 80 || t.chars().any(|c| matches!(c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' | '\n' | '\r'));
    if bad { Err("Choose a name of 1-80 characters without slashes, colons, or line breaks.".into()) } else { Ok(t.to_string()) }
}

pub fn valid_root(root: &str) -> Result<String, String> {
    let r = root.trim().trim_matches('/');
    if r.is_empty() { return Err("Please provide a bucket or container.".into()); }
    if r.contains('\n') || r.split('/').any(|p| p == "..") { return Err("Use a bucket path without parent traversal or line breaks.".into()); }
    Ok(r.to_string())
}

pub fn new_space(paths: &Paths, existing: &[Space], provider: &str, title: &str, root: &str, read_only: bool, archive: bool) -> Result<Space, String> {
    let title = valid_title(title)?;
    let root = valid_root(root)?;
    let id = uuid::Uuid::new_v4().to_string();
    let port = (55733u16..65000).find(|p| !existing.iter().any(|s| s.port == *p)).ok_or("No free control port is available.")?;
    let mount_path = paths.mounts.join(format!("{title} - {}", &id[..8])).to_string_lossy().to_string();
    Ok(Space { id, provider: provider.into(), title, root, read_only, archive, port, mount_path, tags: vec![], note: String::new() })
}

/// Comma-separated text to at most 8 unique tags of up to 24 characters.
pub fn parse_tags(text: &str) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for part in text.split(|c| c == ',' || c == ';' || c == '\n') {
        let tag: String = part.trim().chars().take(24).collect();
        if !tag.is_empty() && seen.insert(tag.to_lowercase()) { out.push(tag); }
        if out.len() == 8 { break; }
    }
    out
}

/// Applies edited details to one space. Identity, port and credentials are untouched; the mount folder follows the new name.
pub fn edit_space(paths: &Paths, spaces: &[Space], id: &str, title: &str, root: &str, read_only: bool, archive: bool) -> Result<Vec<Space>, String> {
    let title = valid_title(title)?;
    let root = valid_root(root)?;
    let mut out = spaces.to_vec();
    let space = out.iter_mut().find(|s| s.id == id).ok_or("Space not found.")?;
    space.title = title.clone();
    space.root = root;
    space.read_only = read_only;
    space.archive = archive;
    space.mount_path = paths.mounts.join(format!("{title} - {}", &id[..8.min(id.len())])).to_string_lossy().to_string();
    Ok(out)
}

#[cfg(test)]
mod tests {
    #[test]
    fn tags_are_trimmed_unique_and_capped() {
        assert_eq!(super::parse_tags(" work, Work ;family\n,, "), vec!["work", "family"]);
        assert_eq!(super::parse_tags(&"a,b,c,d,e,f,g,h,i,j".to_string()).len(), 8);
        assert_eq!(super::parse_tags(&"x".repeat(40))[0].len(), 24);
    }

    use super::*;
    fn paths() -> Paths { Paths { base: std::env::temp_dir().join(format!("os-{}", uuid::Uuid::new_v4())), mounts: PathBuf::from("/tmp/m") } }
    #[test]
    fn spaces_are_isolated_and_persist() {
        let p = paths();
        let a = new_space(&p, &[], "r2", "Photos", "bucket", false, true).unwrap();
        let b = new_space(&p, &[a.clone()], "r2", "Photos", "bucket", false, true).unwrap();
        assert!(a.id != b.id && a.port != b.port && a.mount_path != b.mount_path);
        save_spaces(&p, &[a.clone(), b]).unwrap();
        assert_eq!(load_spaces(&p).unwrap().len(), 2);
        fs::write(p.spaces(), "corrupt").unwrap();
        assert!(load_spaces(&p).is_err());
        let _ = fs::remove_dir_all(&p.base);
    }
    #[test]
    fn editing_keeps_identity_and_validates() {
        let p = paths();
        let a = new_space(&p, &[], "r2", "Photos", "bucket", false, true).unwrap();
        let out = edit_space(&p, &[a.clone()], &a.id, " Family ", "/bucket/2024/", true, false).unwrap();
        let e = &out[0];
        assert!(e.id == a.id && e.port == a.port && e.provider == a.provider);
        assert!(e.title == "Family" && e.root == "bucket/2024" && e.read_only && !e.archive);
        assert!(e.mount_path.contains("Family"));
        assert!(edit_space(&p, &[a.clone()], &a.id, "a/b", "bucket", false, true).is_err());
        assert!(edit_space(&p, &[a.clone()], "missing", "x", "bucket", false, true).is_err());
    }
    #[test]
    fn names_and_roots_validated() {
        for bad in ["", "a/b", "a:b", "a\nb", "../x"] { assert!(valid_title(bad).is_err(), "{bad}"); }
        assert!(valid_root("").is_err() && valid_root("a/../b").is_err());
        assert_eq!(valid_root("/bucket/prefix/").unwrap(), "bucket/prefix");
    }
    #[cfg(unix)]
    #[test]
    fn secrets_files_are_owner_only() {
        use std::os::unix::fs::PermissionsExt;
        let p = paths();
        write_private(&p.conf("x"), "secret").unwrap();
        assert_eq!(fs::metadata(p.conf("x")).unwrap().permissions().mode() & 0o777, 0o600);
        let _ = fs::remove_dir_all(&p.base);
    }
}
