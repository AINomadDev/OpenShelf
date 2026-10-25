//! Platform-independent core: provider catalogue, rclone config generation,
//! quota maths, and detached mount management for Windows and Linux.
pub mod providers;
pub mod quota;
pub mod store;
pub mod mount;
pub mod shelf;
