//! Platform configuration loaded during process startup.
//!
//! Environment variables own server, database, session, and CORS settings.
//! `CALCO_CONFIG_FILE` optionally configures the assistant provider.

mod app;
mod error;
mod source;

pub use app::{
    AppConfig, AssistantAuthentication, AssistantConfig, AssistantModel, AssistantProviderConfig,
    ServerConfig, SessionConfig,
};
pub use error::ConfigError;
