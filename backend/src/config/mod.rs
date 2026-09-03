//! Platform configuration loaded during process startup.
//!
//! Environment variables continue to own server, database, session, and CORS
//! settings. `CALCO_CONFIG_FILE` reserves a TOML file for deployment-wide
//! application features introduced in later changes.

mod environment;
mod file;

use std::path::PathBuf;

pub use environment::{EnvironmentConfig, SessionEnvironmentConfig};
pub use file::{
    AiAuthenticationSettings, AiEnabledSettings, AiModel, AiRuntimeSettings, FileConfig,
};

/// All startup settings required by application composition.
#[derive(Clone)]
pub struct AppConfig {
    pub environment: EnvironmentConfig,
    pub file: FileConfig,
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
        config_file: Option<&std::path::Path>,
    ) -> Result<Self, ConfigError> {
        let environment = EnvironmentConfig::from_lookup(environment_lookup)?;
        let file = file::load_config_file(config_file)?;

        Ok(Self { environment, file })
    }
}

/// Startup-configuration failures contain field names, never operator values
/// or configuration-file paths.
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
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::{AiAuthenticationSettings, AppConfig, ConfigError, EnvironmentConfig, FileConfig};

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
    fn app_config_retains_typed_file_config() {
        let config_file = TempFile::new("");
        let config = AppConfig::from_sources(
            |name| match name {
                "DATABASE_URL" => Some("postgres://calco:calco/calco".into()),
                _ => None,
            },
            Some(config_file.path()),
        )
        .unwrap();

        assert_eq!(config.file, FileConfig::default());
    }

    #[test]
    fn absent_config_path_loads_default_typed_config() {
        assert_eq!(
            super::file::load_config_file(None),
            Ok(FileConfig::default())
        );
    }

    #[test]
    fn empty_or_comment_only_config_file_is_valid() {
        let empty = TempFile::new("");
        let comments = TempFile::new("# Feature configuration is optional.\n");

        assert_eq!(
            super::file::load_config_file(Some(empty.path())),
            Ok(FileConfig::default())
        );
        assert_eq!(
            super::file::load_config_file(Some(comments.path())),
            Ok(FileConfig::default())
        );
    }

    #[test]
    fn configured_toml_path_must_be_readable_without_exposing_its_path() {
        let missing_path = std::env::temp_dir().join(format!(
            "calco-config-missing-contains-no-secret-{}",
            std::process::id()
        ));

        let error = super::file::load_config_file(Some(&missing_path))
            .err()
            .unwrap();

        assert_eq!(error, ConfigError::ConfigFileUnreadable);
        assert!(!format!("{error:?} {error}").contains("contains-no-secret"));
    }

    #[test]
    fn configured_file_must_contain_valid_toml() {
        let config = TempFile::new("[feature\nenabled = true\n");

        assert_eq!(
            super::file::load_config_file(Some(config.path())),
            Err(ConfigError::InvalidToml)
        );
    }

    #[test]
    fn unknown_fields_fail_typed_deserialization() {
        for contents in [
            "unexpected = true\n",
            "[ai]\nenabled = false\nunexpected = true\n",
            "[ai.authentication]\nkind = \"none\"\n",
        ] {
            let config = TempFile::new(contents);

            assert_eq!(
                super::file::load_config_file(Some(config.path())),
                Err(ConfigError::InvalidToml)
            );
        }
    }

    #[test]
    fn absent_ai_section_and_explicitly_disabled_ai_are_runtime_disabled() {
        for contents in [
            "# AI configuration is optional\n",
            "[ai]\nenabled = false\n",
            "[ai]\nenabled = false\nendpoint = \"\"\nmodel = \"\"\n[ai.authentication]\nkind = \"none\"\n",
        ] {
            let config = TempFile::new(contents);

            assert_eq!(
                super::file::load_config_file(Some(config.path())),
                Ok(FileConfig::default())
            );
        }
    }

    #[test]
    fn enabled_ai_deserializes_to_complete_runtime_settings() {
        let config = TempFile::new(
            "[ai]\nenabled = true\nendpoint = \"https://provider.example/v1/chat/completions\"\nmodel = \"  vision-model  \"\nsupports_images = true\n[ai.authentication]\nkind = \"header\"\nheader_name = \"api-key\"\napi_key_file = \"/run/secrets/provider-key\"\n",
        );

        let loaded = super::file::load_config_file(Some(config.path())).unwrap();
        let settings = loaded.ai.as_enabled().expect("enabled AI settings");

        assert_eq!(
            settings.endpoint.as_str(),
            "https://provider.example/v1/chat/completions"
        );
        assert_eq!(settings.model.as_str(), "vision-model");
        assert!(settings.supports_images);
        assert_eq!(
            settings.authentication,
            AiAuthenticationSettings::Header {
                header_name: "api-key".parse().unwrap(),
                api_key_file: PathBuf::from("/run/secrets/provider-key"),
            }
        );
    }

    #[test]
    fn tracked_assistant_configs_load_without_reading_their_key_files() {
        let config_directory = Path::new(env!("CARGO_MANIFEST_DIR")).join("../assistant-config");
        let expected = [
            (
                "groq.toml",
                "https://api.groq.com/openai/v1/chat/completions",
                "qwen/qwen3.6-27b",
                "assistant-config/groq-api-key",
            ),
            (
                "openrouter.toml",
                "https://openrouter.ai/api/v1/chat/completions",
                "openrouter/free",
                "assistant-config/openrouter-api-key",
            ),
        ];

        for (file_name, endpoint, model, api_key_file) in expected {
            let loaded = super::file::load_config_file(Some(&config_directory.join(file_name)))
                .expect("tracked config loads without a credential file");
            let settings = loaded.ai.as_enabled().expect("AI is enabled");

            assert_eq!(settings.endpoint.as_str(), endpoint);
            assert_eq!(settings.model.as_str(), model);
            assert!(settings.supports_images);
            assert_eq!(
                settings.authentication,
                AiAuthenticationSettings::Bearer {
                    api_key_file: PathBuf::from(api_key_file),
                }
            );
        }
    }

    #[test]
    fn malformed_unknown_wrong_type_and_incomplete_ai_config_are_invalid_toml() {
        let invalid_configs = [
            "[ai\nenabled = true\n",
            "[ai]\nenabled = true\nunknown = true\n",
            "[ai]\nenabled = \"true\"\n",
            "[ai]\nenabled = true\nendpoint = 42\nmodel = \"model\"\n[ai.authentication]\nkind = \"none\"\n",
            "[ai]\nenabled = true\nendpoint = \"http://provider.example\"\nmodel = 42\n[ai.authentication]\nkind = \"none\"\n",
            "[ai]\nenabled = true\nendpoint = \"http://provider.example\"\nmodel = \"model\"\nsupports_images = \"yes\"\n[ai.authentication]\nkind = \"none\"\n",
            "[ai]\nenabled = true\nendpoint = \"http://provider.example\"\nmodel = \"model\"\n[ai.authentication]\nkind = \"none\"\nunexpected = true\n",
            "[ai]\nenabled = true\nmodel = \"model\"\n[ai.authentication]\nkind = \"none\"\n",
            "[ai]\nenabled = true\nendpoint = \"http://provider.example\"\n[ai.authentication]\nkind = \"none\"\n",
            "[ai]\nenabled = true\nendpoint = \"http://provider.example\"\nmodel = \"model\"\n",
            "[ai]\nenabled = true\nendpoint = \"ftp://provider.example\"\nmodel = \"model\"\n[ai.authentication]\nkind = \"none\"\n",
            "[ai]\nenabled = true\nendpoint = \"http://provider.example\"\nmodel = \"   \"\n[ai.authentication]\nkind = \"none\"\n",
        ];

        for contents in invalid_configs {
            let config = TempFile::new(contents);
            assert_eq!(
                super::file::load_config_file(Some(config.path())),
                Err(ConfigError::InvalidToml),
                "{contents}"
            );
        }
    }

    #[test]
    fn authentication_shapes_are_refined_during_deserialization() {
        let invalid_configs = [
            "[ai]\nenabled = true\nendpoint = \"http://provider.example\"\nmodel = \"model\"\n[ai.authentication]\nkind = \"other\"\n",
            "[ai]\nenabled = true\nendpoint = \"http://provider.example\"\nmodel = \"model\"\n[ai.authentication]\nkind = \"none\"\napi_key_file = \"/run/key\"\n",
            "[ai]\nenabled = true\nendpoint = \"http://provider.example\"\nmodel = \"model\"\n[ai.authentication]\nkind = \"bearer\"\n",
            "[ai]\nenabled = true\nendpoint = \"http://provider.example\"\nmodel = \"model\"\n[ai.authentication]\nkind = \"bearer\"\napi_key_file = \"\"\n",
            "[ai]\nenabled = true\nendpoint = \"http://provider.example\"\nmodel = \"model\"\n[ai.authentication]\nkind = \"bearer\"\napi_key_file = \"/run/key\"\nheader_name = \"api-key\"\n",
            "[ai]\nenabled = true\nendpoint = \"http://provider.example\"\nmodel = \"model\"\n[ai.authentication]\nkind = \"header\"\napi_key_file = \"/run/key\"\n",
            "[ai]\nenabled = true\nendpoint = \"http://provider.example\"\nmodel = \"model\"\n[ai.authentication]\nkind = \"header\"\nheader_name = \"not a header\"\napi_key_file = \"/run/key\"\n",
            "[ai]\nenabled = true\nendpoint = \"http://provider.example\"\nmodel = \"model\"\n[ai.authentication]\nkind = \"header\"\nheader_name = \"api-key\"\napi_key_file = \"\"\n",
        ];

        for contents in invalid_configs {
            let config = TempFile::new(contents);
            assert_eq!(
                super::file::load_config_file(Some(config.path())),
                Err(ConfigError::InvalidToml),
                "{contents}"
            );
        }
    }

    #[test]
    fn environment_loading_is_typed_and_applies_defaults() {
        let config = EnvironmentConfig::from_lookup(|name| match name {
            "DATABASE_URL" => Some("postgres://calco:calco@localhost/calco".into()),
            _ => None,
        })
        .unwrap();

        assert_eq!(
            config.database_url,
            "postgres://calco:calco@localhost/calco"
        );
        assert_eq!(config.bind_addr.to_string(), "0.0.0.0:3001");
        assert_eq!(config.session.cookie_name, "calco_session");
        assert!(!config.session.cookie_secure);
        assert_eq!(config.session.ttl_seconds, 604800);
        assert!(config.cors_allowed_origins.is_empty());
    }

    #[test]
    fn environment_loading_parses_all_typed_values() {
        let config = EnvironmentConfig::from_lookup(|name| match name {
            "DATABASE_URL" => Some("postgres://calco:calco@localhost/calco".into()),
            "APP_HOST" => Some("127.0.0.1".into()),
            "APP_PORT" => Some("4321".into()),
            "SESSION_COOKIE_NAME" => Some("custom_session".into()),
            "SESSION_COOKIE_SECURE" => Some("true".into()),
            "SESSION_TTL_SECONDS" => Some("60".into()),
            "CORS_ALLOWED_ORIGINS" => Some(" https://one.example, ,https://two.example ".into()),
            _ => None,
        })
        .unwrap();

        assert_eq!(config.bind_addr.to_string(), "127.0.0.1:4321");
        assert_eq!(config.session.cookie_name, "custom_session");
        assert!(config.session.cookie_secure);
        assert_eq!(config.session.ttl_seconds, 60);
        assert_eq!(
            config
                .cors_allowed_origins
                .iter()
                .map(|origin| origin.to_str().unwrap())
                .collect::<Vec<_>>(),
            ["https://one.example", "https://two.example"]
        );
    }

    #[test]
    fn environment_loading_rejects_missing_or_invalid_values() {
        let valid_database = || Some("postgres://calco:calco@localhost/calco".to_owned());

        assert_eq!(
            EnvironmentConfig::from_lookup(|_| None).err().unwrap(),
            ConfigError::DatabaseUrlMissing
        );
        assert_eq!(
            EnvironmentConfig::from_lookup(|name| match name {
                "DATABASE_URL" => valid_database(),
                "APP_HOST" => Some("not-an-ip".into()),
                _ => None,
            })
            .err()
            .unwrap(),
            ConfigError::InvalidAppHost
        );
        assert_eq!(
            EnvironmentConfig::from_lookup(|name| match name {
                "DATABASE_URL" => valid_database(),
                "APP_PORT" => Some("not-a-port".into()),
                _ => None,
            })
            .err()
            .unwrap(),
            ConfigError::InvalidAppPort
        );
        for value in ["TRUE", "1", "yes"] {
            assert_eq!(
                EnvironmentConfig::from_lookup(|name| match name {
                    "DATABASE_URL" => valid_database(),
                    "SESSION_COOKIE_SECURE" => Some(value.into()),
                    _ => None,
                })
                .err()
                .unwrap(),
                ConfigError::InvalidSessionCookieSecure
            );
        }
        for value in ["0", "-1", "not-a-number"] {
            assert_eq!(
                EnvironmentConfig::from_lookup(|name| match name {
                    "DATABASE_URL" => valid_database(),
                    "SESSION_TTL_SECONDS" => Some(value.into()),
                    _ => None,
                })
                .err()
                .unwrap(),
                ConfigError::InvalidSessionTtl
            );
        }
        assert_eq!(
            EnvironmentConfig::from_lookup(|name| match name {
                "DATABASE_URL" => valid_database(),
                "CORS_ALLOWED_ORIGINS" => Some("https://valid.example,invalid\nvalue".into()),
                _ => None,
            })
            .err()
            .unwrap(),
            ConfigError::InvalidCorsAllowedOrigins
        );
    }
}
