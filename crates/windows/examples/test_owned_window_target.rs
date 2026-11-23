//! The separate process used by the managed Windows desktop acceptance fixture.

#[cfg(windows)]
fn main() -> std::io::Result<()> {
    target::run()
}

#[cfg(not(windows))]
fn main() {}

#[cfg(windows)]
#[path = "../tests/support/owned_window_target.rs"]
mod target;
