use std::net::SocketAddr;
use std::path::{Path, PathBuf};

use axum::http::{HeaderName, HeaderValue};
use url::Url;

use super::ConfigError;
use super::source::{load_env, load_toml};

/// All startup settings required by application composition.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppConfig {
    pub database_url: String,
    pub server: ServerConfig,
    pub session: SessionConfig,
    pub assistant: AssistantConfig,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerConfig {
    pub bind_addr: SocketAddr,
    pub cors_allowed_origins: Vec<HeaderValue>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionConfig {
    pub cookie_name: String,
    pub cookie_secure: bool,
    pub ttl_seconds: i64,
}

/// Assistant settings safe to retain during application composition. Enabled
/// settings contain API-key file paths, never API-key contents.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AssistantConfig {
    Disabled,
    Enabled(AssistantProviderConfig),
}

impl AssistantConfig {
    pub fn is_enabled(&self) -> bool {
        matches!(self, Self::Enabled(_))
    }

    pub fn as_enabled(&self) -> Option<&AssistantProviderConfig> {
        match self {
            Self::Disabled => None,
            Self::Enabled(settings) => Some(settings),
        }
    }
}

/// Complete settings for an enabled OpenAI-compatible deployment.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AssistantProviderConfig {
    pub endpoint: Url,
    pub model: AssistantModel,
    pub supports_images: bool,
    pub authentication: AssistantAuth,
}

/// A non-empty, trimmed provider model identifier.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AssistantModel(String);

impl AssistantModel {
    pub(in crate::config) fn new(value: String) -> Self {
        Self(value)
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Auth metadata for an enabled assistant deployment.
///
/// Credential paths are retained as deployment metadata. Configuration loading
/// deliberately does not access their contents.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AssistantAuth {
    None,
    Bearer {
        api_key_file: PathBuf,
    },
    Header {
        header_name: HeaderName,
        api_key_file: PathBuf,
    },
}

impl AppConfig {
    /// Loads typed process settings and the optional TOML file named by
    /// `CALCO_CONFIG_FILE`.
    pub fn from_env() -> Result<Self, ConfigError> {
        let config_file = std::env::var_os("CALCO_CONFIG_FILE").map(PathBuf::from);
        Self::from_sources(|name| std::env::var(name).ok(), config_file.as_deref())
    }

    fn from_sources(
        env_lookup: impl Fn(&str) -> Option<String>,
        config_file: Option<&Path>,
    ) -> Result<Self, ConfigError> {
        let environment = load_env(env_lookup)?;
        let assistant = load_toml(config_file)?;

        Ok(Self {
            database_url: environment.database_url,
            server: environment.server,
            session: environment.session,
            assistant,
        })
    }
}
