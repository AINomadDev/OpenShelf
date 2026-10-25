@echo off
rem Starts OpenShelf on Windows. Needs Rust, rclone and WinFsp installed.
cd /d "%~dp0desktop\src-tauri" && cargo run --release
