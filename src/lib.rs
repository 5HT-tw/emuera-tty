//! The engine as a shared library for the Android app. The whole of main.rs is included
//! so its modules and `run` stay at the crate root, exactly as in the terminal program:
//! that keeps this fork's changes to upstream's files to a few lines.
#![allow(dead_code, unused_imports, unused_macros)]

include!("main.rs");

#[cfg(target_os = "android")]
mod android;
