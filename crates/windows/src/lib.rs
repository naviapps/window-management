//! Native Windows discovery/control in physical virtual-desktop pixels.
//! Discovery does not activate windows. State commands retain native activation behavior.
//! No process-wide DPI, permission or host policy is changed.
#[cfg(any(windows, test))]
mod coordinates;
#[cfg(windows)]
mod desktop;
#[cfg(windows)]
pub use desktop::*;
