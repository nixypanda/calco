//! Food-assistance bounded context.
//!
//! This context owns transient conversations and untrusted custom-food drafts.
//! It deliberately does not depend on nutrition's product aggregate: the
//! future nutrition vocabulary adapter is owned at this boundary instead.

pub mod application;
pub mod domain;
pub mod infrastructure;
pub mod interfaces;
pub mod module;
