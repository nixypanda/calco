//! Platform configuration loaded during process startup.
//!
//! Configuration is deliberately kept outside the bounded contexts. Environment
//! settings describe the server process, while the optional `calco-config.toml`
//! file describes the deployment-wide AI capability. AI credentials are never
//! retained by [`AppConfig`]; an enabled configuration retains only the path to
//! the restricted credential file and reads its contents on demand.

mod environment;
mod file;

use std::fmt;
use std::path::{Path, PathBuf};

use url::Url;
use zeroize::Zeroizing;

pub use environment::{EnvironmentConfig, SessionEnvironmentConfig};

/// All startup settings required by application composition.
#[derive(Clone)]
pub struct AppConfig {
    pub environment: EnvironmentConfig,
    pub ai: AiRuntimeSettings,
}

impl AppConfig {
    /// Loads process settings from the environment and optional AI settings from
    /// the file named by `CALCO_CONFIG_FILE`.
    pub fn from_env() -> Result<Self, ConfigError> {
        let environment = EnvironmentConfig::from_env()?;
        let config_file = std::env::var_os("CALCO_CONFIG_FILE").map(PathBuf::from);
        let ai = load_ai_settings(config_file.as_deref())?;

        Ok(Self { environment, ai })
    }
}

/// AI settings that are safe to keep during composition. The enabled variant
/// does not include an API key.
#[derive(Clone, PartialEq, Eq)]
pub enum AiRuntimeSettings {
    Disabled,
    Enabled(AiEnabledSettings),
}

impl AiRuntimeSettings {
    pub fn is_enabled(&self) -> bool {
        matches!(self, Self::Enabled(_))
    }

    pub fn as_enabled(&self) -> Option<&AiEnabledSettings> {
        match self {
            Self::Disabled => None,
            Self::Enabled(settings) => Some(settings),
        }
    }
}

impl fmt::Debug for AiRuntimeSettings {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Disabled => formatter.write_str("AiRuntimeSettings::Disabled"),
            Self::Enabled(settings) => formatter
                .debug_tuple("AiRuntimeSettings::Enabled")
                .field(settings)
                .finish(),
        }
    }
}

/// Complete, validated settings for an enabled OpenAI-compatible deployment.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiEnabledSettings {
    pub endpoint: Url,
    pub model: String,
    pub supports_images: bool,
    pub authentication: AiAuthenticationSettings,
}

/// Authentication metadata for an enabled AI deployment. Credential file paths
/// are deployment metadata, not credential values.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AiAuthenticationSettings {
    None,
    Bearer {
        api_key_file: PathBuf,
    },
    Header {
        header_name: axum::http::HeaderName,
        api_key_file: PathBuf,
    },
}

impl AiAuthenticationSettings {
    /// Reads the configured API key only when a later provider adapter needs it.
    /// The caller receives a redacted, zeroizing value; `AppConfig` itself never
    /// retains the credential.
    pub fn read_api_key(&self) -> Result<Option<ApiKey>, ConfigError> {
        let Some(path) = self.api_key_file() else {
            return Ok(None);
        };

        let value = std::fs::read_to_string(path).map_err(|_| ConfigError::ApiKeyFileUnreadable)?;
        ApiKey::new(value).map(Some)
    }

    fn api_key_file(&self) -> Option<&Path> {
        match self {
            Self::None => None,
            Self::Bearer { api_key_file } | Self::Header { api_key_file, .. } => Some(api_key_file),
        }
    }
}

/// A credential value intended to be moved directly into the provider adapter.
/// It cannot be formatted with its contents and its allocation is zeroed on
/// drop. Only crate code that constructs HTTP authentication may expose it.
#[allow(
    dead_code,
    reason = "the provider adapter is introduced in a later implementation slice"
)]
pub struct ApiKey(Zeroizing<String>);

impl ApiKey {
    fn new(value: String) -> Result<Self, ConfigError> {
        let value = value
            .strip_suffix("\r\n")
            .or_else(|| value.strip_suffix('\n'))
            .or_else(|| value.strip_suffix('\r'))
            .unwrap_or(&value)
            .to_owned();
        if value.is_empty() {
            return Err(ConfigError::ApiKeyFileEmpty);
        }
        Ok(Self(Zeroizing::new(value)))
    }

    #[allow(
        dead_code,
        reason = "the provider adapter is introduced in a later implementation slice"
    )]
    pub(crate) fn expose_secret(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for ApiKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("ApiKey([REDACTED])")
    }
}

