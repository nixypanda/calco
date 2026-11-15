//! Platform configuration loaded during process startup.
//!
//! Environment variables own server, database, session, CORS, and MCP host
//! settings. `CALCO_CONFIG_FILE` optionally configures the assistant provider.

mod app;
mod error;
mod source;

pub(crate) use app::default_mcp_allowed_hosts;
pub use app::{
    AppConfig, AssistantAuth, AssistantConfig, AssistantModel, AssistantProviderConfig,
    ServerConfig, SessionConfig,
};
pub use error::ConfigError;
