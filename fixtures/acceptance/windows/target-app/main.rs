//! The separate process used by the managed Windows desktop acceptance fixture.

#[cfg(windows)]
fn main() -> std::io::Result<()> {
    window::run()
}

#[cfg(not(windows))]
fn main() {}

#[cfg(windows)]
mod window;
