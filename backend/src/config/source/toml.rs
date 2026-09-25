use std::path::{Path, PathBuf};
use std::str::FromStr;

use axum::http::HeaderName;
use serde::Deserialize;
use url::Url;

use super::super::{
    AssistantAuthentication, AssistantConfig, AssistantModel, AssistantProviderConfig, ConfigError,
};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawFileConfig {
    assistant: Option<RawAssistantConfig>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawAssistantConfig {
    enabled: bool,
    endpoint: Option<String>,
    model: Option<String>,
    #[serde(default)]
    supports_images: bool,
    authentication: Option<RawAuthentication>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawAuthentication {
    kind: RawAuthenticationKind,
    api_key_file: Option<PathBuf>,
    header_name: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
enum RawAuthenticationKind {
    None,
    Bearer,
    Header,
}

impl RawFileConfig {
    fn into_assistant_config(self) -> Result<AssistantConfig, &'static str> {
        let Some(assistant) = self.assistant else {
            return Ok(AssistantConfig::Disabled);
        };

        if !assistant.enabled {
            return Ok(AssistantConfig::Disabled);
        }

        let endpoint = assistant
            .endpoint
            .ok_or("assistant.endpoint is required when the assistant is enabled")
            .and_then(parse_endpoint)?;
        let model = assistant
            .model
            .ok_or("assistant.model is required when the assistant is enabled")
            .and_then(parse_model)?;
        let authentication = assistant
            .authentication
            .ok_or("assistant.authentication is required when the assistant is enabled")?
            .into_config()?;

        Ok(AssistantConfig::Enabled(AssistantProviderConfig {
            endpoint,
            model,
            supports_images: assistant.supports_images,
            authentication,
        }))
    }
}

fn parse_endpoint(value: String) -> Result<Url, &'static str> {
    let endpoint =
        Url::parse(&value).map_err(|_| "assistant.endpoint must be an HTTP(S) URL with a host")?;
    if matches!(endpoint.scheme(), "http" | "https") && endpoint.host().is_some() {
        Ok(endpoint)
    } else {
        Err("assistant.endpoint must be an HTTP(S) URL with a host")
    }
}

fn parse_model(value: String) -> Result<AssistantModel, &'static str> {
    let value = value.trim();
    if value.is_empty() {
        return Err("assistant.model must not be empty");
    }
    Ok(AssistantModel::new(value.to_owned()))
}

impl RawAuthentication {
    fn into_config(self) -> Result<AssistantAuthentication, &'static str> {
        match self.kind {
            RawAuthenticationKind::None => {
                if self.api_key_file.is_some() || self.header_name.is_some() {
                    return Err("none authentication cannot include API-key settings");
                }
                Ok(AssistantAuthentication::None)
            }
            RawAuthenticationKind::Bearer => {
                if self.header_name.is_some() {
                    return Err("bearer authentication cannot include a header name");
                }
                Ok(AssistantAuthentication::Bearer {
                    api_key_file: required_api_key_file(self.api_key_file)?,
                })
            }
            RawAuthenticationKind::Header => {
                let header_name = self
                    .header_name
                    .ok_or("header authentication requires a header name")?;
                let header_name = HeaderName::from_str(header_name.trim())
                    .map_err(|_| "header authentication requires a valid header name")?;
                Ok(AssistantAuthentication::Header {
                    header_name,
                    api_key_file: required_api_key_file(self.api_key_file)?,
                })
            }
        }
    }
}

fn required_api_key_file(value: Option<PathBuf>) -> Result<PathBuf, &'static str> {
    let path = value.ok_or("authentication requires an API-key file path")?;
    if path.as_os_str().is_empty() {
        return Err("authentication requires a non-empty API-key file path");
    }
    Ok(path)
}

