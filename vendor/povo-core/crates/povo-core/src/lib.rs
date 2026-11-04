//! Unofficial, cross-platform (Windows / Android / iOS via `uniffi`) client
//! library for the povo2.0 (`com.kddi.kdla.jp`, au/KDDI) account API.
//!
//! Reverse-engineered for personal account-management/interoperability
//! purposes. Not affiliated with, endorsed by, or supported by KDDI,
//! povo, or Circles.life. Endpoints, headers and payload shapes are subject
//! to change without notice; see `docs/API-REFERENCE.md` for the
//! project-owned request contract and verification boundaries.

mod client;
mod error;
mod jwt;
mod models;
mod url;

pub use client::PovoClient;
pub use error::PovoError;
pub use models::*;

uniffi::setup_scaffolding!();