/// Loads AI settings from an optional TOML path. An absent path or an absent
/// `[ai]` section intentionally disables the capability.
pub fn load_ai_settings(config_file: Option<&Path>) -> Result<AiRuntimeSettings, ConfigError> {
    let Some(config_file) = config_file else {
        return Ok(AiRuntimeSettings::Disabled);
    };

    file::load_ai_settings(config_file)
}

/// Startup-configuration failures deliberately contain field names and no
/// operator values. In particular, they never retain or format API-key content.
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum ConfigError {
    #[error("DATABASE_URL must be set")]
    DatabaseUrlMissing,
    #[error("APP_HOST must be a valid IP address")]
    InvalidAppHost,
    #[error("APP_PORT must be a valid port number")]
    InvalidAppPort,
    #[error("SESSION_COOKIE_SECURE must be either true or false")]
    InvalidSessionCookieSecure,
    #[error("SESSION_TTL_SECONDS must be a positive integer")]
    InvalidSessionTtl,
    #[error("CORS_ALLOWED_ORIGINS contains an invalid header value")]
    InvalidCorsAllowedOrigins,
    #[error("CALCO_CONFIG_FILE could not be read")]
    ConfigFileUnreadable,
    #[error("CALCO_CONFIG_FILE contains invalid TOML")]
    InvalidToml,
    #[error("invalid configuration for {field}")]
    InvalidField { field: &'static str },
    #[error("AI authentication API key file could not be read")]
    ApiKeyFileUnreadable,
    #[error("AI authentication API key file is empty")]
    ApiKeyFileEmpty,
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::{
        AiAuthenticationSettings, AiRuntimeSettings, ConfigError, EnvironmentConfig,
        load_ai_settings,
    };

    static TEMP_FILE_COUNTER: AtomicUsize = AtomicUsize::new(0);

    struct TempFile(PathBuf);

    impl TempFile {
        fn new(contents: &str) -> Self {
            let number = TEMP_FILE_COUNTER.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir()
                .join(format!("calco-config-test-{}-{number}", std::process::id()));
            fs::write(&path, contents).expect("write temporary test file");
            Self(path)
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TempFile {
        fn drop(&mut self) {
            let _ = fs::remove_file(&self.0);
        }
    }

    #[test]
    fn absent_config_path_disables_ai() {
        assert_eq!(load_ai_settings(None).unwrap(), AiRuntimeSettings::Disabled);
    }

    #[test]
    fn missing_ai_section_disables_ai() {
        let config = TempFile::new("# AI configuration is optional\n");

        assert_eq!(
            load_ai_settings(Some(config.path())).unwrap(),
            AiRuntimeSettings::Disabled
        );
    }

    #[test]
    fn explicitly_disabled_partial_config_is_accepted() {
        let config = TempFile::new("[ai]\nenabled = false\n");

        assert_eq!(
            load_ai_settings(Some(config.path())).unwrap(),
            AiRuntimeSettings::Disabled
        );
    }

    #[test]
    fn configured_toml_path_must_be_readable_without_exposing_its_path() {
        let missing_path = std::env::temp_dir().join(format!(
            "calco-config-missing-contains-no-secret-{}",
            std::process::id()
        ));

        let error = load_ai_settings(Some(&missing_path)).unwrap_err();

        assert_eq!(error, ConfigError::ConfigFileUnreadable);
        assert!(!format!("{error:?} {error}").contains("contains-no-secret"));
    }

    #[test]
    fn enabled_config_requires_endpoint_model_and_authentication() {
        let missing_endpoint = TempFile::new("[ai]\nenabled = true\nmodel = \"model\"\n");
        assert_eq!(
            load_ai_settings(Some(missing_endpoint.path())).unwrap_err(),
            ConfigError::InvalidField {
                field: "ai.endpoint"
            }
        );

        let missing_model = TempFile::new(
            "[ai]\nenabled = true\nendpoint = \"http://127.0.0.1/v1/chat/completions\"\n",
        );
        assert_eq!(
            load_ai_settings(Some(missing_model.path())).unwrap_err(),
            ConfigError::InvalidField { field: "ai.model" }
        );

        let missing_authentication = TempFile::new(
            "[ai]\nenabled = true\nendpoint = \"http://127.0.0.1/v1/chat/completions\"\nmodel = \"model\"\n",
        );
        assert_eq!(
            load_ai_settings(Some(missing_authentication.path())).unwrap_err(),
            ConfigError::InvalidField {
                field: "ai.authentication"
            }
        );
    }

    #[test]
    fn authentication_variants_require_and_forbid_the_right_fields() {
        let key = TempFile::new("very-secret-api-key\n");
        let none = TempFile::new(
            "[ai]\nenabled = true\nendpoint = \"http://127.0.0.1/v1/chat/completions\"\nmodel = \"model\"\n[ai.authentication]\nkind = \"none\"\n",
        );
        let bearer = TempFile::new(&format!(
            "[ai]\nenabled = true\nendpoint = \"http://127.0.0.1/v1/chat/completions\"\nmodel = \"model\"\n[ai.authentication]\nkind = \"bearer\"\napi_key_file = \"{}\"\n",
            key.path().display()
        ));
        let header = TempFile::new(&format!(
            "[ai]\nenabled = true\nendpoint = \"http://127.0.0.1/v1/chat/completions\"\nmodel = \"model\"\n[ai.authentication]\nkind = \"header\"\nheader_name = \"api-key\"\napi_key_file = \"{}\"\n",
            key.path().display()
        ));

        assert!(matches!(
            load_ai_settings(Some(none.path())).unwrap(),
            AiRuntimeSettings::Enabled(_)
        ));
        assert!(matches!(
            load_ai_settings(Some(bearer.path())).unwrap(),
            AiRuntimeSettings::Enabled(_)
        ));
        assert!(matches!(
            load_ai_settings(Some(header.path())).unwrap(),
            AiRuntimeSettings::Enabled(_)
        ));

        let bearer_without_key = TempFile::new(
            "[ai]\nenabled = true\nendpoint = \"http://127.0.0.1/v1/chat/completions\"\nmodel = \"model\"\n[ai.authentication]\nkind = \"bearer\"\n",
        );
        assert_eq!(
            load_ai_settings(Some(bearer_without_key.path())).unwrap_err(),
            ConfigError::InvalidField {
                field: "ai.authentication.api_key_file"
            }
        );

        let none_with_key = TempFile::new(&format!(
            "[ai]\nenabled = true\nendpoint = \"http://127.0.0.1/v1/chat/completions\"\nmodel = \"model\"\n[ai.authentication]\nkind = \"none\"\napi_key_file = \"{}\"\n",
            key.path().display()
        ));
        assert_eq!(
            load_ai_settings(Some(none_with_key.path())).unwrap_err(),
            ConfigError::InvalidField {
                field: "ai.authentication.api_key_file"
            }
        );

        let bearer_with_header_name = TempFile::new(&format!(
            "[ai]\nenabled = true\nendpoint = \"http://127.0.0.1/v1/chat/completions\"\nmodel = \"model\"\n[ai.authentication]\nkind = \"bearer\"\nheader_name = \"api-key\"\napi_key_file = \"{}\"\n",
            key.path().display()
        ));
        assert_eq!(
            load_ai_settings(Some(bearer_with_header_name.path())).unwrap_err(),
            ConfigError::InvalidField {
                field: "ai.authentication.header_name"
            }
        );
    }

    #[test]
    fn header_auth_requires_header_name() {
        let key = TempFile::new("api-key");
        let config = TempFile::new(&format!(
            "[ai]\nenabled = true\nendpoint = \"http://127.0.0.1/v1/chat/completions\"\nmodel = \"model\"\n[ai.authentication]\nkind = \"header\"\napi_key_file = \"{}\"\n",
            key.path().display()
        ));

        assert_eq!(
            load_ai_settings(Some(config.path())).unwrap_err(),
            ConfigError::InvalidField {
                field: "ai.authentication.header_name"
            }
        );
    }

    #[test]
    fn header_auth_requires_api_key_file() {
        let config = TempFile::new(
            "[ai]\nenabled = true\nendpoint = \"http://127.0.0.1/v1/chat/completions\"\nmodel = \"model\"\n[ai.authentication]\nkind = \"header\"\nheader_name = \"api-key\"\n",
        );

        assert_eq!(
            load_ai_settings(Some(config.path())).unwrap_err(),
            ConfigError::InvalidField {
                field: "ai.authentication.api_key_file"
            }
        );
    }

    #[test]
    fn none_auth_forbids_header_name() {
        let config = TempFile::new(
            "[ai]\nenabled = true\nendpoint = \"http://127.0.0.1/v1/chat/completions\"\nmodel = \"model\"\n[ai.authentication]\nkind = \"none\"\nheader_name = \"api-key\"\n",
        );

        assert_eq!(
            load_ai_settings(Some(config.path())).unwrap_err(),
            ConfigError::InvalidField {
                field: "ai.authentication.header_name"
            }
        );
    }

    #[test]
    fn api_key_read_failures_and_debug_output_do_not_expose_key_contents() {
        let missing_key_path = std::env::temp_dir().join(format!(
            "calco-config-missing-key-very-secret-api-key-{}",
            std::process::id()
        ));
        let config = TempFile::new(&format!(
            "[ai]\nenabled = true\nendpoint = \"http://127.0.0.1/v1/chat/completions\"\nmodel = \"model\"\n[ai.authentication]\nkind = \"bearer\"\napi_key_file = \"{}\"\n",
            missing_key_path.display()
        ));
        let error = load_ai_settings(Some(config.path())).unwrap_err();
        let rendered = format!("{error:?} {error}");
        assert!(!rendered.contains("very-secret-api-key"));
        assert_eq!(error, ConfigError::ApiKeyFileUnreadable);

        let key_file = TempFile::new("very-secret-api-key\n");
        let authentication = AiAuthenticationSettings::Bearer {
            api_key_file: key_file.path().to_owned(),
        };
        let key = authentication.read_api_key().unwrap().unwrap();
        assert_eq!(key.expose_secret(), "very-secret-api-key");
        assert!(!format!("{key:?}").contains("very-secret-api-key"));
    }

    #[test]
    fn empty_api_key_file_is_rejected() {
        let key = TempFile::new("");
        let config = TempFile::new(&format!(
            "[ai]\nenabled = true\nendpoint = \"http://127.0.0.1/v1/chat/completions\"\nmodel = \"model\"\n[ai.authentication]\nkind = \"bearer\"\napi_key_file = \"{}\"\n",
            key.path().display()
        ));

        assert_eq!(
            load_ai_settings(Some(config.path())).unwrap_err(),
            ConfigError::ApiKeyFileEmpty
        );
    }

    #[test]
    fn api_key_preserves_spaces_and_removes_one_conventional_line_terminator() {
        let key_file = TempFile::new("  api-key with spaces  \r\n");
        let authentication = AiAuthenticationSettings::Bearer {
            api_key_file: key_file.path().to_owned(),
        };

        let key = authentication.read_api_key().unwrap().unwrap();

        assert_eq!(key.expose_secret(), "  api-key with spaces  ");
    }

    #[test]
    fn invalid_toml_and_validation_errors_are_safe_and_identify_fields() {
        let invalid_toml = TempFile::new("[ai\nenabled = true\n");
        assert_eq!(
            load_ai_settings(Some(invalid_toml.path())).unwrap_err(),
            ConfigError::InvalidToml
        );

        let invalid_endpoint = TempFile::new(
            "[ai]\nenabled = true\nendpoint = \"not a URL\"\nmodel = \"model\"\n[ai.authentication]\nkind = \"none\"\n",
        );
        let error = load_ai_settings(Some(invalid_endpoint.path())).unwrap_err();
        assert_eq!(
            error,
            ConfigError::InvalidField {
                field: "ai.endpoint"
            }
        );
        assert!(error.to_string().contains("ai.endpoint"));
    }

    #[test]
    fn environment_loading_is_typed_and_rejects_invalid_values() {
        let config = EnvironmentConfig::from_lookup(|name| match name {
            "DATABASE_URL" => Some("postgres://calco:calco@localhost/calco".into()),
            "APP_HOST" => Some("127.0.0.1".into()),
            "APP_PORT" => Some("4321".into()),
            "SESSION_COOKIE_SECURE" => Some("true".into()),
            "SESSION_TTL_SECONDS" => Some("60".into()),
            _ => None,
        })
        .unwrap();
        assert_eq!(config.bind_addr.port(), 4321);
        assert!(config.session.cookie_secure);
        assert_eq!(config.session.ttl_seconds, 60);

        let error = EnvironmentConfig::from_lookup(|name| match name {
            "DATABASE_URL" => Some("postgres://calco:calco@localhost/calco".into()),
            "APP_PORT" => Some("not-a-port".into()),
            _ => None,
        })
        .unwrap_err();
        assert_eq!(error, ConfigError::InvalidAppPort);
    }
}
