use std::net::SocketAddr;
use std::path::{Path, PathBuf};

use axum::http::{HeaderName, HeaderValue};
use url::Url;

use super::ConfigError;
use super::source::{load_environment, load_toml};

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
    pub authentication: AssistantAuthentication,
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

/// Authentication metadata for an enabled assistant deployment.
///
/// Credential paths are retained as deployment metadata. Configuration loading
/// deliberately does not access their contents.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AssistantAuthentication {
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
        environment_lookup: impl Fn(&str) -> Option<String>,
        config_file: Option<&Path>,
    ) -> Result<Self, ConfigError> {
        let environment = load_environment(environment_lookup)?;
        let assistant = load_toml(config_file)?;

        Ok(Self {
            database_url: environment.database_url,
            server: environment.server,
            session: environment.session,
            assistant,
        })
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::{AppConfig, AssistantConfig};

    static TEMP_FILE_COUNTER: AtomicUsize = AtomicUsize::new(0);

    struct TempFile(PathBuf);

    impl TempFile {
        fn new(contents: &str) -> Self {
            let number = TEMP_FILE_COUNTER.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "calco-app-config-test-{}-{number}",
                std::process::id()
            ));
            fs::write(&path, contents).expect("write temporary test file");
            Self(path)
        }
    }

    impl Drop for TempFile {
        fn drop(&mut self) {
            let _ = fs::remove_file(&self.0);
        }
    }

    #[test]
    fn assembles_environment_and_toml_results_into_runtime_config() {
        let config_file = TempFile::new("[assistant]\nenabled = false\n");
        let config = AppConfig::from_sources(
            |name| match name {
                "DATABASE_URL" => Some("postgres://calco:calco/calco".into()),
                "APP_HOST" => Some("127.0.0.1".into()),
                "APP_PORT" => Some("4321".into()),
                "SESSION_COOKIE_NAME" => Some("custom_session".into()),
                "SESSION_COOKIE_SECURE" => Some("true".into()),
                "SESSION_TTL_SECONDS" => Some("60".into()),
                "CORS_ALLOWED_ORIGINS" => Some("https://calco.example".into()),
                _ => None,
            },
            Some(&config_file.0),
        )
        .unwrap();

        assert_eq!(config.database_url, "postgres://calco:calco/calco");
        assert_eq!(config.server.bind_addr.to_string(), "127.0.0.1:4321");
        assert_eq!(config.server.cors_allowed_origins.len(), 1);
        assert_eq!(config.session.cookie_name, "custom_session");
        assert!(config.session.cookie_secure);
        assert_eq!(config.session.ttl_seconds, 60);
        assert_eq!(config.assistant, AssistantConfig::Disabled);
    }
}