pub(in crate::config) fn load(path: Option<&Path>) -> Result<AssistantConfig, ConfigError> {
    let Some(path) = path else {
        return Ok(AssistantConfig::Disabled);
    };

    let raw = std::fs::read_to_string(path).map_err(|_| ConfigError::ConfigFileUnreadable)?;
    let raw: RawFileConfig = toml_edit::de::from_str(&raw).map_err(|_| ConfigError::InvalidToml)?;
    raw.into_assistant_config()
        .map_err(|_| ConfigError::InvalidToml)
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::super::super::{AssistantAuthentication, AssistantConfig, ConfigError};
    use super::load;

    static TEMP_FILE_COUNTER: AtomicUsize = AtomicUsize::new(0);

    struct TempFile(PathBuf);

    impl TempFile {
        fn new(contents: &str) -> Self {
            let number = TEMP_FILE_COUNTER.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "calco-toml-config-test-{}-{number}",
                std::process::id()
            ));
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
    fn missing_path_empty_file_and_comment_only_file_disable_the_assistant() {
        assert_eq!(load(None), Ok(AssistantConfig::Disabled));

        for contents in [
            "",
            r#"# Assistant configuration is optional.
"#,
        ] {
            let file = TempFile::new(contents);
            assert_eq!(load(Some(file.path())), Ok(AssistantConfig::Disabled));
        }
    }

    #[test]
    fn unreadable_paths_do_not_leak_path_contents() {
        let missing_path = std::env::temp_dir().join(format!(
            "calco-config-missing-contains-no-secret-{}",
            std::process::id()
        ));
        let error = load(Some(&missing_path)).err().unwrap();

        assert_eq!(error, ConfigError::ConfigFileUnreadable);
        assert!(!format!("{error:?} {error}").contains("contains-no-secret"));
    }

    #[test]
    fn malformed_toml_is_rejected() {
        let file = TempFile::new(
            r#"[assistant
enabled = true
"#,
        );
        assert_eq!(load(Some(file.path())), Err(ConfigError::InvalidToml));
    }

    #[test]
    fn unknown_fields_are_rejected() {
        for contents in [
            r#"unexpected = true
"#,
            r#"[assistant]
enabled = false
unexpected = true
"#,
            r#"[assistant.authentication]
kind = "none"
"#,
        ] {
            let file = TempFile::new(contents);
            assert_eq!(
                load(Some(file.path())),
                Err(ConfigError::InvalidToml),
                "{contents}"
            );
        }
    }

    #[test]
    fn absent_and_explicitly_disabled_assistant_configs_are_disabled() {
        for contents in [
            r#"# Assistant configuration is optional
"#,
            r#"[assistant]
enabled = false
"#,
            r#"[assistant]
enabled = false
endpoint = ""
model = ""

[assistant.authentication]
kind = "none"
"#,
        ] {
            let file = TempFile::new(contents);
            assert_eq!(load(Some(file.path())), Ok(AssistantConfig::Disabled));
        }
    }

    #[test]
    fn complete_enabled_config_is_runtime_ready() {
        let file = TempFile::new(
            r#"[assistant]
enabled = true
endpoint = "https://provider.example/v1/chat/completions"
model = "  vision-model  "
supports_images = true

[assistant.authentication]
kind = "header"
header_name = "api-key"
api_key_file = "/run/secrets/provider-key"
"#,
        );
        let loaded = load(Some(file.path())).unwrap();
        let settings = loaded.as_enabled().expect("assistant is enabled");

        assert_eq!(
            settings.endpoint.as_str(),
            "https://provider.example/v1/chat/completions"
        );
        assert_eq!(settings.model.as_str(), "vision-model");
        assert!(settings.supports_images);
        assert_eq!(
            settings.authentication,
            AssistantAuthentication::Header {
                header_name: "api-key".parse().unwrap(),
                api_key_file: PathBuf::from("/run/secrets/provider-key"),
            }
        );
    }

    #[test]
    fn invalid_urls_and_models_are_rejected() {
        for contents in [
            r#"[assistant]
enabled = true
endpoint = "ftp://provider.example"
model = "model"

[assistant.authentication]
kind = "none"
"#,
            r#"[assistant]
enabled = true
endpoint = "http://provider.example"
model = "   "

[assistant.authentication]
kind = "none"
"#,
            r#"[assistant]
enabled = true
endpoint = "not a URL"
model = "model"

[assistant.authentication]
kind = "none"
"#,
        ] {
            let file = TempFile::new(contents);
            assert_eq!(load(Some(file.path())), Err(ConfigError::InvalidToml));
        }
    }

    #[test]
    fn authentication_variants_are_supported() {
        let cases = [
            (
                r#"[assistant]
enabled = true
endpoint = "http://provider.example"
model = "model"

[assistant.authentication]
kind = "none"
"#,
                AssistantAuthentication::None,
            ),
            (
                r#"[assistant]
enabled = true
endpoint = "http://provider.example"
model = "model"

[assistant.authentication]
kind = "bearer"
api_key_file = "/run/key"
"#,
                AssistantAuthentication::Bearer {
                    api_key_file: PathBuf::from("/run/key"),
                },
            ),
            (
                r#"[assistant]
enabled = true
endpoint = "http://provider.example"
model = "model"

[assistant.authentication]
kind = "header"
header_name = "api-key"
api_key_file = "/run/key"
"#,
                AssistantAuthentication::Header {
                    header_name: "api-key".parse().unwrap(),
                    api_key_file: PathBuf::from("/run/key"),
                },
            ),
        ];

        for (contents, expected) in cases {
            let file = TempFile::new(contents);
            let loaded = load(Some(file.path())).unwrap();
            assert_eq!(loaded.as_enabled().unwrap().authentication, expected);
        }
    }

    #[test]
    fn invalid_authentication_field_combinations_are_rejected() {
        let invalid_configs = [
            r#"[assistant]
enabled = true
endpoint = "http://provider.example"
model = "model"

[assistant.authentication]
kind = "other"
"#,
            r#"[assistant]
enabled = true
endpoint = "http://provider.example"
model = "model"

[assistant.authentication]
kind = "none"
api_key_file = "/run/key"
"#,
            r#"[assistant]
enabled = true
endpoint = "http://provider.example"
model = "model"

[assistant.authentication]
kind = "bearer"
"#,
            r#"[assistant]
enabled = true
endpoint = "http://provider.example"
model = "model"

[assistant.authentication]
kind = "bearer"
api_key_file = ""
"#,
            r#"[assistant]
enabled = true
endpoint = "http://provider.example"
model = "model"

[assistant.authentication]
kind = "bearer"
api_key_file = "/run/key"
header_name = "api-key"
"#,
            r#"[assistant]
enabled = true
endpoint = "http://provider.example"
model = "model"

[assistant.authentication]
kind = "header"
api_key_file = "/run/key"
"#,
            r#"[assistant]
enabled = true
endpoint = "http://provider.example"
model = "model"

[assistant.authentication]
kind = "header"
header_name = "not a header"
api_key_file = "/run/key"
"#,
            r#"[assistant]
enabled = true
endpoint = "http://provider.example"
model = "model"

[assistant.authentication]
kind = "header"
header_name = "api-key"
api_key_file = ""
"#,
        ];

        for contents in invalid_configs {
            let file = TempFile::new(contents);
            assert_eq!(
                load(Some(file.path())),
                Err(ConfigError::InvalidToml),
                "{contents}"
            );
        }
    }

    #[test]
    fn incomplete_or_wrongly_typed_enabled_configs_are_rejected() {
        let invalid_configs = [
            r#"[assistant]
enabled = "true"
"#,
            r#"[assistant]
enabled = true
endpoint = 42
model = "model"

[assistant.authentication]
kind = "none"
"#,
            r#"[assistant]
enabled = true
endpoint = "http://provider.example"
model = 42

[assistant.authentication]
kind = "none"
"#,
            r#"[assistant]
enabled = true
endpoint = "http://provider.example"
model = "model"
supports_images = "yes"

[assistant.authentication]
kind = "none"
"#,
            r#"[assistant]
enabled = true
model = "model"

[assistant.authentication]
kind = "none"
"#,
            r#"[assistant]
enabled = true
endpoint = "http://provider.example"

[assistant.authentication]
kind = "none"
"#,
            r#"[assistant]
enabled = true
endpoint = "http://provider.example"
model = "model"
"#,
        ];

        for contents in invalid_configs {
            let file = TempFile::new(contents);
            assert_eq!(load(Some(file.path())), Err(ConfigError::InvalidToml));
        }
    }

    #[test]
    fn tracked_assistant_configs_load_without_reading_key_files() {
        let directory = Path::new(env!("CARGO_MANIFEST_DIR")).join("../assistant-config");
        let expected = [
            (
                "groq.toml",
                "https://api.groq.com/openai/v1/chat/completions",
                "qwen/qwen3.8-27b",
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
            let loaded = load(Some(&directory.join(file_name))).unwrap();
            let settings = loaded.as_enabled().expect("assistant is enabled");
            assert_eq!(settings.endpoint.as_str(), endpoint);
            assert_eq!(settings.model.as_str(), model);
            assert!(settings.supports_images);
            assert_eq!(
                settings.authentication,
                AssistantAuthentication::Bearer {
                    api_key_file: PathBuf::from(api_key_file),
                }
            );
        }
    }
}
